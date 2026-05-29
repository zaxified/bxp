/// Expression evaluator used to compute input_schema variable values.
///
/// Expressions are evaluated against a single CSV row represented by a Context.
/// The evaluator is a single-pass recursive-descent parser that produces a Value
/// (string, number, or boolean) without building an intermediate AST.
///
/// Operator precedence (highest to lowest):
///   unary -
///   * /       (numeric multiply / divide)
///   &         (string concatenation)
///   + -       (numeric add / subtract)
///   = != < > <= >=  (comparison; string equality only for = and !=)
///   AND
///   OR
///
/// Built-in functions:
///   [ColumnName]              — field value by CSV header name
///   FIELDS(n)                 — field value by 1-based column index
///   'text'                    — string literal
///   IF(cond, yes, no)         — short-circuit conditional
///   ABS(f)                    — absolute numeric value
///   NOW()                     — current UTC datetime as ISO 8601 string (YYYY-MM-DDTHH:MM:SSZ)
///   TRIM(f)                   — strip leading and trailing whitespace from string
///   ROUND(f, n)               — round f to n decimal places
///   FLOOR(f)                  — round f down to nearest integer
///   CEILING(f)                — round f up to nearest integer
///   RAND()                    — random float in [0, 1)
///   COALESCE(a, b, ...)       — first non-empty argument (empty = whitespace-only string)
///   DATE_CONVERT(f, from, to) — reformat a date/time string; format tokens use sunrise syntax
///   PRICE_VALUE(f)            — strip currency symbol/code, return numeric string
///   PRICE_CURRENCY(f)         — extract currency code from a price string
///   TICKER(f)                 — map field value through broker's ticker_map
///   LOOKUP([name,] key, field) — retrieve a value stored by a pre_pass table
const std = @import("std");
const sunrise = @import("sunrise");

// ---------------------------------------------------------------------------
// Value — the three types an expression can produce
// ---------------------------------------------------------------------------

pub const Value = union(enum) {
    string: []const u8,
    number: f80,
    boolean: bool,

    /// Returns the value as a string slice, allocated with alloc when needed.
    /// Numbers: integer-valued floats are formatted without a decimal point;
    ///          all other floats are formatted with up to 8 decimal places
    ///          (trailing zeros are trimmed).
    pub fn toString(self: Value, alloc: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .string => |s| s,
            .number => |n| blk: {
                if (n == @trunc(n) and @abs(n) < 1e15) {
                    break :blk std.fmt.allocPrint(alloc, "{d}", .{@as(i64, @intFromFloat(n))});
                }
                const s = try std.fmt.allocPrint(alloc, "{d:.8}", .{n});
                // Trim trailing zeros after the decimal point.
                var end = s.len;
                while (end > 1 and s[end - 1] == '0') end -= 1;
                if (end > 0 and s[end - 1] == '.') end -= 1;
                break :blk s[0..end];
            },
            .boolean => |b| if (b) "true" else "false",
        };
    }

    pub fn toNumber(self: Value) !f80 {
        return switch (self) {
            .number => |n| n,
            // Empty string is treated as zero so that optional/missing CSV
            // fields don't cause arithmetic failures — callers can gate with
            // COALESCE or IF if they need to distinguish "no value" from 0.
            // American thousands-separated numbers ("1,234.56") are tried
            // after the standard parseFloat fails, so they don't pay the
            // parseGroupedNumber overhead when the input is a plain decimal.
            .string => |s| if (s.len == 0) 0 else
                std.fmt.parseFloat(f80, s) catch
                parseGroupedNumber(s, ',', '.') catch
                return error.NotANumber,
            .boolean => |b| if (b) @as(f80, 1) else 0,
        };
    }

    pub fn toBool(self: Value) bool {
        return switch (self) {
            .boolean => |b| b,
            .number => |n| n != 0,
            // A non-empty string — even "0" or "false" — is truthy.
            // This matches typical template logic where field absence (empty
            // string) is the only falsy state for string-typed data.
            .string => |s| s.len > 0,
        };
    }
};

// ---------------------------------------------------------------------------
// Context — per-row evaluation state passed to every expression
// ---------------------------------------------------------------------------

pub const Context = struct {
    /// Field values for the current CSV row, in column order.
    fields: []const []const u8,
    /// Maps CSV column header names to 0-based column indices.
    col_index: *const std.StringHashMap(usize),
    /// Symbol remapping table from broker config (e.g. "BTC" → "BTC-USD").
    ticker_map: *const std.StringHashMap([]const u8),
    /// Lookup table populated by the pre_pass scan; keys are "name\x00key\x00field".
    /// Null when no pre_pass is configured, or during the pre_pass scan itself.
    lookup_table: ?*const std.StringHashMap([]const u8),
    /// When exactly one pre_pass block is defined, this holds its name so 2-arg
    /// `LOOKUP(key, field)` can resolve to the implicit namespace. Null when zero
    /// or multiple pre_pass blocks exist; in the latter case 2-arg LOOKUP is an
    /// error and callers must use the explicit 3-arg form.
    single_prepass_name: ?[]const u8 = null,
    /// Validate-mode whitelist of pre_pass block names. Set non-null
    /// alongside `lookup_table == null` (the bxp-fmt --config deep
    /// pass) so `builtinLookup` can flag unknown first arguments at
    /// parse time — typo / undefined block — instead of silently
    /// returning "". Runtime callers leave this null to preserve the
    /// existing behaviour (silent "" on miss is intentional there).
    pre_pass_names: ?*const std.StringHashMap(void) = null,
    /// Allocator for strings produced during expression evaluation.
    alloc: std.mem.Allocator,
    /// Decimal separator used in input CSV numeric fields (e.g. ',' for European format).
    /// Field values that look numeric are normalized to '.' before arithmetic evaluation.
    /// Default '.' means no conversion.
    decimal_sep_in: u8 = '.',
    /// Output quote character resolved by ''' in expressions.
    /// 0 = none (''' produces ""), '\'' = single, '"' = double.
    quote_out: u8 = 0,
    /// When non-null, the evaluator writes a human-readable description of the last
    /// error here before returning the error.  String is allocated with ctx.alloc.
    /// Caller sets this and resets the pointed value to "" before each eval call.
    error_detail: ?*[]const u8 = null,
    /// Phase G1: byte offset of the offending token in the expression
    /// source. Set by the Parser/Tokenizer alongside `error_detail` so
    /// callers (bxp-fmt --expr stderr, bxp-fmt --config $err_* shape)
    /// can pinpoint the location for the GUI ExprPanel highlight.
    /// Both offset and len are zero when no specific token is at fault
    /// (e.g. allocator failures, format-only complaints).
    error_offset: ?*u32 = null,
    error_len: ?*u32 = null,
    /// Per-call trace writer for the GUI hover-on-token feature. When set,
    /// every successful function call emits one NDJSON record:
    ///   {"fn": "ABS", "src_start": 4, "src_end": 14, "value": "1.50"}
    /// `src_start` and `src_end` are byte offsets into the expression source
    /// passed to `eval()`. Default null disables the writer entirely so the
    /// runtime path (bxp-cli pipeline) pays no overhead.
    trace_writer: ?*std.Io.Writer = null,

    /// Returns the field value at idx, trimmed of surrounding spaces.
    /// Returns "" when idx is out of range.
    ///
    /// Note: RFC 4180 §2 specifies that spaces are part of the field value and
    /// must not be trimmed.  We intentionally deviate from this rule because
    /// broker CSV exports frequently pad fields with spaces, and all downstream
    /// logic (date parsing, numeric conversion, comparisons) benefits from
    /// clean values.
    fn field(self: *const Context, idx: usize) []const u8 {
        if (idx >= self.fields.len) return "";
        return std.mem.trim(u8, self.fields[idx], " ");
    }

    /// Looks up a field by its column header name and returns its value.
    /// Returns "" when the column name is not found in col_index.
    fn fieldByName(self: *const Context, name: []const u8) []const u8 {
        const idx = self.col_index.get(name) orelse return "";
        return self.field(idx);
    }
};

// ---------------------------------------------------------------------------
// Tokenizer — converts expression source text into a stream of tokens
// ---------------------------------------------------------------------------
//
// Per-token TokenDoc consts live here (just above the Tokenizer that produces
// each one). Bottom `tokens` array collects them by reference so adding a
// token kind = add the recognition branch in `next()` + the doc const here in
// one place.

// Recognised by Tokenizer.next()'s `[` branch.
const column_token_doc: TokenDoc = .{
    .kind = "columnRef",
    .syntax = "[ColumnName]",
    .description = "Input CSV column value by header name. Case-sensitive.",
};
// `$variable` has NO tokenizer impl — it's the JSON config key shape used in
// input_schema / output_schema; expressions only see the resolved values of
// those variables, never the names. Documented here purely so the GUI's
// syntax-help section can show users how to declare them in the config file.
const input_var_token_doc: TokenDoc = .{
    .kind = "inputVar",
    .syntax = "$variable",
    .description = "Named variable declared in input_schema. Must start with $.",
};
// Recognised by Tokenizer.next()'s `'` branch.
const string_token_doc: TokenDoc = .{
    .kind = "string",
    .syntax = "'single quoted'",
    .description = "String literal. Escape with \\' for embedded quote.",
};
// Recognised by Tokenizer.next()'s digit branch.
const number_token_doc: TokenDoc = .{
    .kind = "number",
    .syntax = "123 / 3.14",
    .description = "Numeric literal. Decimals supported. American thousands separators (1,234.56) parsed automatically.",
};
// Recognised as `ident` by the tokenizer, then resolved by Parser.evalCall.
const function_token_doc: TokenDoc = .{
    .kind = "function",
    .syntax = "FUNCNAME(...)",
    .description = "Built-in function call. See function list below.",
};
// Recognised as `ident` by the tokenizer, matched against AND/OR in parseAnd/parseOr.
const keyword_token_doc: TokenDoc = .{
    .kind = "keyword",
    .syntax = "AND / OR",
    .description = "Logical keyword operators.",
};

const TokKind = enum {
    string_lit, // 'text'
    triple_quote, // ''' — output quote character placeholder
    number_lit, // 123 / 3.14
    ident, // function name or AND/OR keyword
    field_ref, // [ColumnName] or [3]
    lparen, // (
    rparen, // )
    comma, // ,
    plus, // +
    minus, // -
    star, // *
    slash, // /
    amp, // & (concat)
    eq, // =
    neq, // !=
    lt, // <
    gt, // >
    lte, // <=
    gte, // >=
    eof,
};

/// Tokens carry their byte position in the source so error sites can
/// surface a precise highlight range up to the GUI ExprPanel (Phase G1).
/// `text` is the inner / unquoted slice for `string_lit` / `field_ref`;
/// `offset` and `len` always span the **outer** form including any
/// delimiters (quotes, brackets) so the highlight covers the visible
/// token in the editor. For `eof`, `offset == src.len` and `len == 0`.
const Token = struct {
    kind: TokKind,
    text: []const u8,
    offset: u32,
    len: u32,
};

const Tokenizer = struct {
    src: []const u8,
    pos: usize,
    /// Set before returning error.UnexpectedChar so the caller can build a detail message.
    error_char: u8 = 0,
    error_pos: usize = 0, // 0-based position of the bad character in src
    /// Phase G1: span of the most recently produced token (or the
    /// position of `error.UnexpectedChar`). Updated on every `mkTok`
    /// call so the Parser's `setDetail` can populate
    /// `Context.error_offset` / `error_len` without threading the
    /// offending token through every parse-method call site.
    last_offset: u32 = 0,
    last_len: u32 = 0,

    fn init(src: []const u8) Tokenizer {
        return .{ .src = src, .pos = 0 };
    }

    // Only spaces are stripped — tabs/newlines are not valid in bxp
    // expression strings (they are single-line JSON5 string values),
    // so treating them as unexpected characters gives better errors.
    fn skipWs(self: *Tokenizer) void {
        while (self.pos < self.src.len and self.src[self.pos] == ' ')
            self.pos += 1;
    }

    /// Build a token spanning [start, self.pos) — `start` is the byte
    /// offset where the token began (before quotes / brackets are
    /// consumed), `self.pos` points just past the last consumed byte.
    /// Mutates `last_offset` / `last_len` so Parser error sites can
    /// pick up the location of the just-read token.
    fn mkTok(self: *Tokenizer, kind: TokKind, text: []const u8, start: usize) Token {
        const offset: u32 = @intCast(start);
        const len: u32 = @intCast(self.pos - start);
        self.last_offset = offset;
        self.last_len = len;
        return .{
            .kind = kind,
            .text = text,
            .offset = offset,
            .len = len,
        };
    }

    fn next(self: *Tokenizer) !Token {
        self.skipWs();
        if (self.pos >= self.src.len) return self.mkTok(.eof, "", self.pos);

        const tok_start = self.pos;
        const c = self.src[self.pos];

        // String literal 'text'
        // Special case: triple single-quote ''' is a placeholder for the output
        // quote character defined by csv_text_quote_out ("none"/"single"/"double").
        // The triple-quote check must come BEFORE the generic single-quote path
        // so that ''' is never consumed as an empty string '' followed by a lone '.
        // Unclosed strings (no closing ') consume to end of source and return
        // whatever was scanned — the parser will fail at the next expected token.
        if (c == '\'') {
            self.pos += 1;
            if (self.pos + 1 < self.src.len and
                self.src[self.pos] == '\'' and self.src[self.pos + 1] == '\'')
            {
                self.pos += 2;
                return self.mkTok(.triple_quote, "'''", tok_start);
            }
            const inner_start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != '\'')
                self.pos += 1;
            const text = self.src[inner_start..self.pos];
            if (self.pos < self.src.len) self.pos += 1; // consume closing '
            return self.mkTok(.string_lit, text, tok_start);
        }

        // Field reference [Name] or [n]
        if (c == '[') {
            self.pos += 1;
            const inner_start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != ']')
                self.pos += 1;
            const text = self.src[inner_start..self.pos];
            if (self.pos < self.src.len) self.pos += 1; // consume ]
            return self.mkTok(.field_ref, text, tok_start);
        }

        // Number literal — leading '-' is absorbed here only when immediately
        // followed by a digit, so it's always a negative literal rather than
        // a subtraction operator. "-3.14" tokenizes as one number_lit; "x - 3"
        // produces ident, minus, number_lit. This heuristic is unambiguous
        // because expressions can't produce a result that serves as the left
        // operand of a prefix '-' (the left side is already parenthesized).
        if (std.ascii.isDigit(c) or (c == '-' and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1]))) {
            if (c == '-') self.pos += 1;
            while (self.pos < self.src.len and (std.ascii.isDigit(self.src[self.pos]) or self.src[self.pos] == '.'))
                self.pos += 1;
            return self.mkTok(.number_lit, self.src[tok_start..self.pos], tok_start);
        }

        // Identifier or keyword
        if (std.ascii.isAlphabetic(c) or c == '_') {
            while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_'))
                self.pos += 1;
            return self.mkTok(.ident, self.src[tok_start..self.pos], tok_start);
        }

        // Operators
        self.pos += 1;
        return switch (c) {
            '(' => self.mkTok(.lparen, "(", tok_start),
            ')' => self.mkTok(.rparen, ")", tok_start),
            ',' => self.mkTok(.comma, ",", tok_start),
            '+' => self.mkTok(.plus, "+", tok_start),
            '-' => self.mkTok(.minus, "-", tok_start),
            '*' => self.mkTok(.star, "*", tok_start),
            '/' => self.mkTok(.slash, "/", tok_start),
            '&' => self.mkTok(.amp, "&", tok_start),
            '=' => self.mkTok(.eq, "=", tok_start),
            '!' => blk: {
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    break :blk self.mkTok(.neq, "!=", tok_start);
                }
                self.error_char = '!';
                self.error_pos = self.pos - 1; // self.pos was already incremented above
                self.last_offset = @intCast(self.error_pos);
                self.last_len = 1;
                return error.UnexpectedChar;
            },
            '<' => blk: {
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    break :blk self.mkTok(.lte, "<=", tok_start);
                }
                break :blk self.mkTok(.lt, "<", tok_start);
            },
            '>' => blk: {
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    break :blk self.mkTok(.gte, ">=", tok_start);
                }
                break :blk self.mkTok(.gt, ">", tok_start);
            },
            else => {
                self.error_char = c;
                self.error_pos = self.pos - 1; // self.pos was already incremented above
                self.last_offset = @intCast(self.error_pos);
                self.last_len = 1;
                return error.UnexpectedChar;
            },
        };
    }

    // Peek does NOT restore `last_offset`/`last_len` — only `pos`.
    // Callers that call peek() followed by next() to confirm the token
    // will see `last_offset`/`last_len` updated twice (once for the
    // peek, once for the confirming next()). Both cover the same token,
    // so the net result is correct. The Parser's `setDetail` always runs
    // AFTER a confirming `next()`, so the span it picks up is accurate.
    fn peek(self: *Tokenizer) !Token {
        const saved = self.pos;
        const tok = try self.next();
        self.pos = saved;
        return tok;
    }
};

/// Phase G4 sunrise-format diagnostic shape. Re-exported for external
/// consumers of the unified static checker (kept public after the
/// G4/G5 unification — `staticCheckSplitPart`/`staticCheckDateFormat`
/// are gone, callers consume `StaticCheckResult` instead).
pub const BadDateFormat = struct {
    fmt: []const u8, // unquoted inner format text
    pos: usize,      // 0-based offset of bad char within fmt
    off: u32,        // absolute offset of the literal token in the source
    len: u32,        // length of the literal token in the source
};

pub const BadSplitPart = struct {
    bad_idx: i64,    // the offending integer literal value (≤ 0)
    off: u32,        // absolute offset of the literal token in the source
    len: u32,        // length of the literal token in the source
};

/// Result of the unified per-call static checker. At most one hit per
/// kind, mirroring the pre-unification first-hit semantics of
/// `staticCheckSplitPart` / `staticCheckDateFormat` (the linear walker
/// stops recording further hits of the same kind once one is set).
///
/// Adding a new ArgKind that needs a static check = add a field here,
/// add a case in `tryScanArg` below, populate FnDoc.args on the
/// relevant builtin, and emit the diagnostic in `bxp-core/src/config.zig`.
pub const StaticCheckResult = struct {
    /// `positive_integer` violation — bad literal int (≤ 0).
    /// Today populated by SPLIT_PART arg[2]; carries the offending
    /// integer plus its source span for editor highlighting.
    split_part: ?BadSplitPart = null,
    /// `sunrise_format` violation — bad format string literal.
    /// Today populated by DATE_CONVERT args[1]/[2]; carries the
    /// offending format text + 0-based offset of the bad character
    /// plus the absolute source span of the literal token.
    date_format: ?BadDateFormat = null,
};

/// Walk every call in `src`, look up each by name in `builtins`, and
/// dispatch per-arg static checks via FnDoc.args[i].kind. Replaces the
/// pre-G4/G5-unification trio of name-hardcoded scanners with a single
/// data-driven walker — adding a new specialized ArgKind no longer
/// touches dispatch logic.
///
/// Behavior preserved verbatim from `staticCheckSplitPart` and
/// `staticCheckDateFormat`:
///   - Linear single-pass: tokens inside one call are consumed before
///     the outer loop resumes, so nested calls (e.g. SPLIT_PART inside
///     SPLIT_PART's first arg) are NOT re-scanned. This matches the
///     pre-unification behavior; fixing nested coverage is a follow-up.
///   - Single-bare-token gate: an arg only triggers its kind's
///     scanner when it consists of exactly one top-level token of the
///     expected kind. Variables, expressions, nested calls, and
///     concatenations all push the count above 1 and are skipped
///     (runtime-resolved).
///   - First-hit semantics: at most one diagnostic per kind across
///     the whole `src`. The walker keeps scanning so subsequent fields
///     in the same diagnostic batch can still be checked, but later
///     hits of an already-set kind are silently dropped.
pub fn staticCheckCalls(src: []const u8) StaticCheckResult {
    var out: StaticCheckResult = .{};
    var tok = Tokenizer.init(src);
    while (true) {
        const t = tok.next() catch return out;
        if (t.kind == .eof) return out;
        if (t.kind != .ident) continue;

        // Look up FnDoc by name (case-insensitive, mirroring evalCall).
        // Skip when no specialized arg kinds — saves the inner walk.
        const fn_doc = lookupFnDocByName(t.text) orelse continue;
        if (!hasSpecializedArgs(fn_doc)) continue;

        // Must be followed by `(` to be a real call.
        const lp = tok.next() catch return out;
        if (lp.kind != .lparen) continue;

        // Walk arg list at depth 1; nested parens raise depth and
        // their tokens don't contribute to the bare-token count of
        // the enclosing arg. This matches `staticCheckDateFormat`'s
        // counter logic and produces identical observable behavior to
        // `staticCheckSplitPart` for every input we tested.
        var depth: u32 = 1;
        var arg_idx: u32 = 0;
        var arg_token_count: u32 = 0;
        var arg_first: Token = .{ .kind = .eof, .text = "", .offset = 0, .len = 0 };

        while (true) {
            const inner = tok.next() catch return out;
            if (inner.kind == .eof) return out;

            if (inner.kind == .comma and depth == 1) {
                tryScanArg(fn_doc, arg_idx, arg_token_count, arg_first, &out);
                arg_idx += 1;
                arg_token_count = 0;
                arg_first = .{ .kind = .eof, .text = "", .offset = 0, .len = 0 };
                continue;
            }

            if (inner.kind == .lparen) {
                depth += 1;
                continue;
            }

            if (inner.kind == .rparen) {
                depth -= 1;
                if (depth == 0) {
                    tryScanArg(fn_doc, arg_idx, arg_token_count, arg_first, &out);
                    break;
                }
                continue;
            }

            if (depth == 1) {
                if (arg_token_count == 0) arg_first = inner;
                arg_token_count += 1;
            }
        }
    }
}

/// Linear scan over `builtins` (case-insensitive name match) for
/// FnDoc lookup. Returns null when `name` isn't a known builtin.
fn lookupFnDocByName(name: []const u8) ?FnDoc {
    for (builtins) |b| {
        if (std.ascii.eqlIgnoreCase(name, b.doc.name)) return b.doc;
    }
    return null;
}

/// Quick early-exit helper: does `fn_doc.args` declare any arg whose
/// kind triggers a static checker? Avoids walking the call's tokens
/// when there's no work for any arg position.
fn hasSpecializedArgs(fn_doc: FnDoc) bool {
    for (fn_doc.args) |a| {
        switch (a.kind) {
            .positive_integer, .sunrise_format => return true,
            else => {},
        }
    }
    return false;
}

/// Per-arg dispatch: when the completed arg span is exactly one bare
/// top-level token of the expected kind, run the kind-specific
/// scanner and record into `out`. First-hit semantics mean later hits
/// of the same kind are dropped silently.
fn tryScanArg(
    fn_doc: FnDoc,
    arg_idx: u32,
    count: u32,
    first: Token,
    out: *StaticCheckResult,
) void {
    if (count != 1) return;
    if (arg_idx >= fn_doc.args.len) return; // variadic past declared args
    switch (fn_doc.args[arg_idx].kind) {
        .positive_integer => {
            if (first.kind != .number_lit) return;
            if (out.split_part != null) return;
            const f = std.fmt.parseFloat(f80, first.text) catch return;
            // Gate Inf/NaN and finite-but-out-of-i64 — `@intFromFloat`
            // is undefined behaviour on any of these, and they're all
            // reachable from user input in the editor (e.g. `1e30`).
            // Mirrors the toPositiveIndex helper that runtime FIELDS /
            // SPLIT_PART use; here we keep the literal "≤ 0" detection
            // but treat any non-representable literal as a violation
            // with bad_idx clamped to a sentinel so the diagnostic
            // message stays printable.
            if (!std.math.isFinite(f) or f > @as(f80, @floatFromInt(std.math.maxInt(i64))) or f < @as(f80, @floatFromInt(std.math.minInt(i64)))) {
                out.split_part = .{
                    .bad_idx = 0,
                    .off = first.offset,
                    .len = first.len,
                };
                return;
            }
            const v = @as(i64, @intFromFloat(f));
            if (v <= 0) out.split_part = .{
                .bad_idx = v,
                .off = first.offset,
                .len = first.len,
            };
        },
        .sunrise_format => {
            if (first.kind != .string_lit) return;
            if (out.date_format != null) return;
            if (scanDateFormat(first.text)) |pos| {
                out.date_format = .{
                    .fmt = first.text,
                    .pos = pos,
                    .off = first.offset,
                    .len = first.len,
                };
            }
        },
        // No static literal check: runtime-only domains + plain string /
        // expr args. (integer_in_range's optional literal-range warning is
        // a deliberate non-goal for now — see plan step 4.)
        .expr,
        .string,
        .literal_string,
        .pre_pass_name,
        .number,
        .finite_number,
        .integer_in_range,
        => {},
    }
}

/// Scan one sunrise format string. Returns 0-based offset of first
/// ASCII letter outside `[...]` that's not in the vocabulary, or null
/// when the string is clean. Unclosed `[` consumes to end of string
/// (no false flag) — sunrise's runtime would error on such input.
fn scanDateFormat(fmt: []const u8) ?usize {
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        const c = fmt[i];
        if (c == '[') {
            i += 1;
            while (i < fmt.len and fmt[i] != ']') : (i += 1) {}
            continue;
        }
        // Sunrise vocabulary: Y M D E A / a e h i m s. Anything else
        // ASCII-alpha outside brackets is suspect.
        switch (c) {
            'A', 'D', 'E', 'M', 'Y' => {},
            'a', 'e', 'h', 'i', 'm', 's' => {},
            'B'...'C', 'F'...'L', 'N'...'X', 'Z',
            'b'...'d', 'f'...'g', 'j'...'l', 'n'...'r', 't'...'z' => return i,
            else => {}, // non-letter (digit, separator, etc.) is fine
        }
    }
    return null;
}

/// Phase G8: collect static cross-reference data from an expression
/// source. Walks tokens (no AST, no eval) and gathers:
///   - `fields` set: every named `[ColumnName]` reference (numeric
///     `[1]`-style indexes are skipped — they reference columns by
///     position, not name).
///   - `lookups` set: literal first-arg string of every 3-arg
///     `LOOKUP("name", key, field)` call. Used to cross-walk against
///     declared `pre_passes` block names.
///   - `has_two_arg_lookup`: at least one `LOOKUP(key, field)` was
///     observed. Caller resolves these to the implicit namespace
///     (`_default` for legacy single block, the lone pre_pass key
///     when exactly one block is defined).
///   - `has_computed_lookup_name`: at least one 3-arg LOOKUP had a
///     non-literal first arg (e.g. `LOOKUP(name_var, ...)`). Caller
///     opts out of unused-pre_pass warnings entirely when this fires
///     — we can't statically prove which block(s) are reached.
///
/// Owned hash sets — caller calls `deinit()` on the result.
pub const StaticRefs = struct {
    fields: std.StringHashMap(void),
    lookups: std.StringHashMap(void),
    has_two_arg_lookup: bool = false,
    has_computed_lookup_name: bool = false,

    pub fn deinit(self: *StaticRefs) void {
        self.fields.deinit();
        self.lookups.deinit();
    }
};

pub fn staticReferences(src: []const u8, alloc: std.mem.Allocator) !StaticRefs {
    var refs: StaticRefs = .{
        .fields = std.StringHashMap(void).init(alloc),
        .lookups = std.StringHashMap(void).init(alloc),
    };
    errdefer refs.deinit();

    var tok = Tokenizer.init(src);
    while (true) {
        const t = tok.next() catch break;
        if (t.kind == .eof) break;

        // [Name] field references — record by name. Skip numeric
        // indexes which reference position, not a header name.
        if (t.kind == .field_ref) {
            if (t.text.len == 0) continue;
            if (std.ascii.isDigit(t.text[0])) continue;
            try refs.fields.put(t.text, {});
            continue;
        }

        if (t.kind != .ident) continue;
        if (!std.ascii.eqlIgnoreCase(t.text, "LOOKUP")) continue;

        // LOOKUP — must be followed by `(` to be a real call.
        const lp = tok.next() catch break;
        if (lp.kind != .lparen) continue;

        // Walk inside the call counting top-level commas + tracking
        // the first argument's tokens at depth 1.
        var depth: u32 = 1;
        var commas: u32 = 0;
        var arg0_count: u32 = 0;
        var arg0_token: Token = .{ .kind = .eof, .text = "", .offset = 0, .len = 0 };
        var arg0_done = false;
        while (true) {
            const inner = tok.next() catch break;
            if (inner.kind == .eof) break;
            if (inner.kind == .lparen) {
                depth += 1;
                if (depth == 2 and !arg0_done) arg0_count += 1;
                continue;
            }
            if (inner.kind == .rparen) {
                depth -= 1;
                if (depth == 0) break;
                continue;
            }
            if (inner.kind == .comma and depth == 1) {
                commas += 1;
                if (commas == 1) arg0_done = true;
                continue;
            }
            if (depth == 1 and !arg0_done) {
                if (arg0_count == 0) arg0_token = inner;
                arg0_count += 1;
            }
        }

        if (commas >= 2) {
            // 3-arg form: first arg is the explicit pre_pass name.
            if (arg0_count == 1 and arg0_token.kind == .string_lit) {
                try refs.lookups.put(arg0_token.text, {});
            } else {
                refs.has_computed_lookup_name = true;
            }
        } else if (commas == 1) {
            // 2-arg form: implicit namespace.
            refs.has_two_arg_lookup = true;
        }
        // commas == 0 → malformed LOOKUP; let runtime catch it.
    }
    return refs;
}

// ---------------------------------------------------------------------------
// Parser / Evaluator — recursive-descent; evaluates while parsing, no AST
// ---------------------------------------------------------------------------
//
// Per-keyword + per-operator catalog consts live here, just above the Parser
// that gives them meaning. Comparison ops cluster around parseCmp, additive
// around parseAdd, multiplicative around parseMul, etc. — adding an operator
// = add it to the tokenizer's switch + the parser handler + a doc const here
// in one nearby region.

// Handled in Parser.parseAnd.
const and_kw_doc: KeywordDoc = .{
    .name = "AND",
    .description = "Logical AND. Both operands are evaluated. Returns \"true\" or \"false\".",
};
// Handled in Parser.parseOr.
const or_kw_doc: KeywordDoc = .{
    .name = "OR",
    .description = "Logical OR. Both operands are evaluated. Returns \"true\" or \"false\".",
};
// Handled in Parser.parseNot.
const not_kw_doc: KeywordDoc = .{
    .name = "NOT",
    .description = "Boolean negation. Precedence sits between comparison operators and AND, so `NOT [A] = 1` means `NOT ([A] = 1)`. Multiple NOTs stack.",
};

// Comparison operators — semantics in Parser.parseCmp.
const eq_op_doc: OperatorDoc = .{ .token = "=",  .description = "Equality comparison. Returns \"true\" or \"false\"." };
const neq_op_doc: OperatorDoc = .{ .token = "!=", .description = "Inequality comparison." };
const lt_op_doc: OperatorDoc = .{ .token = "<",  .description = "Less-than comparison (numeric or lexicographic)." };
const gt_op_doc: OperatorDoc = .{ .token = ">",  .description = "Greater-than comparison." };
const lte_op_doc: OperatorDoc = .{ .token = "<=", .description = "Less-than-or-equal comparison." };
const gte_op_doc: OperatorDoc = .{ .token = ">=", .description = "Greater-than-or-equal comparison." };

// Additive operators — semantics in Parser.parseAdd (− also unary in parseUnary).
const add_op_doc: OperatorDoc = .{ .token = "+", .description = "Numeric addition." };
const sub_op_doc: OperatorDoc = .{ .token = "-", .description = "Numeric subtraction." };

// Concat operator — semantics in Parser.parseCat.
const concat_op_doc: OperatorDoc = .{ .token = "&", .description = "String concatenation: \"hello\" & \" \" & \"world\"" };

// Multiplicative operators — semantics in Parser.parseMul.
const mul_op_doc: OperatorDoc = .{ .token = "*", .description = "Numeric multiplication." };
const div_op_doc: OperatorDoc = .{ .token = "/", .description = "Numeric division." };

const Parser = struct {
    tok: Tokenizer,
    ctx: *const Context,
    last_field_name: []const u8 = "",

    fn init(src: []const u8, ctx: *const Context) Parser {
        return .{ .tok = Tokenizer.init(src), .ctx = ctx };
    }

    /// Writes a formatted description to ctx.error_detail (if set by caller).
    /// Writing through the pointer is safe even with *const Context because
    /// we modify the pointed-to value, not the Context field itself.
    ///
    /// Phase G1: also writes the most-recently-tokenized span to
    /// `ctx.error_offset` / `error_len` so the GUI ExprPanel can
    /// underline the offending token. The "most recent" token is
    /// usually the one that triggered the error (e.g. an unexpected
    /// `)`); when the error is actually about the *next* token (e.g.
    /// a missing `(`, where the next-tokenizer call returns `eof`),
    /// the highlight covers whatever was last consumed — close enough
    /// for editor UX, and never wider than the whole expression.
    fn setDetail(self: *const Parser, comptime fmt: []const u8, args: anytype) void {
        if (self.ctx.error_detail) |d| {
            d.* = std.fmt.allocPrint(self.ctx.alloc, fmt, args) catch return;
        }
        if (self.ctx.error_offset) |o| o.* = self.tok.last_offset;
        if (self.ctx.error_len) |l| l.* = self.tok.last_len;
    }

    /// Emit one NDJSON record describing a successful function call to
    /// `ctx.trace_writer` (no-op when the writer is null). Errors are
    /// swallowed — tracing must never disrupt evaluation.
    ///
    /// **Flush policy:** the writer is intentionally NOT flushed here.
    /// Per-event flush would be one syscall per traced call, so a long
    /// expression with N FN-calls translates to N writes. `bxp-fmt
    /// runExprTrace` (and the in-process `bridge_eval_expr_trace`)
    /// flush once at the end of evaluating a single expression, so the
    /// per-call bytes ride out on that final flush. Skipping the
    /// per-call flush is safe because the buffer auto-flushes on
    /// overflow and consumers only act on the trace at end-of-stream.
    fn emitCallTrace(
        self: *Parser,
        name: []const u8,
        src_start: usize,
        src_end: usize,
        value: Value,
    ) void {
        const w = self.ctx.trace_writer orelse return;
        const value_str: []const u8 = switch (value) {
            .number => |n| std.fmt.allocPrint(self.ctx.alloc, "{d}", .{n}) catch return,
            .string => |s| s,
            .boolean => |b| if (b) "true" else "false",
        };
        var jw: std.json.Stringify = .{ .writer = w, .options = .{} };
        jw.beginObject() catch return;
        jw.objectField("fn") catch return;
        jw.write(name) catch return;
        jw.objectField("src_start") catch return;
        jw.write(src_start) catch return;
        jw.objectField("src_end") catch return;
        jw.write(src_end) catch return;
        jw.objectField("value") catch return;
        jw.write(value_str) catch return;
        jw.endObject() catch return;
        w.writeByte('\n') catch return;
    }

    /// Convenience wrapper for NotANumber — includes field name when known.
    fn setNotANumber(self: *Parser, s: []const u8) void {
        if (self.last_field_name.len > 0) {
            self.setDetail("not a number: \"{s}\" (in [{s}])", .{ s, self.last_field_name });
        } else {
            self.setDetail("not a number: \"{s}\"", .{s});
        }
    }

    // expr := or_expr
    pub fn parseExpr(self: *Parser) anyerror!Value {
        return self.parseOr();
    }

    // or_expr := and_expr ('OR' and_expr)*
    fn parseOr(self: *Parser) anyerror!Value {
        var left = try self.parseAnd();
        while (true) {
            const t = try self.tok.peek();
            if (t.kind != .ident or !std.ascii.eqlIgnoreCase(t.text, "OR")) break;
            _ = try self.tok.next();
            const right = try self.parseAnd();
            left = Value{ .boolean = left.toBool() or right.toBool() };
        }
        return left;
    }

    // and_expr := not_expr ('AND' not_expr)*
    fn parseAnd(self: *Parser) anyerror!Value {
        var left = try self.parseNot();
        while (true) {
            const t = try self.tok.peek();
            if (t.kind != .ident or !std.ascii.eqlIgnoreCase(t.text, "AND")) break;
            _ = try self.tok.next();
            const right = try self.parseNot();
            left = Value{ .boolean = left.toBool() and right.toBool() };
        }
        return left;
    }

    // not_expr := 'NOT'* cmp_expr
    // Precedence sits between `AND` and the comparison operators so that
    // `NOT [A] = 1` parses as `NOT ([A] = 1)` and `[A] AND NOT [B]` parses
    // as `[A] AND (NOT [B])`. Multiple NOTs stack (`NOT NOT [A]` == `[A]`)
    // because they consume in a loop.
    fn parseNot(self: *Parser) anyerror!Value {
        var negate: bool = false;
        while (true) {
            const t = try self.tok.peek();
            if (t.kind != .ident or !std.ascii.eqlIgnoreCase(t.text, "NOT")) break;
            _ = try self.tok.next();
            negate = !negate;
        }
        const v = try self.parseCmp();
        if (!negate) return v;
        return Value{ .boolean = !v.toBool() };
    }

    // cmp_expr := add_expr (op add_expr)?
    // Comparisons are NOT chained: `a < b < c` parses as `(a < b) < c` which
    // will usually fail with StringComparisonUnsupported (booleans don't
    // convert to numbers for < / > / <= / >=). Use AND for range checks:
    // `a > 0 AND a < 100`.
    fn parseCmp(self: *Parser) anyerror!Value {
        const left = try self.parseAdd();
        const t = try self.tok.peek();
        const op = t.kind;
        if (op != .eq and op != .neq and op != .lt and op != .gt and op != .lte and op != .gte)
            return left;
        _ = try self.tok.next();
        const right = try self.parseAdd();

        // Try numeric comparison first; fall back to string equality.
        // When either operand fails toNumber(), both are stringified.
        // Ordering operators (< > <= >=) don't support string operands —
        // returning error.StringComparisonUnsupported is intentional
        // so users see a clear error instead of silently wrong output.
        const ln = left.toNumber() catch null;
        const rn = right.toNumber() catch null;
        if (ln != null and rn != null) {
            const l = ln.?;
            const r = rn.?;
            return Value{ .boolean = switch (op) {
                .eq => l == r,
                .neq => l != r,
                .lt => l < r,
                .gt => l > r,
                .lte => l <= r,
                .gte => l >= r,
                else => unreachable, // op enum is exhaustive; eq/neq handled above, lt/gt/lte/gte handled here
            } };
        }
        const ls = try left.toString(self.ctx.alloc);
        const rs = try right.toString(self.ctx.alloc);
        return Value{ .boolean = switch (op) {
            .eq => std.mem.eql(u8, ls, rs),
            .neq => !std.mem.eql(u8, ls, rs),
            else => return error.StringComparisonUnsupported,
        } };
    }

    // add_expr := cat_expr (('+' | '-') cat_expr)*
    fn parseAdd(self: *Parser) anyerror!Value {
        var left = try self.parseCat();
        while (true) {
            const t = try self.tok.peek();
            if (t.kind != .plus and t.kind != .minus) break;
            _ = try self.tok.next();
            const right = try self.parseCat();
            const l = left.toNumber() catch |err| {
                switch (left) { .string => |s| self.setNotANumber(s), else => {} }
                return err;
            };
            const r = right.toNumber() catch |err| {
                switch (right) { .string => |s| self.setNotANumber(s), else => {} }
                return err;
            };
            left = Value{ .number = if (t.kind == .plus) l + r else l - r };
        }
        return left;
    }

    // cat_expr := mul_expr ('&' mul_expr)*
    fn parseCat(self: *Parser) anyerror!Value {
        var left = try self.parseMul();
        while (true) {
            const t = try self.tok.peek();
            if (t.kind != .amp) break;
            _ = try self.tok.next();
            const right = try self.parseMul();
            const ls = try left.toString(self.ctx.alloc);
            const rs = try right.toString(self.ctx.alloc);
            left = Value{ .string = try std.mem.concat(self.ctx.alloc, u8, &.{ ls, rs }) };
        }
        return left;
    }

    // mul_expr := unary (('*' | '/') unary)*
    fn parseMul(self: *Parser) anyerror!Value {
        var left = try self.parseUnary();
        while (true) {
            const t = try self.tok.peek();
            if (t.kind != .star and t.kind != .slash) break;
            _ = try self.tok.next();
            const right = try self.parseUnary();
            const l = left.toNumber() catch |err| {
                switch (left) { .string => |s| self.setNotANumber(s), else => {} }
                return err;
            };
            const r = right.toNumber() catch |err| {
                switch (right) { .string => |s| self.setNotANumber(s), else => {} }
                return err;
            };
            if (t.kind == .slash) {
                // Division by zero silently produces an empty string rather than
                // crashing or surfacing an error. Many broker CSV files contain
                // rows where the divisor field is blank (e.g. unit price on a
                // cash deposit), and a crash or error message per row would be
                // far more disruptive than a blank output cell. Users who need
                // to detect zero-division can guard with IF([qty] != 0, ..., '').
                if (r == 0) {
                    left = Value{ .string = "" };
                } else {
                    left = Value{ .number = l / r };
                }
            } else {
                left = Value{ .number = l * r };
            }
        }
        return left;
    }

    // unary := '-' unary | primary
    fn parseUnary(self: *Parser) anyerror!Value {
        const t = try self.tok.peek();
        if (t.kind == .minus) {
            _ = try self.tok.next();
            const v = try self.parseUnary();
            const n = v.toNumber() catch |err| {
                switch (v) { .string => |s| self.setNotANumber(s), else => {} }
                return err;
            };
            return Value{ .number = -n };
        }
        return self.parsePrimary();
    }

    // primary := STRING_LIT | NUMBER | FIELD_REF | FUNC_CALL | '(' expr ')'
    fn parsePrimary(self: *Parser) anyerror!Value {
        const t = try self.tok.next();
        switch (t.kind) {
            .string_lit => return Value{ .string = t.text },
            .triple_quote => return Value{ .string = switch (self.ctx.quote_out) {
                '\'' => "'",
                '"' => "\"",
                else => "",
            } },
            .number_lit => return Value{ .number = try std.fmt.parseFloat(f80, t.text) },
            .field_ref => return self.evalFieldRef(t.text),
            .lparen => {
                const v = try self.parseExpr();
                const closing = try self.tok.next();
                if (closing.kind != .rparen) return error.ExpectedRParen;
                return v;
            },
            .ident => {
                // Capture the byte offset of the ident token in the original
                // source so the GUI's hover lookup can match `[src_start..)`
                // against the token's position. The text slice points into
                // self.tok.src, so subtraction gives the start offset.
                const name = t.text;
                const src_start = @intFromPtr(name.ptr) - @intFromPtr(self.tok.src.ptr);
                const result = try self.evalCall(name, t.offset, t.len);
                const src_end = self.tok.pos;
                self.emitCallTrace(name, src_start, src_end, result);
                return result;
            },
            else => {
                if (t.kind == .eof) {
                    self.setDetail("unexpected end of expression — expression may be incomplete", .{});
                } else {
                    self.setDetail("unexpected token '{s}' (kind: {s})", .{ t.text, @tagName(t.kind) });
                }
                return error.UnexpectedToken;
            },
        }
    }

    /// Resolves [ColumnName] or [n] (1-based index).
    /// When decimal_sep_in is not '.', numeric-looking field values are normalized
    /// so that the decimal separator becomes '.' for correct arithmetic evaluation.
    fn evalFieldRef(self: *Parser, name: []const u8) !Value {
        // Numeric index: [1], [2], ...
        const raw = if (std.fmt.parseInt(usize, name, 10)) |idx|
            self.ctx.field(idx - 1) // 1-based → 0-based
        else |_|
            self.ctx.fieldByName(name);

        // Record the field name so setNotANumber can include it in error
        // detail — "[Price]" in the message is far more actionable than
        // a bare "not a number: '1.234,56'" when decimal_sep_in is wrong.
        self.last_field_name = name;

        // Decimal separator normalisation for non-default locales. Two
        // shapes are recognised when `decimal_sep_in != '.'`:
        //
        //  * Plain decimal-only ("1234,56", "-1,5"): one alternate separator,
        //    digits otherwise. Validated by `isNumericWithSep`; converted by
        //    swapping the separator to '.'.
        //  * Grouped EU thousands ("1.234,56", "-1.234.567,89"): '.' groups of
        //    three digits + optional decimal. Validated by `parseGroupedNumber`
        //    with `thousands='.'`, `decimal=decimal_sep_in`; converted by
        //    stripping '.' and swapping the decimal char.
        //
        // Mirrors the American thousands fallback in `Value.toNumber`
        // (`parseGroupedNumber(s, ',', '.')`) — same algorithm, swapped
        // separators. Only allocate a copy when the field is genuinely a
        // recognised numeric shape; raw strings like "N/A" are returned as-is.
        if (self.ctx.decimal_sep_in != '.') {
            const sep = self.ctx.decimal_sep_in;
            if (parseGroupedNumber(raw, '.', sep)) |_| {
                const copy = try self.ctx.alloc.alloc(u8, raw.len);
                var ci: usize = 0;
                for (raw) |c| {
                    if (c == '.') continue;
                    copy[ci] = if (c == sep) '.' else c;
                    ci += 1;
                }
                return Value{ .string = copy[0..ci] };
            } else |_| {}
            if (std.mem.indexOfScalar(u8, raw, sep) != null and
                isNumericWithSep(raw, sep))
            {
                const copy = try self.ctx.alloc.dupe(u8, raw);
                std.mem.replaceScalar(u8, copy, sep, '.');
                return Value{ .string = copy };
            }
        }
        return Value{ .string = raw };
    }

    /// Returns true when s looks like a plain number using sep as decimal separator.
    /// Accepts: optional leading '-', digits, at most one sep, more digits.
    /// Rejects anything containing letters or other punctuation.
    fn isNumericWithSep(s: []const u8, sep: u8) bool {
        if (s.len == 0) return false;
        var i: usize = 0;
        if (s[i] == '-') i += 1;
        if (i >= s.len or !std.ascii.isDigit(s[i])) return false;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i < s.len and s[i] == sep) {
            i += 1;
            while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        }
        return i == s.len;
    }

    /// Advances the tokenizer past one complete sub-expression without evaluating it.
    /// Stops before the next ',' or ')' at depth 0 (does not consume the terminator).
    /// Used to skip the non-selected branch of IF.
    fn skipExpr(self: *Parser) !void {
        var depth: i32 = 0;
        while (true) {
            const t = try self.tok.peek();
            if (t.kind == .eof) return error.UnexpectedEof;
            if (t.kind == .comma and depth == 0) return;
            if (t.kind == .rparen) {
                if (depth == 0) return;
                depth -= 1;
            }
            if (t.kind == .lparen) depth += 1;
            _ = try self.tok.next();
        }
    }

    /// Dispatches function calls via the `builtins` catalog (single source of
    /// truth — see "Catalog" section near end of file). IF is the only lazy
    /// (short-circuit) builtin and is handled inline; everything else flows
    /// through eager arg evaluation + a uniform adapter table.
    /// `name_offset`/`name_len` carry the function-name token's source
    /// span so the UnknownFunction error site can highlight the
    /// function ident specifically rather than whatever token was
    /// last consumed (typically the closing `)` after arg parsing).
    fn evalCall(self: *Parser, name: []const u8, name_offset: u32, name_len: u32) anyerror!Value {
        // AND / OR handled as keywords in parseAnd/parseOr — if we see them
        // here as idents without a following '(', treat as boolean true/false.
        if (std.ascii.eqlIgnoreCase(name, "AND") or std.ascii.eqlIgnoreCase(name, "OR"))
            return error.UnexpectedKeyword;

        const lp = try self.tok.next();
        if (lp.kind != .lparen) return error.ExpectedLParen;

        // IF: lazy (short-circuit) — evaluate only the selected branch.
        if (std.ascii.eqlIgnoreCase(name, "IF")) {
            const cond = try self.parseExpr();
            if ((try self.tok.next()).kind != .comma) return error.ExpectedComma;
            if (cond.toBool()) {
                const yes = try self.parseExpr();
                if ((try self.tok.next()).kind != .comma) return error.ExpectedComma;
                try self.skipExpr(); // skip 'no' branch
                if ((try self.tok.next()).kind != .rparen) return error.ExpectedRParen;
                return yes;
            } else {
                try self.skipExpr(); // skip 'yes' branch
                if ((try self.tok.next()).kind != .comma) return error.ExpectedComma;
                const no = try self.parseExpr();
                if ((try self.tok.next()).kind != .rparen) return error.ExpectedRParen;
                return no;
            }
        }

        // Parse argument list (eagerly) for all other functions.
        // Args are held in an arena-backed list; the individual Value.string
        // slices may point into ctx.fields (no alloc) or into ctx.alloc-owned
        // strings (concat, date-format results, etc.). The list itself is freed
        // after the impl call; the strings it holds are either static or arena-
        // owned and will outlive the call frame.
        var args = std.array_list.Managed(Value).init(self.ctx.alloc);
        defer args.deinit();

        var t = try self.tok.peek();
        while (t.kind != .rparen and t.kind != .eof) {
            try args.append(try self.parseExpr());
            t = try self.tok.peek();
            if (t.kind == .comma) {
                _ = try self.tok.next();
                t = try self.tok.peek();
            }
        }
        _ = try self.tok.next(); // consume ')'

        // Linear scan over the catalog; case-insensitive name match.
        // Skips lazy entries (IF is handled above; any future lazy fn must add its
        // own special case before this loop).
        for (builtins) |b| {
            if (b.lazy) continue;
            if (std.ascii.eqlIgnoreCase(name, b.name)) {
                if (try self.validateArgs(b.doc, args.items)) |short_circuit|
                    return short_circuit;
                return b.impl.?(self, args.items);
            }
        }

        // Highlight the function-name ident specifically — by the
        // time we get here we've already consumed the closing `)`,
        // so `last_offset/len` would point at that. Override with
        // the name span captured in parsePrimary.
        self.tok.last_offset = name_offset;
        self.tok.last_len = name_len;
        self.setDetail("unknown function '{s}' — check function name spelling", .{name});
        return error.UnknownFunction;
    }

    /// Central argument validator — runs in `evalCall` before the builtin
    /// impl, enforcing the arity + per-arg domain contracts declared in
    /// `FnDoc`. Returns `null` to proceed to the impl, a `Value` to
    /// short-circuit the whole call (a bad `positive_integer` index resolves
    /// the call to ""), or propagates an error. May coerce `args` in place
    /// (range clamping). Impls downstream receive guaranteed-valid args, so
    /// new builtins are safe-by-construction once their FnDoc declares
    /// domains — see `ArgKind`.
    ///
    /// Failure policy is per-domain, chosen to preserve the historical
    /// behavior of the per-impl guards this centralises:
    ///   - `number` / `finite_number` → loud `error.NotANumber` attributed
    ///     to the offending arg (matches the old `adaptX` catch path).
    ///   - `positive_integer` → silent skip to "" (matches `toPositiveIndex`).
    ///   - `integer_in_range` → clamp finite values in place; non-finite /
    ///     non-numeric pass through untouched so the impl's own handling
    ///     (e.g. ROUND's "non-finite n returns f unchanged") still applies.
    fn validateArgs(self: *Parser, doc: FnDoc, args: []Value) !?Value {
        // Arity — replaces the per-impl `if (args.len != N)` checks.
        // max_args 0 = unspecified, 255 = variadic/unbounded: skip the cap.
        if (args.len < doc.min_args) return error.WrongArgCount;
        if (doc.max_args != 0 and doc.max_args != 255 and args.len > doc.max_args)
            return error.WrongArgCount;

        // Per-arg domain guards. Only declared positions are checked; extra
        // (variadic) args past `doc.args.len` carry no contract.
        for (doc.args, 0..) |a, i| {
            if (i >= args.len) break;
            switch (a.kind) {
                .expr, .string, .literal_string, .sunrise_format, .pre_pass_name => {},
                .number => _ = args[i].toNumber() catch {
                    switch (args[i]) {
                        .string => |s| self.setNotANumber(s),
                        else => {},
                    }
                    return error.NotANumber;
                },
                .finite_number => {
                    const n = args[i].toNumber() catch {
                        switch (args[i]) {
                            .string => |s| self.setNotANumber(s),
                            else => {},
                        }
                        return error.NotANumber;
                    };
                    if (!std.math.isFinite(n)) {
                        switch (args[i]) {
                            .string => |s| self.setNotANumber(s),
                            else => {},
                        }
                        return error.NotANumber;
                    }
                },
                .positive_integer => {
                    // Split failure policy, preserving historical behavior:
                    // non-numeric input → loud NotANumber; a valid number
                    // that is not a positive index (≤ 0 / non-finite) →
                    // silent skip to "".
                    const n = args[i].toNumber() catch {
                        switch (args[i]) {
                            .string => |s| self.setNotANumber(s),
                            else => {},
                        }
                        return error.NotANumber;
                    };
                    if (toPositiveIndex(n) == null) return Value{ .string = "" };
                },
                .integer_in_range => |r| {
                    if (args[i].toNumber()) |n| {
                        if (std.math.isFinite(n)) {
                            const lo: f80 = @floatFromInt(r.min);
                            const hi: f80 = @floatFromInt(r.max);
                            args[i] = .{ .number = @max(@min(@trunc(n), hi), lo) };
                        }
                    } else |_| {}
                },
            }
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Catalog types — exposed via `bxp-fmt --docs` for the GUI's expression
// catalog (functions / keywords / operators / tokens). Per-fn FnDoc
// declarations live RIGHT NEXT to each builtin impl + adapter further down,
// so adding a function in one place keeps doc/impl/adapter visibly in sync.
// The bottom `builtins` array just lists references to those named docs.
// ---------------------------------------------------------------------------

/// Per-arg semantic kind. Default `expr` means "any expression, no
/// special static check"; specialized kinds drive the generic
/// FnArgDoc-based static checker (see `staticCheckCallsCollect` below).
/// New kinds extend the catalog without touching dispatch sites in
/// `bxp-core/src/config.zig`.
/// Per-arg semantic domain — the single source of truth for argument
/// metadata. One declaration on a builtin's FnDoc drives all three
/// consumers: (a) the central runtime guard in `evalCall` (coerce / skip /
/// clamp before the impl runs), (b) the static literal checker
/// `staticCheckCalls` (config-load diagnostics), and (c) the
/// `bxp-fmt --docs` JSON the GUI autocomplete reads.
///
/// Runtime failure policy is chosen per variant to preserve the historical
/// observable behavior of the impls these guards replaced — see the
/// `validateArgs` table below. Adding a new builtin = declare its arg
/// domains here; it is then safe-by-construction (no per-impl validation).
///
/// A `union(enum)` (not a plain enum) because `integer_in_range` carries a
/// `{min,max}` payload. GUI-facing tag names (`expr`, `string`,
/// `literal_string`, `sunrise_format`, `pre_pass_name`) are deliberately
/// stable — `expr_editor.dart` keys placeholder quoting on them.
pub const ArgKind = union(enum) {
    /// Any expression — no runtime guard, no static check (default).
    expr,
    /// Coerces to a string via `toString` (never fails). Signals a
    /// string-typed arg for docs / autocomplete; no runtime guard needed.
    string,
    /// Bare string literal expected (validators may scan literal text).
    /// GUI wraps the autocomplete placeholder in quotes.
    literal_string,
    /// Bare string literal containing a sunrise-format pattern. Drives
    /// `expr.DateFormatBadToken` diagnostics for DATE_CONVERT arg[1]/arg[2].
    sunrise_format,
    /// Bare string literal naming a pre_pass block. Drives autocomplete
    /// in bxp-gui (no static check today — runtime-resolved via
    /// Context.pre_pass_names; documented for catalog completeness).
    pre_pass_name,
    /// Must coerce to a number via `toNumber`; failure → NotANumber
    /// (loud, attributed to the failing arg).
    number,
    /// Number that must be finite (no NaN/Inf); non-finite → NotANumber.
    finite_number,
    /// Integer ≥ 1, representable as a usize index. Static: bad literal
    /// (≤ 0 / non-representable) drives `expr.SplitPartBadIndex`. Runtime:
    /// `toPositiveIndex` guard — failure short-circuits the call to "".
    positive_integer,
    /// Finite integer clamped to `[min, max]` after truncation. Runtime:
    /// clamp (no skip). Mirrors the ROUND precision cap.
    integer_in_range: struct { min: i64, max: i64 },
};

pub const FnArgDoc = struct {
    name: []const u8,
    kind: ArgKind = .expr,
};

pub const FnDoc = struct {
    name: []const u8,
    signature: []const u8,
    description: []const u8,
    /// Per-arg metadata. Empty (default) means "no per-arg static
    /// checks / autocomplete hints declared". Populated entries drive
    /// the generic static checker + Dart autocomplete.
    args: []const FnArgDoc = &.{},
    /// Minimum arg count. 0 = unspecified (legacy default — does not
    /// drive WrongArgCount checks until populated). Set to args.len for
    /// fixed-arity functions; smaller for variadic minimums.
    min_args: u8 = 0,
    /// Maximum arg count. 0 = unspecified. 255 (= 0xFF) = unbounded
    /// (variadic). Otherwise set to args.len for fixed-arity.
    max_args: u8 = 0,
};

pub const KeywordDoc = struct {
    name: []const u8,
    description: []const u8,
};

pub const OperatorDoc = struct {
    token: []const u8,
    description: []const u8,
};

pub const TokenDoc = struct {
    kind: []const u8,
    syntax: []const u8,
    description: []const u8,
};

/// Adapter shape used by every eager builtin: receives the active Parser (for
/// ctx access + setDetail/setNotANumber error reporting) plus the evaluated
/// argument array, returns a Value or an error.
pub const FnImpl = *const fn (p: *Parser, args: []Value) anyerror!Value;

pub const FnEntry = struct {
    name: []const u8,
    /// When true, the dispatcher does not call `impl` — the function parses its
    /// own argument list via the Parser (used by IF for short-circuit eval).
    lazy: bool = false,
    doc: FnDoc,
    impl: ?FnImpl = null,
};

/// IF — lazy/short-circuit. The dispatcher matches IF by name BEFORE reaching
/// the table loop and parses its own arg list via Parser; no adapter exists.
const if_doc: FnDoc = .{
    .name = "IF",
    .signature = "IF(cond, yes, no)",
    .description = "Short-circuit conditional. Returns `yes` if `cond` is truthy, else `no`.",
    .args = &.{
        .{ .name = "cond" },
        .{ .name = "yes" },
        .{ .name = "no" },
    },
    .min_args = 3,
    .max_args = 3,
};

// ---------------------------------------------------------------------------
// Number parsing helpers
// ---------------------------------------------------------------------------

/// Parses a number in thousands-grouped format, generalised over both
/// American (`thousands=','`, `decimal='.'`) and European (`thousands='.'`,
/// `decimal=','`) conventions. Accepts:
///   `[-]?d{1,3}(<thousands>d{3})+(<decimal>d+)?`
/// Requires at least one thousands group — plain numbers without grouping
/// (`"123"`, `"1,5"`, `"1.5"`) are caller's `parseFloat` responsibility.
/// Returns `error.NotANumber` if `s` does not match the pattern for the
/// given separators.
///
/// The strict structural validation (1–3 leading digits, exactly 3 digits
/// per group, no trailing non-numeric characters) is intentional. It
/// prevents false positives on strings like `"2025,06,01"` (date
/// components) or American thousands input misread as a European number.
///
/// Examples:
///   parseGroupedNumber("1,234.56", ',', '.') → 1234.56  (American)
///   parseGroupedNumber("1.234,56", '.', ',') → 1234.56  (European)
///   parseGroupedNumber("-1.234.567,89", '.', ',') → -1234567.89
fn parseGroupedNumber(s: []const u8, thousands: u8, decimal: u8) error{NotANumber}!f80 {
    var i: usize = 0;
    if (i < s.len and s[i] == '-') i += 1;
    // 1–3 leading digits before the first thousands group
    const leading_start = i;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    const leading = i - leading_start;
    if (leading == 0 or leading > 3) return error.NotANumber;
    // At least one '<thousands>ddd' group required
    var groups: usize = 0;
    while (i < s.len and s[i] == thousands) {
        if (s.len < i + 4) return error.NotANumber;
        if (!std.ascii.isDigit(s[i + 1]) or
            !std.ascii.isDigit(s[i + 2]) or
            !std.ascii.isDigit(s[i + 3])) return error.NotANumber;
        i += 4;
        groups += 1;
        // A digit immediately after the group means >3 digits between separators → invalid
        if (i < s.len and std.ascii.isDigit(s[i])) return error.NotANumber;
    }
    if (groups == 0) return error.NotANumber;
    // Optional decimal part
    if (i < s.len) {
        if (s[i] != decimal) return error.NotANumber;
        i += 1;
        if (i >= s.len or !std.ascii.isDigit(s[i])) return error.NotANumber;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    }
    if (i != s.len) return error.NotANumber;
    // Strip thousands and rewrite the decimal char to '.' into a stack
    // buffer, then re-parse with the standard parseFloat. The 32-byte
    // buffer covers any input that fits in an f80 (f80 max ≈ 1.18×10^4932,
    // far beyond what 3+N*4 digits can express).
    var buf: [32]u8 = undefined;
    var bi: usize = 0;
    for (s) |c| {
        if (c == thousands) continue;
        if (bi >= buf.len) return error.NotANumber;
        buf[bi] = if (c == decimal) '.' else c;
        bi += 1;
    }
    return std.fmt.parseFloat(f80, buf[0..bi]) catch return error.NotANumber;
}

// ---------------------------------------------------------------------------
// Built-in function implementations
// ---------------------------------------------------------------------------

/// Convert a float to a 1-based positive integer index, or return null for
/// "silent skip" semantics (caller should return Value{ .string = "" }).
///
/// Gates THREE classes of input that `@intFromFloat` cannot handle safely:
///   - NaN          → IEEE comparisons return false, so `f < 1.0` does NOT
///                     filter it; `@intFromFloat(NaN)` is undefined behavior.
///   - +Inf / -Inf  → cast to usize is out-of-range, panics in Debug/Safe.
///   - f < 1.0      → would underflow on the typical `idx - 1` access.
///
/// Use this in every builtin that converts a user-supplied f80 to a usize
/// index (FIELDS, SPLIT_PART, future similar). Discovered by the
/// 2026-05-14 corpus probe (see DEV/6-todo-builtin-arg-validation-design.md).
fn toPositiveIndex(f: f80) ?usize {
    if (!std.math.isFinite(f) or f < 1.0) return null;
    return @as(usize, @intFromFloat(f));
}

/// Sane upper bound (in days) for date-offset arithmetic — ±10 000 years,
/// far beyond any realistic settlement / maturity offset. Bounds
/// `@intFromFloat` so a non-finite or absurd offset can't reach it.
const MAX_DATE_OFFSET_DAYS: i64 = 3_652_500;

/// Convert a user-supplied f80 day offset (DATEADD / WORKDAY arg `n`) to an
/// i64, or return null for "silent skip" — non-finite (NaN/Inf) or beyond
/// ±MAX_DATE_OFFSET_DAYS. Day offsets are always small (T+2, +30, +365), so
/// rejecting huge / non-finite values both prevents an `@intFromFloat`
/// out-of-range panic and matches the date builtins' "blank/invalid → ''"
/// contract. Non-numeric args are caught earlier by the `.number` domain.
fn toDayOffset(f: f80) ?i64 {
    if (!std.math.isFinite(f)) return null;
    const t = @trunc(f);
    if (t > @as(f80, MAX_DATE_OFFSET_DAYS) or t < -@as(f80, MAX_DATE_OFFSET_DAYS))
        return null;
    return @intFromFloat(t);
}

/// Maximum decimal precision a ROUND call will honour. f80 mantissa holds
/// ~19 decimal digits, so anything beyond that is numerical noise.
/// Caps `factor *= 10.0` (or `/= 10.0`) loop iterations to avoid DoS hangs
/// when a template author passes a huge precision arg (e.g. `'inf'`).
const ROUND_MAX_PRECISION: i32 = 30;

// ── ABS ─────────────────────────────────────────────────────────────────
const abs_doc: FnDoc = .{
    .name = "ABS",
    .signature = "ABS(f)",
    .description = "Absolute numeric value.",
    .args = &.{.{ .name = "f", .kind = .number }},
    .min_args = 1,
    .max_args = 1,
};
// Arity + the `.number` domain on `f` are enforced centrally in
// `validateArgs`, so the impl receives a guaranteed-numeric arg and the
// adapter no longer needs a NotANumber catch (plain signature forward).
fn builtinAbs(args: []Value) !Value {
    return Value{ .number = @abs(try args[0].toNumber()) };
}
fn adaptAbs(_: *Parser, args: []Value) anyerror!Value {
    return builtinAbs(args);
}

// ── FIELDS ──────────────────────────────────────────────────────────────
const fields_doc: FnDoc = .{
    .name = "FIELDS",
    .signature = "FIELDS(n)",
    .description = "Field value by 1-based column index. n must be a positive integer — use this when the column header is unknown or unstable; use the [ColumnName] syntax to look up by header name.",
    // `n` is `.positive_integer`: a literal `FIELDS(0)` / `FIELDS(-1)` is
    // statically flagged at config-load (1-based index contract, same as
    // SPLIT_PART / SUBSTR). A non-literal index that resolves to ≤ 0 / Inf
    // still silently returns "" at runtime via `toPositiveIndex` below.
    .args = &.{.{ .name = "n", .kind = .positive_integer }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinFields(args: []Value, ctx: *const Context) !Value {
    const idx = toPositiveIndex(try args[0].toNumber()) orelse
        return Value{ .string = "" };
    return Value{ .string = ctx.field(idx - 1) };
}
fn adaptFields(p: *Parser, args: []Value) anyerror!Value {
    return builtinFields(args, p.ctx);
}

/// stripCurrencySymbol strips a leading currency symbol (byte prefix) from s.
/// Returns the stripped slice and the ISO currency code, or null if no symbol matched.
/// Symbols: $ (1 byte), € (E2 82 AC, 3 bytes), £ (C2 A3, 2 bytes),
///          ¥ (C2 A5, 2 bytes), ₽ (E2 82 BD, 3 bytes).
fn stripCurrencySymbol(s: []const u8) ?struct { rest: []const u8, iso: []const u8 } {
    if (s.len > 0 and s[0] == '$') return .{ .rest = s[1..], .iso = "USD" };
    if (s.len >= 3 and s[0] == 0xE2 and s[1] == 0x82 and s[2] == 0xAC)
        return .{ .rest = s[3..], .iso = "EUR" }; // €
    if (s.len >= 2 and s[0] == 0xC2 and s[1] == 0xA3)
        return .{ .rest = s[2..], .iso = "GBP" }; // £
    if (s.len >= 2 and s[0] == 0xC2 and s[1] == 0xA5)
        return .{ .rest = s[2..], .iso = "JPY" }; // ¥
    if (s.len >= 3 and s[0] == 0xE2 and s[1] == 0x82 and s[2] == 0xBD)
        return .{ .rest = s[3..], .iso = "RUB" }; // ₽
    return null;
}

// ── PRICE_VALUE ─────────────────────────────────────────────────────────
const price_value_doc: FnDoc = .{
    .name = "PRICE_VALUE",
    .signature = "PRICE_VALUE(f)",
    .description = "Strip currency symbol or code from a price string, return the numeric part (e.g. \"$88744.27\" → \"88744.27\", \"€24.00\" → \"24.00\", \"24.00 CZK\" → \"24.00\").",
    .args = &.{.{ .name = "f", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
/// PRICE_VALUE("$88744.27") → "88744.27"
/// PRICE_VALUE("€24.00") → "24.00"
/// PRICE_VALUE("24.00 CZK") → "24.00"
/// The trailing-space split handles "amount ISO" format (e.g. "24.00 CZK"):
/// everything after the first space is dropped, returning just the numeric
/// part. If no space is present, the whole trimmed string is returned.
fn builtinPriceValue(args: []Value) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    var r = std.mem.trim(u8, s, " ");
    if (stripCurrencySymbol(r)) |m| r = m.rest;
    if (std.mem.indexOfScalar(u8, r, ' ')) |i| r = r[0..i];
    return Value{ .string = r };
}
fn adaptPriceValue(_: *Parser, args: []Value) anyerror!Value {
    return builtinPriceValue(args);
}

// ── PRICE_CURRENCY ──────────────────────────────────────────────────────
const price_currency_doc: FnDoc = .{
    .name = "PRICE_CURRENCY",
    .signature = "PRICE_CURRENCY(f)",
    .description = "Extract currency code from a price string (e.g. \"EUR\", \"USD\").",
    .args = &.{.{ .name = "f", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
/// PRICE_CURRENCY("$88744.27") → "USD"
/// PRICE_CURRENCY("€24.00") → "EUR"
/// PRICE_CURRENCY("24.00 CZK") → "CZK"
/// For the symbol-prefix case the ISO code is hard-coded in stripCurrencySymbol.
/// For the "amount ISO" trailing format the code is everything after the first
/// space. If neither form is matched the field contains no identifiable currency
/// symbol and the function returns "". Callers should use COALESCE or IF to
/// supply a fallback when the format may be ambiguous.
fn builtinPriceCurrency(args: []Value) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const r = std.mem.trim(u8, s, " ");
    if (stripCurrencySymbol(r)) |m| return Value{ .string = m.iso };
    if (std.mem.indexOfScalar(u8, r, ' ')) |i| return Value{ .string = r[i + 1 ..] };
    return Value{ .string = "" };
}
fn adaptPriceCurrency(_: *Parser, args: []Value) anyerror!Value {
    return builtinPriceCurrency(args);
}

// ── TICKER ──────────────────────────────────────────────────────────────
const ticker_doc: FnDoc = .{
    .name = "TICKER",
    .signature = "TICKER(f)",
    .description = "Map field value through the template's `ticker_map` (per-template config block that translates broker-specific symbols to canonical tickers, e.g. \"VOW.DE\" → \"VOW.DE.XETRA\"). Returns value unchanged if not found.",
    .args = &.{.{ .name = "f", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
/// TICKER(field) — look up in ticker_map, return as-is if not found.
fn builtinTicker(args: []Value, ctx: *const Context) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    return Value{ .string = ctx.ticker_map.get(s) orelse s };
}
fn adaptTicker(p: *Parser, args: []Value) anyerror!Value {
    return builtinTicker(args, p.ctx);
}

// ── LOOKUP ──────────────────────────────────────────────────────────────
const lookup_doc: FnDoc = .{
    .name = "LOOKUP",
    .signature = "LOOKUP([name,] key, field)",
    .description = "Retrieve a value stored by a pre_pass table. 3-arg form `LOOKUP(name, key, field)` selects the named pre_pass block. 2-arg form `LOOKUP(key, field)` works only when exactly one pre_pass block is defined.",
    // Variadic 2/3 args; per-arg roles depend on arity (3-arg: name/key/field,
    // 2-arg: key/field with implicit name). The catalog declares the 3-arg
    // shape — bxp-gui autocomplete suggests pre_pass names for arg[0] when
    // the user is mid-typing a 3-arg call. Static name-resolution is
    // runtime-only via Context.pre_pass_names (no static check here).
    .args = &.{
        .{ .name = "name", .kind = .pre_pass_name },
        .{ .name = "key", .kind = .expr },
        .{ .name = "field", .kind = .literal_string },
    },
    .min_args = 2,
    .max_args = 3,
};
/// LOOKUP — reads a value stored by pre_pass.
///   3-arg: LOOKUP(name, key, field)  — explicit pre_pass name.
///   2-arg: LOOKUP(key, field)        — only when a single pre_pass is defined;
///                                      its name is taken from ctx.single_prepass_name.
/// The lookup table uses composite keys "name\x00key\x00field".
/// Returns empty string if no pre_pass table is present or key/field not found.
fn builtinLookup(args: []Value, ctx: *const Context) !Value {
    // Validate-mode (Phase G3): when the deep-pass deepens with a
    // populated `pre_pass_names` whitelist, resolve the first argument
    // immediately and flag unknown names. Runtime callers leave
    // `pre_pass_names` null and skip this branch entirely, preserving
    // the historical "silent '' on miss" contract that bxp-fmt --expr
    // also relies on (LOOKUP in bare contexts must not blow up).
    if (ctx.pre_pass_names) |names| {
        const name: []const u8 = if (args.len == 3) switch (args[0]) {
            .string => |v| v,
            else => return error.StringExpected,
        } else ctx.single_prepass_name orelse return error.LookupRequiresName;
        if (!names.contains(name)) return error.LookupUnknownPrePass;
        return Value{ .string = "" };
    }
    // No lookup_table → either validation context (bxp-fmt --expr) or runtime
    // without any pre_pass defined. Both cases existed pre-namespacing and
    // returned empty so validators don't choke on bare LOOKUP(...) exprs.
    const table = ctx.lookup_table orelse return Value{ .string = "" };
    const name: []const u8 = if (args.len == 3) switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    } else ctx.single_prepass_name orelse return error.LookupRequiresName;
    const key_idx: usize = if (args.len == 3) 1 else 0;
    const field_idx: usize = if (args.len == 3) 2 else 1;
    const key = switch (args[key_idx]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const field = switch (args[field_idx]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const composite = try std.mem.concat(ctx.alloc, u8, &.{ name, "\x00", key, "\x00", field });
    return Value{ .string = table.get(composite) orelse "" };
}
fn adaptLookup(p: *Parser, args: []Value) anyerror!Value {
    return builtinLookup(args, p.ctx) catch |err| {
        switch (err) {
            error.LookupRequiresName => p.setDetail(
                "LOOKUP requires explicit name when multiple pre_passes are defined", .{}),
            error.LookupUnknownPrePass => {
                const name: []const u8 = if (args.len == 3) switch (args[0]) {
                    .string => |v| v,
                    else => "",
                } else (p.ctx.single_prepass_name orelse "");
                p.setDetail("unknown pre_pass '{s}' — check pre_passes block name", .{name});
            },
            else => {},
        }
        return err;
    };
}

// ── SPLIT_PART ──────────────────────────────────────────────────────────
const split_part_doc: FnDoc = .{
    .name = "SPLIT_PART",
    .signature = "SPLIT_PART(s, delim, n)",
    .description = "Return the n-th part of `s` split by `delim` (1-based index). Returns \"\" when n exceeds the part count, when `delim` is empty, or when `n` ≤ 0. When `delim` is not found, n=1 returns the whole string and n>1 returns \"\".",
    .args = &.{
        .{ .name = "s", .kind = .string },
        .{ .name = "delim", .kind = .string },
        .{ .name = "n", .kind = .positive_integer },
    },
    .min_args = 3,
    .max_args = 3,
};
/// SPLIT_PART(string, delimiter, n) — split string by delimiter, return nth part (1-based).
/// Returns "" when fewer than n parts exist or delimiter is empty.
fn builtinSplitPart(args: []Value) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const delim = switch (args[1]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    // SPLIT_PART is 1-based; anything < 1 (or non-finite Inf/NaN, or
    // empty delim) returns "" by spec. toPositiveIndex gates all the
    // @intFromFloat-unsafe cases (NaN, Inf, < 1.0) in one place.
    if (delim.len == 0) return Value{ .string = "" };
    const n = toPositiveIndex(try args[2].toNumber()) orelse
        return Value{ .string = "" };

    var rest = s;
    var part: usize = 1;
    while (true) {
        if (part == n) {
            // Return from rest up to the next delimiter (or end of string).
            const end = std.mem.indexOf(u8, rest, delim) orelse return Value{ .string = rest };
            return Value{ .string = rest[0..end] };
        }
        const pos = std.mem.indexOf(u8, rest, delim) orelse return Value{ .string = "" };
        rest = rest[pos + delim.len ..];
        part += 1;
    }
}
fn adaptSplitPart(_: *Parser, args: []Value) anyerror!Value {
    return builtinSplitPart(args);
}

// ── CONTAINS ────────────────────────────────────────────────────────────
const contains_doc: FnDoc = .{
    .name = "CONTAINS",
    .signature = "CONTAINS(haystack, needle)",
    .description = "Returns \"true\" if `haystack` contains `needle`, else \"false\".",
    .args = &.{
        .{ .name = "haystack", .kind = .string },
        .{ .name = "needle", .kind = .string },
    },
    .min_args = 2,
    .max_args = 2,
};
/// CONTAINS(string, substring) → bool — true when substring is found inside string.
fn builtinContains(args: []Value) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const sub = switch (args[1]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    return Value{ .boolean = std.mem.indexOf(u8, s, sub) != null };
}
fn adaptContains(_: *Parser, args: []Value) anyerror!Value {
    return builtinContains(args);
}

// ── REPLACE ─────────────────────────────────────────────────────────────
const replace_doc: FnDoc = .{
    .name = "REPLACE",
    .signature = "REPLACE(s, from, to)",
    .description = "Replace all occurrences of `from` in `s` with `to` (case-sensitive byte match). Returns `s` unchanged when `from` is empty.",
    .args = &.{
        .{ .name = "s", .kind = .string },
        .{ .name = "from", .kind = .string },
        .{ .name = "to", .kind = .string },
    },
    .min_args = 3,
    .max_args = 3,
};
/// REPLACE(string, old, new) — replace all occurrences of old with new.
fn builtinReplace(args: []Value, alloc: std.mem.Allocator) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const old = switch (args[1]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const new = switch (args[2]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    if (old.len == 0) return Value{ .string = s };
    return Value{ .string = try std.mem.replaceOwned(u8, alloc, s, old, new) };
}
fn adaptReplace(p: *Parser, args: []Value) anyerror!Value {
    return builtinReplace(args, p.ctx.alloc);
}

// ── NOW ─────────────────────────────────────────────────────────────────
const now_doc: FnDoc = .{
    .name = "NOW",
    .signature = "NOW()",
    .description = "Current UTC datetime as ISO 8601 string (YYYY-MM-DDTHH:MM:SSZ).",
    .args = &.{},
    .min_args = 0,
    .max_args = 0,
};
/// NOW() — current UTC datetime as ISO 8601 string: YYYY-MM-DDTHH:MM:SSZ.
fn builtinNow(args: []Value, alloc: std.mem.Allocator) !Value {
    if (args.len != 0) return error.WrongArgCount;
    const epoch = std.time.epoch;
    const secs: u64 = @intCast(std.time.timestamp());
    const es = epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay();
    const time = es.getDaySeconds();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    return Value{ .string = try std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    }) };
}
fn adaptNow(p: *Parser, args: []Value) anyerror!Value {
    return builtinNow(args, p.ctx.alloc);
}

// ── TRIM ────────────────────────────────────────────────────────────────
const trim_doc: FnDoc = .{
    .name = "TRIM",
    .signature = "TRIM(f)",
    .description = "Strip leading and trailing whitespace from a string.",
    .args = &.{.{ .name = "f", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
/// TRIM(f) — strip leading and trailing whitespace (spaces, tabs, CR, LF).
fn builtinTrim(args: []Value) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return args[0],
    };
    return Value{ .string = std.mem.trim(u8, s, " \t\r\n") };
}
fn adaptTrim(_: *Parser, args: []Value) anyerror!Value {
    return builtinTrim(args);
}

// ── ROUND ───────────────────────────────────────────────────────────────
const round_doc: FnDoc = .{
    .name = "ROUND",
    .signature = "ROUND(f, n)",
    .description = "Round `f` to `n` decimal places (half-away-from-zero). `n=0` rounds to the nearest integer; `n<0` rounds to tens/hundreds/etc. (`n=-2` → nearest 100). `n` is clamped to ±30 to bound CPU; non-finite `n` (NaN/Inf) returns `f` unchanged.",
    .args = &.{
        .{ .name = "f", .kind = .number },
        .{ .name = "n", .kind = .{ .integer_in_range = .{
            .min = -@as(i64, ROUND_MAX_PRECISION),
            .max = @as(i64, ROUND_MAX_PRECISION),
        } } },
    },
    .min_args = 2,
    .max_args = 2,
};
/// ROUND(f, n) — round f to n decimal places.
/// n >= 0: round to n places after decimal point; n < 0: round to tens/hundreds/etc.
/// `validateArgs` clamps a finite `n` to ±ROUND_MAX_PRECISION (the
/// integer_in_range domain) before this runs; the local clamp below stays
/// as defence-in-depth and to handle the non-finite passthrough case.
fn builtinRound(args: []Value) !Value {
    const x = try args[0].toNumber();
    const n_f = @trunc(try args[1].toNumber());
    // Gate non-finite precision (NaN/Inf) — silent skip, return x unchanged.
    // Also cap at ±ROUND_MAX_PRECISION to avoid a 10⁹-iteration DoS hang
    // when an arg evaluates to a huge number.
    if (!std.math.isFinite(n_f)) return Value{ .number = x };
    const n_clamped = @max(@min(n_f, @as(f80, ROUND_MAX_PRECISION)), -@as(f80, ROUND_MAX_PRECISION));
    const n: i32 = @intFromFloat(n_clamped);
    var factor: f80 = 1.0;
    if (n >= 0) {
        for (0..@intCast(n)) |_| factor *= 10.0;
    } else {
        for (0..@intCast(-n)) |_| factor /= 10.0;
    }
    return Value{ .number = @round(x * factor) / factor };
}
fn adaptRound(p: *Parser, args: []Value) anyerror!Value {
    return builtinRound(args) catch |err| {
        if (args.len >= 1) switch (args[0]) { .string => |s| p.setNotANumber(s), else => {} };
        return err;
    };
}

// ── FLOOR ───────────────────────────────────────────────────────────────
const floor_doc: FnDoc = .{
    .name = "FLOOR",
    .signature = "FLOOR(f)",
    .description = "Round `f` down to nearest integer.",
    .args = &.{.{ .name = "f", .kind = .number }},
    .min_args = 1,
    .max_args = 1,
};
/// FLOOR(f) — largest integer less than or equal to f.
fn builtinFloor(args: []Value) !Value {
    return Value{ .number = @floor(try args[0].toNumber()) };
}
fn adaptFloor(_: *Parser, args: []Value) anyerror!Value {
    return builtinFloor(args);
}

// ── CEILING ─────────────────────────────────────────────────────────────
const ceiling_doc: FnDoc = .{
    .name = "CEILING",
    .signature = "CEILING(f)",
    .description = "Round `f` up to nearest integer.",
    .args = &.{.{ .name = "f", .kind = .number }},
    .min_args = 1,
    .max_args = 1,
};
/// CEILING(f) — smallest integer greater than or equal to f.
fn builtinCeiling(args: []Value) !Value {
    return Value{ .number = @ceil(try args[0].toNumber()) };
}
fn adaptCeiling(_: *Parser, args: []Value) anyerror!Value {
    return builtinCeiling(args);
}

// ── RAND ────────────────────────────────────────────────────────────────
const rand_doc: FnDoc = .{
    .name = "RAND",
    .signature = "RAND()",
    .description = "Random float in [0, 1).",
    .args = &.{},
    .min_args = 0,
    .max_args = 0,
};
/// RAND() — cryptographically random float in [0, 1).
fn builtinRand(args: []Value) !Value {
    if (args.len != 0) return error.WrongArgCount;
    return Value{ .number = @floatCast(std.crypto.random.float(f64)) };
}
fn adaptRand(_: *Parser, args: []Value) anyerror!Value {
    return builtinRand(args);
}

// ── COALESCE ────────────────────────────────────────────────────────────
const coalesce_doc: FnDoc = .{
    .name = "COALESCE",
    .signature = "COALESCE(a, b, ...)",
    .description = "First non-empty argument (empty = whitespace-only string). Returns last argument verbatim as fallback.",
    // Variadic 1+ args, all expr. Catalog declares the first arg as
    // documentation; trailing args inherit `kind = .expr` semantically.
    .args = &.{.{ .name = "a" }},
    .min_args = 1,
    .max_args = 255,
};
/// COALESCE(a, b, ...) — return the first non-empty argument.
/// A string is considered empty if its trimmed length is 0 (whitespace-only
/// counts as empty). Numbers and booleans are never empty — even 0 and false
/// are returned. If every argument is empty, the last argument is returned
/// verbatim so callers can supply a default: COALESCE(@a, @b, "0").
///
/// The loop intentionally excludes the last argument so it's always returned
/// as-is — this guarantees that COALESCE(x, '') returns '' instead of the
/// first non-empty, which matches the "last arg is the fallback" contract.
fn builtinCoalesce(args: []Value) !Value {
    for (args[0 .. args.len - 1]) |v| {
        switch (v) {
            .string => |s| {
                if (std.mem.trim(u8, s, " \t\r\n").len > 0) return v;
            },
            .number, .boolean => return v,
        }
    }
    return args[args.len - 1];
}
fn adaptCoalesce(_: *Parser, args: []Value) anyerror!Value {
    return builtinCoalesce(args);
}

// ── DATE_CONVERT ────────────────────────────────────────────────────────
const date_convert_doc: FnDoc = .{
    .name = "DATE_CONVERT",
    .signature = "DATE_CONVERT(f, from, to)",
    .description = "Reformat a date/time string. Format tokens: YYYY (year), MM/M (month), MMM/MMMM (month name), DD/D (day), hh/h (hour), mm/m (minute), ss/s (second), [literal] (literal characters), [*] (wildcard).",
    .args = &.{
        .{ .name = "f", .kind = .string },
        .{ .name = "from", .kind = .sunrise_format },
        .{ .name = "to", .kind = .sunrise_format },
    },
    .min_args = 3,
    .max_args = 3,
};
/// Parses the input string according to from_fmt, then formats the result
/// according to to_fmt.  Both format strings use sunrise token syntax:
///   YYYY  MM/M  MMM/MMMM  DD/D  hh/h  mm/m  ss/s  [literal]  [*]=wildcard
/// See the sunrise library documentation for the full token list.
///
/// When from_fmt contains the MMM token, the input is pre-processed by
/// normalizeMonthAbbrev to handle non-standard 4-character month abbreviations
/// (e.g. "Sept" → "Sep") before passing to sunrise.
fn builtinDateConvert(args: []Value, alloc: std.mem.Allocator) !Value {
    const input = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const from_fmt = switch (args[1]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const to_fmt = switch (args[2]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    // Pre-process 4-character month abbreviations (e.g. "Sept", "June") into
    // the 3-character form that sunrise expects. Allocation happens only when
    // the input actually contains a matching word — the common case (no MMM
    // token in from_fmt) skips the work entirely.
    const normalized = if (containsMMM(from_fmt))
        try normalizeMonthAbbrev(input, alloc)
    else
        input;
    // Parse failures silently produce an empty string (no warning, no summary entry).
    // Rationale: broker files frequently contain rows where a date field is blank
    // (e.g. a cash row that has no settlement date). A silent "" is preferable to
    // an error that aborts processing of every subsequent row in the file.
    const dt = sunrise.DateTime.parse(normalized, .{ .format = from_fmt }) catch {
        return Value{ .string = "" };
    };
    return Value{ .string = try dt.format(alloc, to_fmt) };
}
fn adaptDateConvert(p: *Parser, args: []Value) anyerror!Value {
    return builtinDateConvert(args, p.ctx.alloc) catch |err| {
        if (args.len >= 1) switch (args[0]) {
            .string => |s| p.setDetail("DATE_CONVERT: {s} — input \"{s}\"", .{ @errorName(err), s }),
            else => {},
        };
        return err;
    };
}

/// Returns true if fmt contains the MMM token (exactly 3 M's, not part of MMMM).
/// MMMM is the full month-name token and does NOT trigger month-abbreviation
/// normalisation — it expects the full name ("September") and sunrise handles it
/// natively. Only MMM (abbreviated: "Sep") needs our pre-processing step because
/// some brokers export 4-letter variants that sunrise doesn't recognise.
fn containsMMM(fmt: []const u8) bool {
    var i: usize = 0;
    while (i + 3 <= fmt.len) {
        if (std.mem.eql(u8, fmt[i .. i + 3], "MMM")) {
            if (i + 3 < fmt.len and fmt[i + 3] == 'M') {
                i += 4; // skip MMMM
            } else {
                return true;
            }
        } else {
            i += 1;
        }
    }
    return false;
}

/// Returns a copy of s with any 4-character month abbreviations trimmed to 3
/// characters (e.g. "Sept" → "Sep", "June" → "Jun").  Allocates only when a
/// replacement is actually needed; returns the original slice otherwise.
fn normalizeMonthAbbrev(s: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    const abbrevs = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };

    // First pass: check whether any fix is needed before allocating.
    var needs_fix = false;
    var i: usize = 0;
    check: while (i < s.len) {
        if (!std.ascii.isAlphabetic(s[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < s.len and std.ascii.isAlphabetic(s[i])) i += 1;
        if (i - start == 4) {
            for (abbrevs) |a| {
                if (std.ascii.eqlIgnoreCase(s[start .. start + 3], a)) {
                    needs_fix = true;
                    break :check;
                }
            }
        }
    }
    if (!needs_fix) return s;

    // Second pass: build a new string with 4-char abbreviations trimmed to 3.
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    i = 0;
    while (i < s.len) {
        if (!std.ascii.isAlphabetic(s[i])) {
            try out.append(s[i]);
            i += 1;
            continue;
        }
        const start = i;
        while (i < s.len and std.ascii.isAlphabetic(s[i])) i += 1;
        const word = s[start..i];
        var trimmed = false;
        if (word.len == 4) {
            for (abbrevs) |a| {
                if (std.ascii.eqlIgnoreCase(word[0..3], a)) {
                    try out.appendSlice(word[0..3]);
                    trimmed = true;
                    break;
                }
            }
        }
        if (!trimmed) try out.appendSlice(word);
    }
    return out.toOwnedSlice();
}

// ── LEFT ────────────────────────────────────────────────────────────────
const left_doc: FnDoc = .{
    .name = "LEFT",
    .signature = "LEFT(s, n)",
    .description = "Return the first `n` bytes of `s`. `n` is clamped to `[0, len(s)]`; non-finite `n` (NaN/Inf) or negative `n` returns \"\".",
    .args = &.{
        .{ .name = "s", .kind = .string },
        .{ .name = "n", .kind = .number },
    },
    .min_args = 2,
    .max_args = 2,
};
fn builtinLeft(args: []Value) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const nf = try args[1].toNumber();
    if (!std.math.isFinite(nf) or nf < 0) return Value{ .string = "" };
    const clamped = @min(nf, @as(f80, @floatFromInt(s.len)));
    const n: usize = @intFromFloat(clamped);
    return Value{ .string = s[0..n] };
}
fn adaptLeft(_: *Parser, args: []Value) anyerror!Value {
    return builtinLeft(args);
}

// ── RIGHT ───────────────────────────────────────────────────────────────
const right_doc: FnDoc = .{
    .name = "RIGHT",
    .signature = "RIGHT(s, n)",
    .description = "Return the last `n` bytes of `s`. `n` is clamped to `[0, len(s)]`; non-finite `n` (NaN/Inf) or negative `n` returns \"\".",
    .args = &.{
        .{ .name = "s", .kind = .string },
        .{ .name = "n", .kind = .number },
    },
    .min_args = 2,
    .max_args = 2,
};
fn builtinRight(args: []Value) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const nf = try args[1].toNumber();
    if (!std.math.isFinite(nf) or nf < 0) return Value{ .string = "" };
    const clamped = @min(nf, @as(f80, @floatFromInt(s.len)));
    const n: usize = @intFromFloat(clamped);
    return Value{ .string = s[s.len - n ..] };
}
fn adaptRight(_: *Parser, args: []Value) anyerror!Value {
    return builtinRight(args);
}

// ── SUBSTR ──────────────────────────────────────────────────────────────
const substr_doc: FnDoc = .{
    .name = "SUBSTR",
    .signature = "SUBSTR(s, start, length)",
    .description = "Return `length` bytes from `s` starting at 1-based position `start`. Returns \"\" when `start` is non-positive / non-finite / past end of `s`, or when `length` is non-positive / non-finite. `length` is clamped to the bytes remaining from `start`.",
    .args = &.{
        .{ .name = "s", .kind = .string },
        .{ .name = "start", .kind = .positive_integer },
        .{ .name = "length", .kind = .number },
    },
    .min_args = 3,
    .max_args = 3,
};
fn builtinSubstr(args: []Value) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const start = toPositiveIndex(try args[1].toNumber()) orelse
        return Value{ .string = "" };
    const lenf = try args[2].toNumber();
    if (!std.math.isFinite(lenf) or lenf < 0) return Value{ .string = "" };
    if (start > s.len) return Value{ .string = "" };
    const begin = start - 1;
    const avail = s.len - begin;
    const clamped = @min(lenf, @as(f80, @floatFromInt(avail)));
    const len: usize = @intFromFloat(clamped);
    return Value{ .string = s[begin .. begin + len] };
}
fn adaptSubstr(_: *Parser, args: []Value) anyerror!Value {
    return builtinSubstr(args);
}

// ── UPPER ───────────────────────────────────────────────────────────────
const upper_doc: FnDoc = .{
    .name = "UPPER",
    .signature = "UPPER(s)",
    .description = "ASCII upper-case conversion: bytes a–z become A–Z; all other bytes (including non-ASCII UTF-8) pass through unchanged.",
    .args = &.{.{ .name = "s", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinUpper(args: []Value, alloc: std.mem.Allocator) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const buf = try alloc.alloc(u8, s.len);
    for (s, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return Value{ .string = buf };
}
fn adaptUpper(p: *Parser, args: []Value) anyerror!Value {
    return builtinUpper(args, p.ctx.alloc);
}

// ── LOWER ───────────────────────────────────────────────────────────────
const lower_doc: FnDoc = .{
    .name = "LOWER",
    .signature = "LOWER(s)",
    .description = "ASCII lower-case conversion: bytes A–Z become a–z; all other bytes (including non-ASCII UTF-8) pass through unchanged.",
    .args = &.{.{ .name = "s", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinLower(args: []Value, alloc: std.mem.Allocator) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const buf = try alloc.alloc(u8, s.len);
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return Value{ .string = buf };
}
fn adaptLower(p: *Parser, args: []Value) anyerror!Value {
    return builtinLower(args, p.ctx.alloc);
}

// ── STARTS_WITH ─────────────────────────────────────────────────────────
const starts_with_doc: FnDoc = .{
    .name = "STARTS_WITH",
    .signature = "STARTS_WITH(s, prefix)",
    .description = "Return \"true\" when `s` begins with `prefix` (case-sensitive byte match), else \"false\". An empty `prefix` always matches.",
    .args = &.{
        .{ .name = "s", .kind = .string },
        .{ .name = "prefix", .kind = .string },
    },
    .min_args = 2,
    .max_args = 2,
};
fn builtinStartsWith(args: []Value) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const prefix = switch (args[1]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    return Value{ .boolean = std.mem.startsWith(u8, s, prefix) };
}
fn adaptStartsWith(_: *Parser, args: []Value) anyerror!Value {
    return builtinStartsWith(args);
}

// ── ENDS_WITH ───────────────────────────────────────────────────────────
const ends_with_doc: FnDoc = .{
    .name = "ENDS_WITH",
    .signature = "ENDS_WITH(s, suffix)",
    .description = "Return \"true\" when `s` ends with `suffix` (case-sensitive byte match), else \"false\". An empty `suffix` always matches.",
    .args = &.{
        .{ .name = "s", .kind = .string },
        .{ .name = "suffix", .kind = .string },
    },
    .min_args = 2,
    .max_args = 2,
};
fn builtinEndsWith(args: []Value) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const suffix = switch (args[1]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    return Value{ .boolean = std.mem.endsWith(u8, s, suffix) };
}
fn adaptEndsWith(_: *Parser, args: []Value) anyerror!Value {
    return builtinEndsWith(args);
}

// ── NULLIF ──────────────────────────────────────────────────────────────
const nullif_doc: FnDoc = .{
    .name = "NULLIF",
    .signature = "NULLIF(value, sentinel)",
    .description = "Return `\"\"` when `value` equals `sentinel`, otherwise return `value`. Equality is numeric when both sides parse as numbers, otherwise byte-exact string compare — mirrors the `=` operator. Typical use: collapse sentinel values such as `\"-9999\"`, `\"\\N\"`, `\"N/A\"` to empty.",
    .args = &.{
        .{ .name = "value" },
        .{ .name = "sentinel" },
    },
    .min_args = 2,
    .max_args = 2,
};
/// NULLIF semantics match SQL: NULLIF(x, y) → NULL if x = y else x. bxp
/// has no NULL — empty string is the equivalent (numeric ctx coerces it
/// to 0, string ctx leaves it as ""). Compare numerically first, fall
/// back to string equality, mirroring parseCmp's `=` operator.
fn builtinNullif(args: []Value, alloc: std.mem.Allocator) !Value {
    const ln = args[0].toNumber() catch null;
    const rn = args[1].toNumber() catch null;
    if (ln != null and rn != null) {
        if (ln.? == rn.?) return Value{ .string = "" };
        return args[0];
    }
    const ls = try args[0].toString(alloc);
    const rs = try args[1].toString(alloc);
    if (std.mem.eql(u8, ls, rs)) return Value{ .string = "" };
    return args[0];
}
fn adaptNullif(p: *Parser, args: []Value) anyerror!Value {
    return builtinNullif(args, p.ctx.alloc);
}

// ── IN ──────────────────────────────────────────────────────────────────
const in_doc: FnDoc = .{
    .name = "IN",
    .signature = "IN(value, v1, v2, ...)",
    .description = "Return \"true\" when `value` equals any of `v1, v2, …`. Equality is numeric when both sides parse as numbers, otherwise byte-exact string compare — mirrors the `=` operator. Variadic 2+ args.",
    .args = &.{
        .{ .name = "value" },
        .{ .name = "v1" },
    },
    .min_args = 2,
    .max_args = 255,
};
/// IN(value, v1, v2, ...) — variadic equality OR-chain. Replaces nested
/// `IF([X] = 'A' OR [X] = 'B' OR ..., ...)` patterns. Equality semantics
/// match `=` operator (numeric first, then string).
fn builtinIn(args: []Value, alloc: std.mem.Allocator) !Value {
    const ln = args[0].toNumber() catch null;
    const ls_lazy: ?[]const u8 = null;
    var ls: ?[]const u8 = ls_lazy;
    for (args[1..]) |opt| {
        if (ln) |l| {
            if (opt.toNumber() catch null) |r| {
                if (l == r) return Value{ .boolean = true };
                continue;
            }
        }
        // Either value is non-numeric, or this option doesn't parse as
        // a number → fall back to string equality. Materialise the
        // stringified value on first need.
        if (ls == null) ls = try args[0].toString(alloc);
        const rs = try opt.toString(alloc);
        if (std.mem.eql(u8, ls.?, rs)) return Value{ .boolean = true };
    }
    return Value{ .boolean = false };
}
fn adaptIn(p: *Parser, args: []Value) anyerror!Value {
    return builtinIn(args, p.ctx.alloc);
}

// ---------------------------------------------------------------------------
// Date helpers — shared by YEAR/MONTH/DAY/WEEKDAY/DATEADD/DATEDIFF/WORKDAY/
// EOMONTH. All inputs must be canonical "YYYY-MM-DD" strings; chain via
// DATE_CONVERT() when the source uses a different format.
//
// Empty-input contract: every date builtin returns the empty string ""
// silently when its date argument is empty. This mirrors DATE_CONVERT's
// rationale (broker rows often have blank settlement/value-date fields and
// a hard error would abort processing of every subsequent row).
// Malformed non-empty input still surfaces InvalidDate with a clickable
// diagnostic so typo'd templates fail loudly.
//
// Uses Howard Hinnant's `days_from_civil` / `civil_from_days` algorithm —
// branch-free O(1), exact across the entire i32 year range, handles leap
// years and negative dates without table lookups. Source:
// https://howardhinnant.github.io/date_algorithms.html#days_from_civil
// ---------------------------------------------------------------------------

const DateParts = struct { year: i32, month: u32, day: u32 };

fn parseYmd(s: []const u8) !DateParts {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return error.InvalidDate;
    const y = std.fmt.parseInt(i32, s[0..4], 10) catch return error.InvalidDate;
    const m = std.fmt.parseInt(u32, s[5..7], 10) catch return error.InvalidDate;
    const d = std.fmt.parseInt(u32, s[8..10], 10) catch return error.InvalidDate;
    if (m < 1 or m > 12 or d < 1 or d > 31) return error.InvalidDate;
    return .{ .year = y, .month = m, .day = d };
}

fn ymdToEpochDay(year: i32, month: u32, day: u32) i64 {
    const y: i64 = if (month <= 2) @as(i64, year) - 1 else year;
    const era = @divFloor(y, 400);
    const yoe: u32 = @intCast(y - era * 400);
    const m_idx: u32 = if (month > 2) month - 3 else month + 9;
    const doy: u32 = (153 * m_idx + 2) / 5 + day - 1;
    const doe: u32 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + @as(i64, doe) - 719468;
}

fn epochDayToYmd(epoch_day: i64) DateParts {
    const z = epoch_day + 719468;
    const era = @divFloor(z, 146097);
    const doe: u32 = @intCast(z - era * 146097);
    const yoe: u32 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i64 = @as(i64, yoe) + era * 400;
    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u32 = (5 * doy + 2) / 153;
    const d: u32 = doy - (153 * mp + 2) / 5 + 1;
    const m: u32 = if (mp < 10) mp + 3 else mp - 9;
    const final_y: i32 = @intCast(if (m <= 2) y + 1 else y);
    return .{ .year = final_y, .month = m, .day = d };
}

/// ISO weekday: Monday=1 … Sunday=7. 1970-01-01 (epoch_day=0) was Thursday=4.
fn isoWeekday(epoch_day: i64) u32 {
    return @intCast(@mod(epoch_day + 3, 7) + 1);
}

fn formatYmd(alloc: std.mem.Allocator, parts: DateParts) ![]const u8 {
    // Cast to unsigned for formatting: Zig 0.15's `{d}` prepends '+' to
    // positive signed integers. Trading dates never go negative, so the
    // cast is safe in practice — `parseYmd` rejects malformed input and
    // year arithmetic stays positive across the realistic CSV range.
    const y_u: u32 = @intCast(parts.year);
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}", .{ y_u, parts.month, parts.day });
}

/// Parse arg[0] as a date string and return its epoch day. On parse failure
/// writes a descriptive diagnostic via `setDetail` and returns InvalidDate so
/// callers see a clickable error in bxp-fmt / GUI. Empty input must be
/// pre-handled by the caller (return "" silently) — see DATE_CONVERT's
/// rationale at builtinDateConvert.
fn parseDateArg(p: *Parser, s: []const u8) !i64 {
    const parts = parseYmd(s) catch {
        p.setDetail("invalid date '{s}': expected YYYY-MM-DD", .{s});
        return error.InvalidDate;
    };
    return ymdToEpochDay(parts.year, parts.month, parts.day);
}

// ── DATEADD ─────────────────────────────────────────────────────────────
const dateadd_doc: FnDoc = .{
    .name = "DATEADD",
    .signature = "DATEADD(d, n)",
    .description = "Add `n` calendar days to date `d` (YYYY-MM-DD). Negative `n` subtracts. Returns YYYY-MM-DD. For business-day arithmetic (skipping weekends) use WORKDAY().",
    .args = &.{
        .{ .name = "d", .kind = .string },
        .{ .name = "n", .kind = .number },
    },
    .min_args = 2,
    .max_args = 2,
};
fn builtinDateAdd(p: *Parser, args: []Value) !Value {
    const ds = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    if (ds.len == 0) return Value{ .string = "" };
    const n = toDayOffset(try args[1].toNumber()) orelse return Value{ .string = "" };
    const start = try parseDateArg(p, ds);
    const result = epochDayToYmd(start + n);
    return Value{ .string = try formatYmd(p.ctx.alloc, result) };
}
fn adaptDateAdd(p: *Parser, args: []Value) anyerror!Value {
    return builtinDateAdd(p, args);
}

// ── DATEDIFF ────────────────────────────────────────────────────────────
const datediff_doc: FnDoc = .{
    .name = "DATEDIFF",
    .signature = "DATEDIFF(d1, d2)",
    .description = "Calendar days from `d2` to `d1`: positive when `d1` is later. Both arguments are YYYY-MM-DD strings.",
    .args = &.{
        .{ .name = "d1", .kind = .string },
        .{ .name = "d2", .kind = .string },
    },
    .min_args = 2,
    .max_args = 2,
};
fn builtinDateDiff(p: *Parser, args: []Value) !Value {
    const s1 = switch (args[0]) { .string => |v| v, else => return error.StringExpected };
    const s2 = switch (args[1]) { .string => |v| v, else => return error.StringExpected };
    if (s1.len == 0 or s2.len == 0) return Value{ .string = "" };
    const d1 = try parseDateArg(p, s1);
    const d2 = try parseDateArg(p, s2);
    return Value{ .number = @floatFromInt(d1 - d2) };
}
fn adaptDateDiff(p: *Parser, args: []Value) anyerror!Value {
    return builtinDateDiff(p, args);
}

// ── WORKDAY ─────────────────────────────────────────────────────────────
const workday_doc: FnDoc = .{
    .name = "WORKDAY",
    .signature = "WORKDAY(d, n)",
    .description = "Add `n` business days to date `d` (YYYY-MM-DD), skipping Saturdays and Sundays. Negative `n` subtracts. Correct for T+2 settlement math; does NOT account for exchange holidays.",
    .args = &.{
        .{ .name = "d", .kind = .string },
        .{ .name = "n", .kind = .number },
    },
    .min_args = 2,
    .max_args = 2,
};
fn builtinWorkday(p: *Parser, args: []Value) !Value {
    const ds = switch (args[0]) { .string => |v| v, else => return error.StringExpected };
    if (ds.len == 0) return Value{ .string = "" };
    var n = toDayOffset(try args[1].toNumber()) orelse return Value{ .string = "" };
    var ep = try parseDateArg(p, ds);
    // Excel semantics: WORKDAY(d, 0) returns d unchanged (no snap to next workday).
    while (n > 0) {
        ep += 1;
        if (isoWeekday(ep) <= 5) n -= 1;
    }
    while (n < 0) {
        ep -= 1;
        if (isoWeekday(ep) <= 5) n += 1;
    }
    return Value{ .string = try formatYmd(p.ctx.alloc, epochDayToYmd(ep)) };
}
fn adaptWorkday(p: *Parser, args: []Value) anyerror!Value {
    return builtinWorkday(p, args);
}

// ── YEAR ────────────────────────────────────────────────────────────────
const year_doc: FnDoc = .{
    .name = "YEAR",
    .signature = "YEAR(d)",
    .description = "Year component of date `d` (YYYY-MM-DD) as a number.",
    .args = &.{.{ .name = "d", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinYear(p: *Parser, args: []Value) !Value {
    const s = switch (args[0]) { .string => |v| v, else => return error.StringExpected };
    if (s.len == 0) return Value{ .string = "" };
    const parts = parseYmd(s) catch {
        p.setDetail("invalid date '{s}': expected YYYY-MM-DD", .{s});
        return error.InvalidDate;
    };
    return Value{ .number = @floatFromInt(parts.year) };
}
fn adaptYear(p: *Parser, args: []Value) anyerror!Value {
    return builtinYear(p, args);
}

// ── MONTH ───────────────────────────────────────────────────────────────
const month_doc: FnDoc = .{
    .name = "MONTH",
    .signature = "MONTH(d)",
    .description = "Month component of date `d` (YYYY-MM-DD) as a number, 1-12.",
    .args = &.{.{ .name = "d", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinMonth(p: *Parser, args: []Value) !Value {
    const s = switch (args[0]) { .string => |v| v, else => return error.StringExpected };
    if (s.len == 0) return Value{ .string = "" };
    const parts = parseYmd(s) catch {
        p.setDetail("invalid date '{s}': expected YYYY-MM-DD", .{s});
        return error.InvalidDate;
    };
    return Value{ .number = @floatFromInt(parts.month) };
}
fn adaptMonth(p: *Parser, args: []Value) anyerror!Value {
    return builtinMonth(p, args);
}

// ── DAY ─────────────────────────────────────────────────────────────────
const day_doc: FnDoc = .{
    .name = "DAY",
    .signature = "DAY(d)",
    .description = "Day-of-month component of date `d` (YYYY-MM-DD) as a number, 1-31.",
    .args = &.{.{ .name = "d", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinDay(p: *Parser, args: []Value) !Value {
    const s = switch (args[0]) { .string => |v| v, else => return error.StringExpected };
    if (s.len == 0) return Value{ .string = "" };
    const parts = parseYmd(s) catch {
        p.setDetail("invalid date '{s}': expected YYYY-MM-DD", .{s});
        return error.InvalidDate;
    };
    return Value{ .number = @floatFromInt(parts.day) };
}
fn adaptDay(p: *Parser, args: []Value) anyerror!Value {
    return builtinDay(p, args);
}

// ── WEEKDAY ─────────────────────────────────────────────────────────────
const weekday_doc: FnDoc = .{
    .name = "WEEKDAY",
    .signature = "WEEKDAY(d)",
    .description = "ISO day-of-week for date `d` (YYYY-MM-DD): Monday=1 … Sunday=7. Useful for weekend-trade detection: `WEEKDAY([Date]) > 5`.",
    .args = &.{.{ .name = "d", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinWeekday(p: *Parser, args: []Value) !Value {
    const s = switch (args[0]) { .string => |v| v, else => return error.StringExpected };
    if (s.len == 0) return Value{ .string = "" };
    const ep = try parseDateArg(p, s);
    return Value{ .number = @floatFromInt(isoWeekday(ep)) };
}
fn adaptWeekday(p: *Parser, args: []Value) anyerror!Value {
    return builtinWeekday(p, args);
}

// ── EOMONTH ─────────────────────────────────────────────────────────────
const eomonth_doc: FnDoc = .{
    .name = "EOMONTH",
    .signature = "EOMONTH(d)",
    .description = "Last calendar day of the month containing date `d` (YYYY-MM-DD), as YYYY-MM-DD. Useful for snapping coupon/dividend dates and month-end reporting.",
    .args = &.{.{ .name = "d", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinEomonth(p: *Parser, args: []Value) !Value {
    const s = switch (args[0]) { .string => |v| v, else => return error.StringExpected };
    if (s.len == 0) return Value{ .string = "" };
    const parts = parseYmd(s) catch {
        p.setDetail("invalid date '{s}': expected YYYY-MM-DD", .{s});
        return error.InvalidDate;
    };
    var next_y = parts.year;
    var next_m = parts.month + 1;
    if (next_m > 12) {
        next_m = 1;
        next_y += 1;
    }
    const first_of_next = ymdToEpochDay(next_y, next_m, 1);
    const result = epochDayToYmd(first_of_next - 1);
    return Value{ .string = try formatYmd(p.ctx.alloc, result) };
}
fn adaptEomonth(p: *Parser, args: []Value) anyerror!Value {
    return builtinEomonth(p, args);
}

// ── LEN ─────────────────────────────────────────────────────────────────
const len_doc: FnDoc = .{
    .name = "LEN",
    .signature = "LEN(s)",
    .description = "Byte length of `s` (UTF-8 byte count, not codepoint or grapheme count). Empty string → 0.",
    .args = &.{.{ .name = "s", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinLen(args: []Value) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    return Value{ .number = @floatFromInt(s.len) };
}
fn adaptLen(_: *Parser, args: []Value) anyerror!Value {
    return builtinLen(args);
}

// ── GREATEST ────────────────────────────────────────────────────────────
const greatest_doc: FnDoc = .{
    .name = "GREATEST",
    .signature = "GREATEST(a, b, ...)",
    .description = "Largest numeric value among arguments. Per-row maximum (not aggregation across rows). Arguments are coerced to numbers; empty string coerces to 0, non-numeric strings raise an error.",
    // Variadic 1+ args. Like COALESCE, only the first arg is declared;
    // trailing args inherit `kind = .expr` semantically.
    .args = &.{.{ .name = "a", .kind = .number }},
    .min_args = 1,
    .max_args = 255,
};
fn builtinGreatest(args: []Value) !Value {
    var best: f80 = try args[0].toNumber();
    for (args[1..]) |v| {
        const n = try v.toNumber();
        if (n > best) best = n;
    }
    return Value{ .number = best };
}
fn adaptGreatest(p: *Parser, args: []Value) anyerror!Value {
    return builtinGreatest(args) catch |err| {
        for (args) |v| switch (v) {
            .string => |s| {
                _ = std.fmt.parseFloat(f80, s) catch {
                    p.setNotANumber(s);
                    return err;
                };
            },
            else => {},
        };
        return err;
    };
}

// ── LEAST ───────────────────────────────────────────────────────────────
const least_doc: FnDoc = .{
    .name = "LEAST",
    .signature = "LEAST(a, b, ...)",
    .description = "Smallest numeric value among arguments. Per-row minimum (not aggregation across rows). Arguments are coerced to numbers; empty string coerces to 0, non-numeric strings raise an error.",
    .args = &.{.{ .name = "a", .kind = .number }},
    .min_args = 1,
    .max_args = 255,
};
fn builtinLeast(args: []Value) !Value {
    var best: f80 = try args[0].toNumber();
    for (args[1..]) |v| {
        const n = try v.toNumber();
        if (n < best) best = n;
    }
    return Value{ .number = best };
}
fn adaptLeast(p: *Parser, args: []Value) anyerror!Value {
    return builtinLeast(args) catch |err| {
        for (args) |v| switch (v) {
            .string => |s| {
                _ = std.fmt.parseFloat(f80, s) catch {
                    p.setNotANumber(s);
                    return err;
                };
            },
            else => {},
        };
        return err;
    };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Evaluates src against ctx and returns a Value.
/// An empty src string evaluates to an empty string value.
/// String values may be slices into ctx.fields (no alloc) or alloc-owned.
pub fn eval(src: []const u8, ctx: *const Context) !Value {
    if (src.len == 0) return Value{ .string = "" };
    var p = Parser.init(src, ctx);
    return p.parseExpr() catch |err| {
        // If the tokenizer recorded the bad character, surface it as detail.
        // Only set detail when it hasn't already been written by a deeper setDetail call.
        if (p.tok.error_char != 0) {
            const d = ctx.error_detail orelse return err;
            if (d.len == 0) {
                p.setDetail("unexpected character '{c}' at pos {d}", .{ p.tok.error_char, p.tok.error_pos + 1 });
            }
        }
        return err;
    };
}

/// Evaluates src and returns the result as a string allocated with ctx.alloc.
/// Numeric strings are normalized: non-integers get up to 8 decimal places
/// with trailing zeros trimmed; integer-valued floats have no decimal point.
///
/// The re-parse + re-format step after toString() is what produces the
/// "99.00" → "99" normalisation documented in the project notes. It only
/// fires when the string looks like a valid float — non-numeric strings
/// (e.g. "BUY") pass through unchanged.
pub fn evalString(src: []const u8, ctx: *const Context) ![]const u8 {
    const v = try eval(src, ctx);
    const s = try v.toString(ctx.alloc);
    if (std.fmt.parseFloat(f80, s)) |n| {
        return (Value{ .number = n }).toString(ctx.alloc);
    } else |_| {}
    return s;
}

// ---------------------------------------------------------------------------
// Catalog — single source of truth for FnDoc / OperatorDoc / KeywordDoc /
// TokenDoc surfaced by `bxp-fmt --docs` and consumed by the GUI. Per-fn
// FnDoc declarations live RIGHT NEXT to each builtin impl + adapter above
// (search for "── <NAME> ──" headers); the `builtins` table at the very
// bottom of this file just collects refs to them so the dispatcher in
// evalCall can iterate. Keywords, operators and tokens have no impl in
// expr.zig so their full data lives here.
// ---------------------------------------------------------------------------

pub const keywords = [_]KeywordDoc{ and_kw_doc, or_kw_doc, not_kw_doc };

// Operator order chosen to match how the parser groups them visually — concat
// + comparisons + additive + multiplicative — so a reader scanning the GUI's
// docs panel sees roughly the same precedence flow as the parser code.
pub const operators = [_]OperatorDoc{
    concat_op_doc,
    eq_op_doc,
    neq_op_doc,
    lt_op_doc,
    gt_op_doc,
    lte_op_doc,
    gte_op_doc,
    add_op_doc,
    sub_op_doc,
    mul_op_doc,
    div_op_doc,
};

pub const tokens = [_]TokenDoc{
    column_token_doc,
    input_var_token_doc,
    string_token_doc,
    number_token_doc,
    function_token_doc,
    keyword_token_doc,
};

/// Master dispatch table — must be the LAST decl in the catalog because each
/// entry references a `<name>_doc` const + `adaptXxx` adapter that are
/// co-located with their `builtinXxx` impl above. Adding a builtin = add a
/// new "── NAME ──" block above + one line here. Order is the iteration
/// order in `evalCall` (case-insensitive lookup so order doesn't matter for
/// correctness).
pub const builtins = [_]FnEntry{
    .{ .name = "IF",             .lazy = true, .doc = if_doc },
    .{ .name = "ABS",            .doc = abs_doc,            .impl = adaptAbs },
    .{ .name = "NOW",            .doc = now_doc,            .impl = adaptNow },
    .{ .name = "TRIM",           .doc = trim_doc,           .impl = adaptTrim },
    .{ .name = "ROUND",          .doc = round_doc,          .impl = adaptRound },
    .{ .name = "FLOOR",          .doc = floor_doc,          .impl = adaptFloor },
    .{ .name = "CEILING",        .doc = ceiling_doc,        .impl = adaptCeiling },
    .{ .name = "RAND",           .doc = rand_doc,           .impl = adaptRand },
    .{ .name = "COALESCE",       .doc = coalesce_doc,       .impl = adaptCoalesce },
    .{ .name = "DATE_CONVERT",   .doc = date_convert_doc,   .impl = adaptDateConvert },
    .{ .name = "PRICE_VALUE",    .doc = price_value_doc,    .impl = adaptPriceValue },
    .{ .name = "PRICE_CURRENCY", .doc = price_currency_doc, .impl = adaptPriceCurrency },
    .{ .name = "TICKER",         .doc = ticker_doc,         .impl = adaptTicker },
    .{ .name = "LOOKUP",         .doc = lookup_doc,         .impl = adaptLookup },
    .{ .name = "SPLIT_PART",     .doc = split_part_doc,     .impl = adaptSplitPart },
    .{ .name = "CONTAINS",       .doc = contains_doc,       .impl = adaptContains },
    .{ .name = "REPLACE",        .doc = replace_doc,        .impl = adaptReplace },
    .{ .name = "FIELDS",         .doc = fields_doc,         .impl = adaptFields },
    .{ .name = "LEFT",           .doc = left_doc,           .impl = adaptLeft },
    .{ .name = "RIGHT",          .doc = right_doc,          .impl = adaptRight },
    .{ .name = "SUBSTR",         .doc = substr_doc,         .impl = adaptSubstr },
    .{ .name = "UPPER",          .doc = upper_doc,          .impl = adaptUpper },
    .{ .name = "LOWER",          .doc = lower_doc,          .impl = adaptLower },
    .{ .name = "STARTS_WITH",    .doc = starts_with_doc,    .impl = adaptStartsWith },
    .{ .name = "ENDS_WITH",      .doc = ends_with_doc,      .impl = adaptEndsWith },
    .{ .name = "NULLIF",         .doc = nullif_doc,         .impl = adaptNullif },
    .{ .name = "IN",             .doc = in_doc,             .impl = adaptIn },
    .{ .name = "LEN",            .doc = len_doc,            .impl = adaptLen },
    .{ .name = "GREATEST",       .doc = greatest_doc,       .impl = adaptGreatest },
    .{ .name = "LEAST",          .doc = least_doc,          .impl = adaptLeast },
    .{ .name = "DATEADD",        .doc = dateadd_doc,        .impl = adaptDateAdd },
    .{ .name = "DATEDIFF",       .doc = datediff_doc,       .impl = adaptDateDiff },
    .{ .name = "WORKDAY",        .doc = workday_doc,        .impl = adaptWorkday },
    .{ .name = "YEAR",           .doc = year_doc,           .impl = adaptYear },
    .{ .name = "MONTH",          .doc = month_doc,          .impl = adaptMonth },
    .{ .name = "DAY",            .doc = day_doc,            .impl = adaptDay },
    .{ .name = "WEEKDAY",        .doc = weekday_doc,        .impl = adaptWeekday },
    .{ .name = "EOMONTH",        .doc = eomonth_doc,        .impl = adaptEomonth },
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

/// Minimal test fixture: col_index + ticker_map kept alive for the test.
/// Use ctx() to build a Context pointing into this helper.
const TestHelper = struct {
    col_index: std.StringHashMap(usize),
    ticker_map: std.StringHashMap([]const u8),

    fn init(alloc: std.mem.Allocator) TestHelper {
        return .{
            .col_index = std.StringHashMap(usize).init(alloc),
            .ticker_map = std.StringHashMap([]const u8).init(alloc),
        };
    }

    fn ctx(self: *const TestHelper, fields: []const []const u8, alloc: std.mem.Allocator) Context {
        return .{
            .fields = fields,
            .col_index = &self.col_index,
            .ticker_map = &self.ticker_map,
            .lookup_table = null,
            .alloc = alloc,
        };
    }
};

// ------------------------------------------------------------
// Value methods
// ------------------------------------------------------------

test "Value.toString: integer-valued float has no decimal point" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("7", try (Value{ .number = 7.0 }).toString(arena.allocator()));
    try testing.expectEqualStrings("-3", try (Value{ .number = -3.0 }).toString(arena.allocator()));
    try testing.expectEqualStrings("0", try (Value{ .number = 0.0 }).toString(arena.allocator()));
}

test "Value.toString: float trims trailing zeros" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("1.5", try (Value{ .number = 1.5 }).toString(arena.allocator()));
    try testing.expectEqualStrings("1.25", try (Value{ .number = 1.25 }).toString(arena.allocator()));
}

test "Value.toString: bool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("true", try (Value{ .boolean = true }).toString(arena.allocator()));
    try testing.expectEqualStrings("false", try (Value{ .boolean = false }).toString(arena.allocator()));
}

test "Value.toNumber: empty string returns 0" {
    try testing.expectEqual(@as(f80, 0), try (Value{ .string = "" }).toNumber());
}

test "Value.toNumber: numeric string is parsed" {
    try testing.expectEqual(@as(f80, 42), try (Value{ .string = "42" }).toNumber());
    try testing.expectEqual(@as(f80, -1.5), try (Value{ .string = "-1.5" }).toNumber());
}

test "Value.toNumber: non-numeric string returns error" {
    try testing.expectError(error.NotANumber, (Value{ .string = "abc" }).toNumber());
}

test "Value.toNumber: American thousands-separated format" {
    try testing.expectEqual(@as(f80, 1234.56),   try (Value{ .string = "1,234.56"     }).toNumber());
    try testing.expectEqual(@as(f80, 1234567),   try (Value{ .string = "1,234,567"    }).toNumber());
    try testing.expectEqual(@as(f80, -1234.5),   try (Value{ .string = "-1,234.5"     }).toNumber());
    try testing.expectEqual(@as(f80, 1000),      try (Value{ .string = "1,000"        }).toNumber());
    // Must still be a string when not used in arithmetic
    try testing.expectEqualStrings("1,234.56", (Value{ .string = "1,234.56" }).toString(testing.allocator) catch unreachable);
    // Invalid patterns must stay NotANumber
    try testing.expectError(error.NotANumber, (Value{ .string = "1,23.45"   }).toNumber()); // group not 3 digits
    try testing.expectError(error.NotANumber, (Value{ .string = "1,2345"    }).toNumber()); // 4 digits in group
    try testing.expectError(error.NotANumber, (Value{ .string = "12345,678" }).toNumber()); // 5 leading digits
}

test "eval: American number arithmetic via field ref" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    try h.col_index.put("Amount", 0);
    const ctx = h.ctx(&.{"1,234.56"}, a);
    // Arithmetic triggers toNumber — should parse correctly
    try testing.expectEqualStrings("1234.56", try evalString("[Amount] * 1", &ctx));
    try testing.expectEqualStrings("2469.12", try evalString("[Amount] * 2", &ctx));
    // Plain passthrough — string preserved as-is
    try testing.expectEqualStrings("1,234.56", try evalString("[Amount]",     &ctx));
}

test "Value.toBool: empty string is false, non-empty is true (even '0')" {
    try testing.expect(!(Value{ .string = "" }).toBool());
    try testing.expect((Value{ .string = "0" }).toBool()); // non-empty string → true!
    try testing.expect((Value{ .string = "hello" }).toBool());
}

test "Value.toBool: numeric zero is false, non-zero is true" {
    try testing.expect(!(Value{ .number = 0 }).toBool());
    try testing.expect((Value{ .number = 1 }).toBool());
    try testing.expect((Value{ .number = -1 }).toBool());
}

// ------------------------------------------------------------
// Arithmetic and operators
// ------------------------------------------------------------

test "eval: addition and subtraction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("7", try evalString("3 + 4", &ctx));
    try testing.expectEqualStrings("1", try evalString("3 - 2", &ctx));
}

test "eval: multiplication has higher precedence than addition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("11", try evalString("3 + 4 * 2", &ctx));
}

test "eval: division" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("2", try evalString("10 / 5", &ctx));
    try testing.expectEqualStrings("2.5", try evalString("5 / 2", &ctx));
}

test "eval: unary minus" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("-5", try evalString("-5", &ctx));
    try testing.expectEqualStrings("3", try evalString("8 + -5", &ctx));
}

test "eval: string concatenation with &" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("ab", try evalString("'a' & 'b'", &ctx));
    // Numbers are converted to strings before concat, not added.
    try testing.expectEqualStrings("12", try evalString("1 & 2", &ctx));
}

test "eval: numeric comparison operators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("true",  try evalString("1 < 2",  &ctx));
    try testing.expectEqualStrings("false", try evalString("2 < 1",  &ctx));
    try testing.expectEqualStrings("true",  try evalString("2 <= 2", &ctx));
    try testing.expectEqualStrings("true",  try evalString("3 > 2",  &ctx));
    try testing.expectEqualStrings("true",  try evalString("3 >= 3", &ctx));
    try testing.expectEqualStrings("true",  try evalString("1 = 1",  &ctx));
    try testing.expectEqualStrings("true",  try evalString("1 != 2", &ctx));
}

test "eval: string equality and inequality" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("true",  try evalString("'abc' = 'abc'",  &ctx));
    try testing.expectEqualStrings("false", try evalString("'abc' = 'ABC'",  &ctx));
    try testing.expectEqualStrings("true",  try evalString("'abc' != 'xyz'", &ctx));
}

test "eval: string < > returns error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectError(error.StringComparisonUnsupported, eval("'a' < 'b'", &ctx));
}

test "eval: AND and OR" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("true",  try evalString("1 = 1 AND 2 = 2", &ctx));
    try testing.expectEqualStrings("false", try evalString("1 = 1 AND 1 = 2", &ctx));
    try testing.expectEqualStrings("true",  try evalString("1 = 2 OR  2 = 2", &ctx));
    try testing.expectEqualStrings("false", try evalString("1 = 2 OR  1 = 2", &ctx));
}

// ------------------------------------------------------------
// IF
// ------------------------------------------------------------

test "eval: IF selects true branch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("yes", try evalString("IF(1 = 1, 'yes', 'no')", &ctx));
}

test "eval: IF selects false branch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("no", try evalString("IF(1 = 2, 'yes', 'no')", &ctx));
}

test "eval: IF string '0' is truthy (non-empty string)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("yes", try evalString("IF('0', 'yes', 'no')", &ctx));
}

test "eval: IF numeric 0 is falsy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("no", try evalString("IF(0, 'yes', 'no')", &ctx));
}

// ------------------------------------------------------------
// ABS
// ------------------------------------------------------------

test "eval: ABS" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("5",   try evalString("ABS(-5)",  &ctx));
    try testing.expectEqualStrings("5",   try evalString("ABS(5)",   &ctx));
    try testing.expectEqualStrings("0",   try evalString("ABS(0)",   &ctx));
    try testing.expectEqualStrings("1.5", try evalString("ABS(-1.5)", &ctx));
}

// ------------------------------------------------------------
// PRICE_VALUE and PRICE_CURRENCY
// ------------------------------------------------------------

test "eval: PRICE_VALUE strips leading currency symbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("88.5",  try evalString("PRICE_VALUE('$88.5')",  &ctx));
    try testing.expectEqualStrings("24",    try evalString("PRICE_VALUE('\u{20ac}24.00')", &ctx)); // €
    try testing.expectEqualStrings("10",    try evalString("PRICE_VALUE('\u{00a3}10.00')", &ctx)); // £
}

test "eval: PRICE_VALUE strips trailing ISO currency code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("24",    try evalString("PRICE_VALUE('24.00 CZK')", &ctx));
    try testing.expectEqualStrings("99.99", try evalString("PRICE_VALUE('99.99 EUR')", &ctx));
}

test "eval: PRICE_VALUE trims surrounding spaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("99.5", try evalString("PRICE_VALUE('  $99.50  ')", &ctx));
}

test "eval: PRICE_CURRENCY from leading symbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("USD", try evalString("PRICE_CURRENCY('$88')",          &ctx));
    try testing.expectEqualStrings("EUR", try evalString("PRICE_CURRENCY('\u{20ac}99')",   &ctx));
    try testing.expectEqualStrings("GBP", try evalString("PRICE_CURRENCY('\u{00a3}10')",   &ctx));
    try testing.expectEqualStrings("JPY", try evalString("PRICE_CURRENCY('\u{00a5}500')",  &ctx));
    try testing.expectEqualStrings("RUB", try evalString("PRICE_CURRENCY('\u{20bd}100')",  &ctx));
}

test "eval: PRICE_CURRENCY from trailing ISO code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("CZK", try evalString("PRICE_CURRENCY('24.00 CZK')", &ctx));
    try testing.expectEqualStrings("USD", try evalString("PRICE_CURRENCY('99 USD')",    &ctx));
}

test "eval: PRICE_CURRENCY returns empty when no currency found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("", try evalString("PRICE_CURRENCY('99.99')", &ctx));
}

// ------------------------------------------------------------
// SPLIT_PART
// ------------------------------------------------------------

test "eval: SPLIT_PART returns nth part (1-based)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("a", try evalString("SPLIT_PART('a:b:c', ':', 1)", &ctx));
    try testing.expectEqualStrings("b", try evalString("SPLIT_PART('a:b:c', ':', 2)", &ctx));
    try testing.expectEqualStrings("c", try evalString("SPLIT_PART('a:b:c', ':', 3)", &ctx));
}

test "eval: SPLIT_PART last part with no trailing delimiter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("c", try evalString("SPLIT_PART('a:b:c', ':', 3)", &ctx));
}

test "eval: SPLIT_PART returns empty when n exceeds part count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("", try evalString("SPLIT_PART('a:b', ':', 5)", &ctx));
}

test "eval: SPLIT_PART returns empty when n is 0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("", try evalString("SPLIT_PART('a:b', ':', 0)", &ctx));
}

test "eval: SPLIT_PART returns empty when delimiter is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("", try evalString("SPLIT_PART('abc', '', 1)", &ctx));
}

test "eval: SPLIT_PART multi-char delimiter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("b", try evalString("SPLIT_PART('a::b::c', '::', 2)", &ctx));
}

// ------------------------------------------------------------
// CONTAINS
// ------------------------------------------------------------

test "eval: CONTAINS" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("true",  try evalString("CONTAINS('hello world', 'world')", &ctx));
    try testing.expectEqualStrings("false", try evalString("CONTAINS('hello world', 'xyz')",   &ctx));
    try testing.expectEqualStrings("true",  try evalString("CONTAINS('abc', '')",               &ctx));
}

// ------------------------------------------------------------
// REPLACE
// ------------------------------------------------------------

test "eval: REPLACE replaces all occurrences" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("a-b-c", try evalString("REPLACE('aXbXc', 'X', '-')", &ctx));
}

test "eval: REPLACE returns unchanged when old not found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("abc", try evalString("REPLACE('abc', 'X', '-')", &ctx));
}

test "eval: REPLACE returns unchanged when old is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("abc", try evalString("REPLACE('abc', '', 'x')", &ctx));
}

// ------------------------------------------------------------
// DATE_CONVERT
// ------------------------------------------------------------

test "eval: DATE_CONVERT basic reformat" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings(
        "2022-06-26",
        try evalString("DATE_CONVERT('26/06/2022', 'DD/MM/YYYY', 'YYYY-MM-DD')", &ctx),
    );
}

test "eval: DATE_CONVERT normalises Sept to Sep via normalizeMonthAbbrev" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings(
        "2022-09-26",
        try evalString("DATE_CONVERT('26 Sept 2022', 'DD MMM YYYY', 'YYYY-MM-DD')", &ctx),
    );
}

// ------------------------------------------------------------
// normalizeMonthAbbrev (private)
// ------------------------------------------------------------

test "normalizeMonthAbbrev: 4-char abbrev trimmed to 3" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("26 Sep 2022", try normalizeMonthAbbrev("26 Sept 2022", a));
    try testing.expectEqualStrings("26 Jun 2024", try normalizeMonthAbbrev("26 June 2024", a));
    try testing.expectEqualStrings("01 Mar 2020", try normalizeMonthAbbrev("01 Marc 2020", a));
}

test "normalizeMonthAbbrev: no change when not needed returns original slice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = "26 Jun 2022";
    const result = try normalizeMonthAbbrev(input, a);
    // Same pointer means no allocation was done.
    try testing.expectEqual(input.ptr, result.ptr);
}

// ------------------------------------------------------------
// containsMMM (private)
// ------------------------------------------------------------

test "containsMMM" {
    try testing.expect(containsMMM("DD MMM YYYY"));
    try testing.expect(containsMMM("MMM"));
    try testing.expect(!containsMMM("DD MMMM YYYY")); // 4 M's → full month name, not abbrev
    try testing.expect(!containsMMM("YYYY-MM-DD"));   // only 2 M's
    try testing.expect(!containsMMM(""));
}

// ------------------------------------------------------------
// isNumericWithSep (private, inside Parser namespace)
// ------------------------------------------------------------

test "isNumericWithSep" {
    try testing.expect(Parser.isNumericWithSep("1,5",  ','));  // decimal with comma sep
    try testing.expect(Parser.isNumericWithSep("-1,5", ','));  // negative
    try testing.expect(Parser.isNumericWithSep("100",  ','));  // integer, no sep needed
    try testing.expect(!Parser.isNumericWithSep("1,2,3", ',')); // two separators → false
    try testing.expect(!Parser.isNumericWithSep("",    ','));  // empty
    try testing.expect(!Parser.isNumericWithSep("abc", ','));  // letters
    try testing.expect(!Parser.isNumericWithSep(",5",  ','));  // leading sep without digit
}

// ------------------------------------------------------------
// Field access and decimal_sep_in normalization
// ------------------------------------------------------------

test "eval: [ColumnName] field lookup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    try h.col_index.put("Price", 0);
    try h.col_index.put("Name",  1);
    const ctx = h.ctx(&.{ "42.5", "Apple" }, a);
    try testing.expectEqualStrings("42.5",  try evalString("[Price]", &ctx));
    try testing.expectEqualStrings("Apple", try evalString("[Name]",  &ctx));
}

test "eval: [n] 1-based numeric index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{ "first", "second", "third" }, a);
    try testing.expectEqualStrings("first",  try evalString("[1]", &ctx));
    try testing.expectEqualStrings("second", try evalString("[2]", &ctx));
    try testing.expectEqualStrings("third",  try evalString("[3]", &ctx));
}

test "eval: out-of-bounds field returns empty string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{ "only" }, a);
    try testing.expectEqualStrings("", try evalString("[5]", &ctx));
}

test "eval: decimal_sep_in=',' normalises numeric field value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    var ctx = h.ctx(&.{ "1,5" }, a);
    ctx.decimal_sep_in = ',';
    // The field "1,5" is recognised as numeric → comma replaced by dot → "1.5"
    try testing.expectEqualStrings("1.5", try evalString("[1]", &ctx));
}

test "eval: decimal_sep_in=',' leaves non-numeric fields unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    var ctx = h.ctx(&.{ "hello,world" }, a);
    ctx.decimal_sep_in = ',';
    try testing.expectEqualStrings("hello,world", try evalString("[1]", &ctx));
}

test "eval: decimal_sep_in=',' parses EU thousands group (1.234,56)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    var ctx = h.ctx(&.{ "1.234,56" }, a);
    ctx.decimal_sep_in = ',';
    try testing.expectEqualStrings("1234.56", try evalString("[1]", &ctx));
}

test "eval: decimal_sep_in=',' parses multi-group EU thousands (-1.234.567,89)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    var ctx = h.ctx(&.{ "-1.234.567,89" }, a);
    ctx.decimal_sep_in = ',';
    try testing.expectEqualStrings("-1234567.89", try evalString("[1]", &ctx));
}

test "eval: decimal_sep_in=',' parses integer-only EU thousands (1.234)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    var ctx = h.ctx(&.{ "1.234" }, a);
    ctx.decimal_sep_in = ',';
    try testing.expectEqualStrings("1234", try evalString("[1]", &ctx));
}

test "eval: decimal_sep_in=',' rejects invalid grouping (1.5)" {
    // '.' followed by fewer than 3 digits is not a valid thousands group
    // in EU notation → field is left raw, not converted to "15".
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    var ctx = h.ctx(&.{ "1.5" }, a);
    ctx.decimal_sep_in = ',';
    try testing.expectEqualStrings("1.5", try evalString("[1]", &ctx));
}

test "eval: decimal_sep_in=',' arithmetic on EU thousands group" {
    // End-to-end: EU thousands value flows through field access into
    // arithmetic and produces the expected numeric result.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    var ctx = h.ctx(&.{ "1.234,50" }, a);
    ctx.decimal_sep_in = ',';
    try testing.expectEqualStrings("2469", try evalString("[1] * 2", &ctx));
}

test "parseGroupedNumber: American format" {
    try testing.expectEqual(@as(f80, 1234.56), try parseGroupedNumber("1,234.56", ',', '.'));
    try testing.expectEqual(@as(f80, -1234567), try parseGroupedNumber("-1,234,567", ',', '.'));
    try testing.expectEqual(@as(f80, 1000), try parseGroupedNumber("1,000", ',', '.'));
    try testing.expectError(error.NotANumber, parseGroupedNumber("123", ',', '.'));
    try testing.expectError(error.NotANumber, parseGroupedNumber("1,5", ',', '.'));
    try testing.expectError(error.NotANumber, parseGroupedNumber("1,2345", ',', '.'));
}

test "parseGroupedNumber: European format" {
    try testing.expectEqual(@as(f80, 1234.56), try parseGroupedNumber("1.234,56", '.', ','));
    try testing.expectEqual(@as(f80, -1234567.89), try parseGroupedNumber("-1.234.567,89", '.', ','));
    try testing.expectEqual(@as(f80, 1234), try parseGroupedNumber("1.234", '.', ','));
    try testing.expectError(error.NotANumber, parseGroupedNumber("1.5", '.', ','));
    try testing.expectError(error.NotANumber, parseGroupedNumber("1.234.5", '.', ','));
    try testing.expectError(error.NotANumber, parseGroupedNumber("1,234.56", '.', ','));
}

// ------------------------------------------------------------
// evalString normalization
// ------------------------------------------------------------

test "evalString: normalises numeric string result (99.00 → 99)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    // Field contains "99.00"; evalString re-parses as float → strips trailing zeros.
    const ctx = h.ctx(&.{ "99.00" }, a);
    try testing.expectEqualStrings("99", try evalString("[1]", &ctx));
}

// ------------------------------------------------------------
// NOW
// ------------------------------------------------------------

test "eval: NOW returns ISO 8601 UTC string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    const result = try evalString("NOW()", &ctx);
    // YYYY-MM-DDTHH:MM:SSZ = 20 characters
    try testing.expectEqual(@as(usize, 20), result.len);
    try testing.expectEqual(@as(u8, 'T'), result[10]);
    try testing.expectEqual(@as(u8, 'Z'), result[19]);
    try testing.expectEqual(@as(u8, '-'), result[4]);
    try testing.expectEqual(@as(u8, '-'), result[7]);
    try testing.expectEqual(@as(u8, ':'), result[13]);
    try testing.expectEqual(@as(u8, ':'), result[16]);
}

test "eval: NOW rejects wrong arg count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectError(error.WrongArgCount, eval("NOW('x')", &ctx));
}

// ------------------------------------------------------------
// TRIM
// ------------------------------------------------------------

test "eval: TRIM strips spaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("hello", try evalString("TRIM('  hello  ')", &ctx));
    try testing.expectEqualStrings("hello", try evalString("TRIM('hello')", &ctx));
    try testing.expectEqualStrings("", try evalString("TRIM('   ')", &ctx));
}

test "eval: TRIM strips tabs and newlines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("hi", try evalString("TRIM('\thi\n')", &ctx));
}

// ------------------------------------------------------------
// ROUND
// ------------------------------------------------------------

test "eval: ROUND to decimal places" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("3.14",  try evalString("ROUND(3.14159, 2)", &ctx));
    try testing.expectEqualStrings("3.142", try evalString("ROUND(3.14159, 3)", &ctx));
    try testing.expectEqualStrings("4",     try evalString("ROUND(3.5, 0)",     &ctx));
    try testing.expectEqualStrings("3",     try evalString("ROUND(3.4, 0)",     &ctx));
    try testing.expectEqualStrings("-4",    try evalString("ROUND(-3.5, 0)",    &ctx));
}

// ------------------------------------------------------------
// FLOOR
// ------------------------------------------------------------

test "eval: FLOOR rounds down" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("3",  try evalString("FLOOR(3.9)",  &ctx));
    try testing.expectEqualStrings("3",  try evalString("FLOOR(3.0)",  &ctx));
    try testing.expectEqualStrings("-4", try evalString("FLOOR(-3.2)", &ctx));
}

// ------------------------------------------------------------
// CEILING
// ------------------------------------------------------------

test "eval: CEILING rounds up" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("4",  try evalString("CEILING(3.2)",  &ctx));
    try testing.expectEqualStrings("3",  try evalString("CEILING(3.0)",  &ctx));
    try testing.expectEqualStrings("-3", try evalString("CEILING(-3.7)", &ctx));
}

// ------------------------------------------------------------
// RAND
// ------------------------------------------------------------

test "eval: RAND returns float in [0, 1)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    for (0..20) |_| {
        const v = try eval("RAND()", &ctx);
        const n = try v.toNumber();
        try testing.expect(n >= 0 and n < 1);
    }
}

test "eval: RAND rejects wrong arg count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectError(error.WrongArgCount, eval("RAND(5)", &ctx));
}

// ------------------------------------------------------------
// COALESCE
// ------------------------------------------------------------

test "eval: COALESCE returns first non-empty string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("first",    try evalString("COALESCE('first', 'second')", &ctx));
    try testing.expectEqualStrings("fallback", try evalString("COALESCE('', 'fallback')", &ctx));
    try testing.expectEqualStrings("x",        try evalString("COALESCE('', '   ', 'x', 'y')", &ctx));
}

test "eval: COALESCE returns last arg verbatim when all empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("",  try evalString("COALESCE('', '', '')", &ctx));
    try testing.expectEqualStrings("0", try evalString("COALESCE('', '', '0')", &ctx));
}

test "eval: COALESCE treats numbers and booleans as non-empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("0", try evalString("COALESCE('', 0, 'x')", &ctx));
    try testing.expectEqualStrings("7", try evalString("COALESCE('', 7)", &ctx));
}

test "eval: COALESCE rejects zero args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectError(error.WrongArgCount, eval("COALESCE()", &ctx));
}

// ------------------------------------------------------------
// FIELDS — 1-based column index by literal int
// ------------------------------------------------------------

test "eval: FIELDS returns field at 1-based index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{ "first", "second", "third" }, a);
    try testing.expectEqualStrings("first",  try evalString("FIELDS(1)", &ctx));
    try testing.expectEqualStrings("second", try evalString("FIELDS(2)", &ctx));
    try testing.expectEqualStrings("third",  try evalString("FIELDS(3)", &ctx));
}

test "eval: FIELDS truncates fractional index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{ "first", "second" }, a);
    try testing.expectEqualStrings("first", try evalString("FIELDS(1.9)", &ctx));
}

test "eval: FIELDS out-of-bounds index returns empty string (silent skip)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{ "only" }, a);
    try testing.expectEqualStrings("", try evalString("FIELDS(99)", &ctx));
}

// Regression guard: previously panicked with integer overflow on `idx - 1`.
test "eval: FIELDS zero or negative index returns empty string (no panic)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{ "only" }, a);
    try testing.expectEqualStrings("", try evalString("FIELDS(0)", &ctx));
    try testing.expectEqualStrings("", try evalString("FIELDS(-1)", &ctx));
}

// Regression guard: empty-string arg via field-ref previously panicked
// because toNumber("") = 0 then `idx - 1` underflowed.
test "eval: FIELDS empty-string arg returns empty string (no panic)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{ "only" }, a);
    try testing.expectEqualStrings("", try evalString("FIELDS('')", &ctx));
}

test "eval: FIELDS rejects wrong arg count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectError(error.WrongArgCount, eval("FIELDS()", &ctx));
    try testing.expectError(error.WrongArgCount, eval("FIELDS(1, 2)", &ctx));
}

test "eval: FIELDS non-numeric string arg returns NotANumber" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectError(error.NotANumber, eval("FIELDS('abc')", &ctx));
}

// Regression guards for toPositiveIndex helper — discovered 2026-05-14:
// IEEE 754 comparisons return false for NaN, so the prior `f < 1.0` gate
// did NOT filter Inf/NaN, and `@intFromFloat(Inf or NaN)` panicked.
test "eval: FIELDS Inf/NaN index returns empty string (no panic)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{"only"}, a);
    try testing.expectEqualStrings("", try evalString("FIELDS('inf')", &ctx));
    try testing.expectEqualStrings("", try evalString("FIELDS('-inf')", &ctx));
    try testing.expectEqualStrings("", try evalString("FIELDS('nan')", &ctx));
}

test "eval: SPLIT_PART Inf/NaN index returns empty string (no panic)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("", try evalString("SPLIT_PART('a,b', ',', 'inf')", &ctx));
    try testing.expectEqualStrings("", try evalString("SPLIT_PART('a,b', ',', 'nan')", &ctx));
}

// staticCheckCalls panic regression — the literal-int-positive arg
// scanner cast `parseFloat(f80) -> i64` without bounds-checking, so a
// finite-but-huge literal (e.g. `1e30`) or a parse-as-Inf literal
// triggered `@intFromFloat` UB. Reachable from user input in three
// places: bxp-fmt --expr / --config, bxp-gui-bridge bridge_eval_expr,
// BrokerConfig.validate at startup. Guard now flags such literals as
// "violation with bad_idx=0" and returns without invoking @intFromFloat.
test "staticCheckCalls: SPLIT_PART literal index out-of-i64 range does not panic" {
    // 24-digit positive literal parses as f80 ≈ 1e24, well past i64 max
    // (~9.22e18); pre-guard `@intFromFloat(f80 → i64)` was undefined
    // behaviour and panicked in Debug/ReleaseSafe.
    const r_pos = staticCheckCalls("SPLIT_PART([Field], '/', 999999999999999999999999)");
    try testing.expect(r_pos.split_part != null);
    try testing.expectEqual(@as(i64, 0), r_pos.split_part.?.bad_idx);

    // Negative beyond minInt(i64) (~-9.22e18) — same UB on the
    // negative branch.
    const r_neg = staticCheckCalls("SPLIT_PART([Field], '/', -99999999999999999999)");
    try testing.expect(r_neg.split_part != null);
    try testing.expectEqual(@as(i64, 0), r_neg.split_part.?.bad_idx);
}

test "staticCheckCalls: SPLIT_PART literal index in i64 range still detects ≤ 0" {
    const r_zero = staticCheckCalls("SPLIT_PART([Field], '/', 0)");
    try testing.expect(r_zero.split_part != null);
    try testing.expectEqual(@as(i64, 0), r_zero.split_part.?.bad_idx);

    const r_pos = staticCheckCalls("SPLIT_PART([Field], '/', 3)");
    try testing.expect(r_pos.split_part == null);
}

test "eval: ROUND non-finite precision returns x unchanged (no panic)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("3.14", try evalString("ROUND(3.14, 'inf')", &ctx));
    try testing.expectEqualStrings("3.14", try evalString("ROUND(3.14, '-inf')", &ctx));
    try testing.expectEqualStrings("3.14", try evalString("ROUND(3.14, 'nan')", &ctx));
}

// DoS guard — prior code looped `factor *= 10.0` n times, so n=1e9 hung
// for tens of seconds. The clamp to ROUND_MAX_PRECISION caps it at ~30.
test "eval: ROUND huge precision is fast" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    const t0 = std.time.milliTimestamp();
    _ = try eval("ROUND(1.0, 1000000000)", &ctx);
    _ = try eval("ROUND(1.0, -1000000000)", &ctx);
    const elapsed_ms = std.time.milliTimestamp() - t0;
    // Two clamped calls together must finish well under any sane budget.
    try testing.expect(elapsed_ms < 100);
}

// ------------------------------------------------------------
// Catalog consistency — guards single-source-of-truth invariants
// ------------------------------------------------------------

test "catalog: every builtin has a non-empty FnDoc" {
    for (builtins) |b| {
        try testing.expectEqualStrings(b.name, b.doc.name);
        try testing.expect(b.doc.signature.len > 0);
        try testing.expect(b.doc.description.len > 0);
        // Eager builtins must have an impl; lazy ones must not.
        if (b.lazy) {
            try testing.expect(b.impl == null);
        } else {
            try testing.expect(b.impl != null);
        }
    }
}

test "catalog: builtin names are unique (case-insensitive)" {
    for (builtins, 0..) |a, i| {
        for (builtins[i + 1 ..]) |b| {
            try testing.expect(!std.ascii.eqlIgnoreCase(a.name, b.name));
        }
    }
}

test "catalog: keywords are non-empty and unique" {
    for (keywords, 0..) |a, i| {
        try testing.expect(a.name.len > 0);
        try testing.expect(a.description.len > 0);
        for (keywords[i + 1 ..]) |b| {
            try testing.expect(!std.ascii.eqlIgnoreCase(a.name, b.name));
        }
    }
}

test "catalog: operators are non-empty and unique" {
    for (operators, 0..) |a, i| {
        try testing.expect(a.token.len > 0);
        try testing.expect(a.description.len > 0);
        for (operators[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.token, b.token));
        }
    }
}

test "catalog: tokens are non-empty and unique by kind" {
    for (tokens, 0..) |a, i| {
        try testing.expect(a.kind.len > 0);
        try testing.expect(a.syntax.len > 0);
        try testing.expect(a.description.len > 0);
        for (tokens[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.kind, b.kind));
        }
    }
}

// ------------------------------------------------------------
// v0.2.4 string utilities: LEFT, RIGHT, SUBSTR, UPPER, LOWER,
// STARTS_WITH, ENDS_WITH
// ------------------------------------------------------------

test "eval: LEFT basic and edge cases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("hel",   try evalString("LEFT('hello', 3)", &ctx));
    try testing.expectEqualStrings("hello", try evalString("LEFT('hello', 10)", &ctx));
    try testing.expectEqualStrings("",      try evalString("LEFT('hello', 0)", &ctx));
    try testing.expectEqualStrings("",      try evalString("LEFT('hello', -1)", &ctx));
    try testing.expectEqualStrings("",      try evalString("LEFT('', 5)", &ctx));
}

test "eval: LEFT ISIN country prefix (real-world use case)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("US", try evalString("LEFT('US0378331005', 2)", &ctx));
    try testing.expectEqualStrings("DE", try evalString("LEFT('DE0007236101', 2)", &ctx));
}

test "eval: RIGHT basic and edge cases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("llo",   try evalString("RIGHT('hello', 3)", &ctx));
    try testing.expectEqualStrings("hello", try evalString("RIGHT('hello', 10)", &ctx));
    try testing.expectEqualStrings("",      try evalString("RIGHT('hello', 0)", &ctx));
    try testing.expectEqualStrings("",      try evalString("RIGHT('hello', -1)", &ctx));
    try testing.expectEqualStrings("",      try evalString("RIGHT('', 5)", &ctx));
}

test "eval: SUBSTR basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("ell",   try evalString("SUBSTR('hello', 2, 3)", &ctx));
    try testing.expectEqualStrings("hello", try evalString("SUBSTR('hello', 1, 100)", &ctx));
    try testing.expectEqualStrings("",      try evalString("SUBSTR('hello', 6, 3)", &ctx));
    try testing.expectEqualStrings("",      try evalString("SUBSTR('hello', 2, 0)", &ctx));
}

test "eval: SUBSTR start non-positive returns empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("", try evalString("SUBSTR('hello', 0, 3)", &ctx));
    try testing.expectEqualStrings("", try evalString("SUBSTR('hello', -1, 3)", &ctx));
    try testing.expectEqualStrings("", try evalString("SUBSTR('hello', 1, -1)", &ctx));
}

// Regression guard: parallels [[feedback_expr_intfromfloat_pattern]] —
// SUBSTR/LEFT/RIGHT must not panic on huge floats, Inf, or NaN. The
// tokenizer rejects `1e30` / `Inf` literals, so we drive these through
// field-string parseFloat which DOES accept them.
test "eval: LEFT/RIGHT/SUBSTR Inf/NaN/huge floats via field are safe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    try h.col_index.put("Big", 0);
    try h.col_index.put("Inf", 1);
    try h.col_index.put("Nan", 2);
    const ctx = h.ctx(&.{ "1e30", "Inf", "NaN" }, a);
    try testing.expectEqualStrings("hello", try evalString("LEFT('hello', [Big])", &ctx));
    try testing.expectEqualStrings("",      try evalString("LEFT('hello', [Inf])", &ctx));
    try testing.expectEqualStrings("",      try evalString("LEFT('hello', [Nan])", &ctx));
    try testing.expectEqualStrings("hello", try evalString("RIGHT('hello', [Big])", &ctx));
    try testing.expectEqualStrings("",      try evalString("RIGHT('hello', [Inf])", &ctx));
    try testing.expectEqualStrings("ello",  try evalString("SUBSTR('hello', 2, [Big])", &ctx));
    try testing.expectEqualStrings("",      try evalString("SUBSTR('hello', 2, [Inf])", &ctx));
    try testing.expectEqualStrings("",      try evalString("SUBSTR('hello', 2, [Nan])", &ctx));
}

test "eval: UPPER and LOWER ASCII" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("HELLO", try evalString("UPPER('hello')", &ctx));
    try testing.expectEqualStrings("HELLO", try evalString("UPPER('HeLLo')", &ctx));
    try testing.expectEqualStrings("hello", try evalString("LOWER('HELLO')", &ctx));
    try testing.expectEqualStrings("",      try evalString("UPPER('')", &ctx));
    try testing.expectEqualStrings("123abc", try evalString("LOWER('123ABC')", &ctx));
}

// Non-ASCII bytes (e.g. UTF-8 multi-byte sequences) are left alone so
// UPPER doesn't corrupt broker exports with accented chars.
test "eval: UPPER/LOWER leave non-ASCII bytes unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    // "Č" = 0xC4 0x8C; bytes pass through, ASCII letters get case-folded.
    try testing.expectEqualStrings("ČAU",  try evalString("UPPER('Čau')",  &ctx));
    try testing.expectEqualStrings("Čau",  try evalString("LOWER('ČaU')",  &ctx));
}

test "eval: STARTS_WITH and ENDS_WITH" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("true",  try evalString("STARTS_WITH('hello world', 'hello')", &ctx));
    try testing.expectEqualStrings("false", try evalString("STARTS_WITH('hello world', 'world')", &ctx));
    try testing.expectEqualStrings("true",  try evalString("ENDS_WITH('hello world', 'world')", &ctx));
    try testing.expectEqualStrings("false", try evalString("ENDS_WITH('hello world', 'hello')", &ctx));
    // Empty needle always matches; matches std.mem.startsWith / endsWith.
    try testing.expectEqualStrings("true",  try evalString("STARTS_WITH('hello', '')", &ctx));
    try testing.expectEqualStrings("true",  try evalString("ENDS_WITH('hello', '')", &ctx));
}

test "eval: STARTS_WITH/ENDS_WITH wrong arg count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectError(error.WrongArgCount, eval("STARTS_WITH('a')", &ctx));
    try testing.expectError(error.WrongArgCount, eval("ENDS_WITH('a', 'b', 'c')", &ctx));
}

// ------------------------------------------------------------
// v0.2.4 SQL semantics: NOT keyword, NULLIF, IN
// ------------------------------------------------------------

test "eval: NOT negates boolean expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("false", try evalString("NOT 1 = 1", &ctx));
    try testing.expectEqualStrings("true",  try evalString("NOT 1 = 2", &ctx));
    try testing.expectEqualStrings("true",  try evalString("NOT CONTAINS('hello', 'xyz')", &ctx));
    try testing.expectEqualStrings("false", try evalString("NOT CONTAINS('hello', 'ell')", &ctx));
}

test "eval: NOT stacks (double-NOT cancels)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("true",  try evalString("NOT NOT 1 = 1", &ctx));
    try testing.expectEqualStrings("false", try evalString("NOT NOT NOT 1 = 1", &ctx));
}

// Precedence sanity: NOT binds tighter than AND/OR. `[A] AND NOT [B]`
// must group as `[A] AND (NOT [B])`, not `NOT ([A] AND [B])`.
test "eval: NOT precedence between AND and =" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    // truthy AND NOT(falsy) → true AND true → true
    try testing.expectEqualStrings("true",  try evalString("'x' AND NOT 1 = 2", &ctx));
    // truthy AND NOT(truthy) → true AND false → false
    try testing.expectEqualStrings("false", try evalString("'x' AND NOT 1 = 1", &ctx));
}

// "NOT" as a substring of a longer identifier must NOT be consumed as
// the keyword. The tokenizer + keyword check use exact-length compare.
test "eval: NOT keyword does not steal longer identifiers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    try h.col_index.put("NOTE", 0);
    const ctx = h.ctx(&.{ "hi" }, a);
    try testing.expectEqualStrings("hi", try evalString("[NOTE]", &ctx));
}

test "eval: NULLIF basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    // Equal string → ""
    try testing.expectEqualStrings("",       try evalString("NULLIF('foo', 'foo')", &ctx));
    // Different string → first arg
    try testing.expectEqualStrings("foo",    try evalString("NULLIF('foo', 'bar')", &ctx));
    // Real-world sentinels.
    try testing.expectEqualStrings("",       try evalString("NULLIF('-9999', '-9999')", &ctx));
    try testing.expectEqualStrings("",       try evalString("NULLIF('N/A', 'N/A')", &ctx));
    try testing.expectEqualStrings("42",     try evalString("NULLIF('42', '-9999')", &ctx));
}

// Numeric equality: '100' and '100.0' should match (same as `=` operator).
test "eval: NULLIF numeric coercion matches '=' semantics" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("", try evalString("NULLIF('100', '100.0')", &ctx));
    try testing.expectEqualStrings("", try evalString("NULLIF(0, 0)", &ctx));
}

test "eval: NULLIF wrong arg count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectError(error.WrongArgCount, eval("NULLIF('a')", &ctx));
    try testing.expectError(error.WrongArgCount, eval("NULLIF('a', 'b', 'c')", &ctx));
}

test "eval: IN matches any option" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("true",  try evalString("IN('B', 'A', 'B', 'C')", &ctx));
    try testing.expectEqualStrings("false", try evalString("IN('Z', 'A', 'B', 'C')", &ctx));
    // Single-option IN behaves like equality.
    try testing.expectEqualStrings("true",  try evalString("IN('A', 'A')", &ctx));
    try testing.expectEqualStrings("false", try evalString("IN('A', 'B')", &ctx));
}

test "eval: IN numeric coercion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("true",  try evalString("IN('100', '50', '100.0', '200')", &ctx));
    try testing.expectEqualStrings("false", try evalString("IN(100, 200, 300)", &ctx));
}

test "eval: IN wrong arg count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectError(error.WrongArgCount, eval("IN('a')", &ctx));
    try testing.expectError(error.WrongArgCount, eval("IN()", &ctx));
}

test "eval: LEN byte count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("0", try evalString("LEN('')", &ctx));
    try testing.expectEqualStrings("5", try evalString("LEN('hello')", &ctx));
    // UTF-8 byte count, not codepoint count — "café" is 5 bytes (é = 0xC3 0xA9).
    try testing.expectEqualStrings("5", try evalString("LEN('café')", &ctx));
}

test "eval: LEN wrong arg count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectError(error.WrongArgCount, eval("LEN()", &ctx));
    try testing.expectError(error.WrongArgCount, eval("LEN('a', 'b')", &ctx));
}

test "eval: GREATEST returns numeric maximum" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("5", try evalString("GREATEST(5)", &ctx));
    try testing.expectEqualStrings("7", try evalString("GREATEST(3, 7, 2)", &ctx));
    try testing.expectEqualStrings("-1", try evalString("GREATEST(-5, -1, -3)", &ctx));
    // Fee-clamping idiom: GREATEST(value, 0) replaces IF(value < 0, 0, value).
    try testing.expectEqualStrings("0",   try evalString("GREATEST(-2.5, 0)", &ctx));
    try testing.expectEqualStrings("3.5", try evalString("GREATEST(3.5, 0)", &ctx));
}

test "eval: LEAST returns numeric minimum" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("2", try evalString("LEAST(3, 7, 2)", &ctx));
    try testing.expectEqualStrings("-5", try evalString("LEAST(-5, -1, -3)", &ctx));
    // Ceiling idiom: LEAST(value, cap) clamps from above.
    try testing.expectEqualStrings("100", try evalString("LEAST(150, 100)", &ctx));
}

test "eval: GREATEST/LEAST empty string coerces to zero" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    try h.col_index.put("Fee", 0);
    // Empty field coerces to 0 via toNumber() — matches BXP's "no NULL, empty=0" convention.
    const ctx = h.ctx(&.{""}, a);
    try testing.expectEqualStrings("5", try evalString("GREATEST([Fee], 5)", &ctx));
    try testing.expectEqualStrings("0", try evalString("LEAST([Fee], 5)", &ctx));
}

test "eval: GREATEST/LEAST non-numeric string raises NotANumber" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectError(error.NotANumber, eval("GREATEST('abc', 5)", &ctx));
    try testing.expectError(error.NotANumber, eval("LEAST(5, 'xyz')", &ctx));
}

test "eval: GREATEST/LEAST wrong arg count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectError(error.WrongArgCount, eval("GREATEST()", &ctx));
    try testing.expectError(error.WrongArgCount, eval("LEAST()", &ctx));
}

// ------------------------------------------------------------
// Date helpers — Hinnant round-trip + ISO weekday anchors
// ------------------------------------------------------------

test "ymdToEpochDay / epochDayToYmd round-trip" {
    // Anchor: 1970-01-01 = epoch_day 0.
    try testing.expectEqual(@as(i64, 0), ymdToEpochDay(1970, 1, 1));
    const p0 = epochDayToYmd(0);
    try testing.expectEqual(@as(i32, 1970), p0.year);
    try testing.expectEqual(@as(u32, 1), p0.month);
    try testing.expectEqual(@as(u32, 1), p0.day);
    // Leap day round-trip.
    const leap_ep = ymdToEpochDay(2024, 2, 29);
    const leap = epochDayToYmd(leap_ep);
    try testing.expectEqual(@as(i32, 2024), leap.year);
    try testing.expectEqual(@as(u32, 2), leap.month);
    try testing.expectEqual(@as(u32, 29), leap.day);
    // Pre-epoch date.
    const pre = epochDayToYmd(ymdToEpochDay(1900, 6, 15));
    try testing.expectEqual(@as(i32, 1900), pre.year);
    try testing.expectEqual(@as(u32, 6), pre.month);
    try testing.expectEqual(@as(u32, 15), pre.day);
}

test "isoWeekday: Monday=1, Sunday=7" {
    // 1970-01-01 was Thursday.
    try testing.expectEqual(@as(u32, 4), isoWeekday(ymdToEpochDay(1970, 1, 1)));
    // 2026-05-25 (today's reference) is Monday.
    try testing.expectEqual(@as(u32, 1), isoWeekday(ymdToEpochDay(2026, 5, 25)));
    // 2026-05-31 = Sunday.
    try testing.expectEqual(@as(u32, 7), isoWeekday(ymdToEpochDay(2026, 5, 31)));
    // Negative epoch_day path — 1969-12-31 was Wednesday.
    try testing.expectEqual(@as(u32, 3), isoWeekday(ymdToEpochDay(1969, 12, 31)));
}

// ------------------------------------------------------------
// Date builtins
// ------------------------------------------------------------

test "eval: DATEADD calendar arithmetic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("2024-01-03", try evalString("DATEADD('2024-01-01', 2)", &ctx));
    try testing.expectEqualStrings("2023-12-30", try evalString("DATEADD('2024-01-01', -2)", &ctx));
    // Month rollover.
    try testing.expectEqualStrings("2024-02-01", try evalString("DATEADD('2024-01-31', 1)", &ctx));
    // Leap year — 2024-02-28 + 1 = 2024-02-29 (leap day).
    try testing.expectEqualStrings("2024-02-29", try evalString("DATEADD('2024-02-28', 1)", &ctx));
    // Year rollover.
    try testing.expectEqualStrings("2025-01-01", try evalString("DATEADD('2024-12-31', 1)", &ctx));
}

test "eval: DATEDIFF returns calendar days" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("2", try evalString("DATEDIFF('2024-01-03', '2024-01-01')", &ctx));
    try testing.expectEqualStrings("-2", try evalString("DATEDIFF('2024-01-01', '2024-01-03')", &ctx));
    try testing.expectEqualStrings("0", try evalString("DATEDIFF('2024-01-15', '2024-01-15')", &ctx));
    // Across leap year boundary.
    try testing.expectEqualStrings("366", try evalString("DATEDIFF('2025-01-01', '2024-01-01')", &ctx));
}

test "eval: WORKDAY skips weekends" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    // 2024-01-04 = Thursday. T+2 = Monday 2024-01-08 (not Saturday).
    try testing.expectEqualStrings("2024-01-08", try evalString("WORKDAY('2024-01-04', 2)", &ctx));
    // T+1 from Friday = next Monday.
    try testing.expectEqualStrings("2024-01-08", try evalString("WORKDAY('2024-01-05', 1)", &ctx));
    // T+2 from Monday = Wednesday (no weekend in between).
    try testing.expectEqualStrings("2024-01-10", try evalString("WORKDAY('2024-01-08', 2)", &ctx));
    // n=0 returns input unchanged (Excel semantics).
    try testing.expectEqualStrings("2024-01-06", try evalString("WORKDAY('2024-01-06', 0)", &ctx));
    // Negative n — back-dating settlement.
    try testing.expectEqualStrings("2024-01-04", try evalString("WORKDAY('2024-01-08', -2)", &ctx));
}

test "eval: YEAR / MONTH / DAY / WEEKDAY extract components" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("2026", try evalString("YEAR('2026-05-25')", &ctx));
    try testing.expectEqualStrings("5",    try evalString("MONTH('2026-05-25')", &ctx));
    try testing.expectEqualStrings("25",   try evalString("DAY('2026-05-25')", &ctx));
    // 2026-05-25 was Monday.
    try testing.expectEqualStrings("1",    try evalString("WEEKDAY('2026-05-25')", &ctx));
    // 2026-05-31 was Sunday.
    try testing.expectEqualStrings("7",    try evalString("WEEKDAY('2026-05-31')", &ctx));
}

test "eval: EOMONTH snaps to month end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("2024-01-31", try evalString("EOMONTH('2024-01-15')", &ctx));
    // February non-leap.
    try testing.expectEqualStrings("2023-02-28", try evalString("EOMONTH('2023-02-10')", &ctx));
    // February leap.
    try testing.expectEqualStrings("2024-02-29", try evalString("EOMONTH('2024-02-10')", &ctx));
    // December rollover handled correctly.
    try testing.expectEqualStrings("2024-12-31", try evalString("EOMONTH('2024-12-01')", &ctx));
    // Already last day of month — returns same day.
    try testing.expectEqualStrings("2024-04-30", try evalString("EOMONTH('2024-04-30')", &ctx));
}

test "eval: date builtins reject malformed dates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectError(error.InvalidDate, eval("YEAR('2024/01/15')", &ctx));
    try testing.expectError(error.InvalidDate, eval("MONTH('not-a-date')", &ctx));
    try testing.expectError(error.InvalidDate, eval("DATEADD('2024-13-01', 1)", &ctx));
    try testing.expectError(error.InvalidDate, eval("DATEDIFF('2024-01-01', 'bad')", &ctx));
    try testing.expectError(error.InvalidDate, eval("WORKDAY('24-01-01', 1)", &ctx));
}

test "eval: date builtins arg count errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectError(error.WrongArgCount, eval("DATEADD('2024-01-01')", &ctx));
    try testing.expectError(error.WrongArgCount, eval("DATEDIFF('2024-01-01')", &ctx));
    try testing.expectError(error.WrongArgCount, eval("WORKDAY('2024-01-01')", &ctx));
    try testing.expectError(error.WrongArgCount, eval("YEAR()", &ctx));
    try testing.expectError(error.WrongArgCount, eval("MONTH('a', 'b')", &ctx));
    try testing.expectError(error.WrongArgCount, eval("DAY()", &ctx));
    try testing.expectError(error.WrongArgCount, eval("WEEKDAY()", &ctx));
    try testing.expectError(error.WrongArgCount, eval("EOMONTH()", &ctx));
}

test "eval: date builtins return empty string on empty input (no error)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    try h.col_index.put("Date", 0);
    // Blank field — every date builtin must silently pass through ""
    // (matches DATE_CONVERT's blank-tolerant contract).
    const ctx = h.ctx(&.{""}, a);
    try testing.expectEqualStrings("", try evalString("YEAR([Date])", &ctx));
    try testing.expectEqualStrings("", try evalString("MONTH([Date])", &ctx));
    try testing.expectEqualStrings("", try evalString("DAY([Date])", &ctx));
    try testing.expectEqualStrings("", try evalString("WEEKDAY([Date])", &ctx));
    try testing.expectEqualStrings("", try evalString("EOMONTH([Date])", &ctx));
    try testing.expectEqualStrings("", try evalString("DATEADD([Date], 2)", &ctx));
    try testing.expectEqualStrings("", try evalString("WORKDAY([Date], 2)", &ctx));
    try testing.expectEqualStrings("", try evalString("DATEDIFF([Date], '2024-01-01')", &ctx));
    try testing.expectEqualStrings("", try evalString("DATEDIFF('2024-01-01', [Date])", &ctx));
}

test "eval: date builtins compose with DATE_CONVERT for non-canonical input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    try h.col_index.put("TradeDate", 0);
    // T212 reports "DD.MM.YYYY"; chain DATE_CONVERT → DATEADD for T+2 settlement.
    const ctx = h.ctx(&.{"15.01.2024"}, a);
    try testing.expectEqualStrings(
        "2024-01-17",
        try evalString("DATEADD(DATE_CONVERT([TradeDate], 'DD.MM.YYYY', 'YYYY-MM-DD'), 2)", &ctx),
    );
}
