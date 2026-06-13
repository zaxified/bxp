/// Expression evaluator used to compute input_schema variable values.
///
/// Expressions are evaluated against a single CSV row represented by a Context.
/// The evaluator is a single-pass recursive-descent parser that produces a Value
/// (string, fixed-point decimal, or boolean) without building an intermediate AST.
/// Numeric values use a fixed-point Decimal core (i128 @ scale 1e12) — see
/// `decimal.zig` — so decimal money math is exact (`0.02 + 0.08 == 0.10`).
///
/// Operator precedence (highest to lowest):
///   unary -
///   * /       (numeric multiply / divide)
///   &         (string concatenation)
///   + -       (numeric add / subtract)
///   = != < > <= >=  (comparison; string equality only for = and !=)
///   NOT       (boolean negation; binds looser than comparison, tighter than AND)
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
///   RAND(n)                   — string of n random digits (first 1–9, rest 0–9; n clamped 1–65)
///   COALESCE(a, b, ...)       — first non-empty argument (empty = whitespace-only string)
///   DATE_CONVERT(f, from, to) — reformat a date/time string; format tokens use datefmt syntax
///   PRICE_VALUE(f)            — strip currency symbol/code, return numeric string
///   PRICE_CURRENCY(f)         — extract currency code from a price string
///   TICKER(f)                 — map field value through broker's ticker_map
///   LOOKUP([name,] key, field) — retrieve a value stored by a pre_pass table
const std = @import("std");
const datefmt = @import("datefmt.zig");
const unicode = @import("unicode.zig");
const encoding = @import("encoding");
const Decimal = @import("decimal").Decimal;

/// Re-export so callers that already import the `expr` module (bxp-cli pipeline,
/// the inspect core, bxp-mcp) can name the encoding type / helpers without a separate dependency.
pub const Encoding = encoding.Encoding;

// ---------------------------------------------------------------------------
// Value — the three types an expression can produce
// ---------------------------------------------------------------------------

pub const Value = union(enum) {
    string: []const u8,
    decimal: Decimal,
    boolean: bool,

    /// Returns the value as a string slice, allocated with alloc when needed.
    /// Decimals format their integer part, then up to 12 fractional digits
    /// with trailing zeros trimmed (no float formatter — see decimal.zig).
    pub fn toString(self: Value, alloc: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .string => |s| s,
            .decimal => |d| try d.toString(alloc),
            .boolean => |b| if (b) "true" else "false",
        };
    }

    pub fn toNumber(self: Value) !Decimal {
        return switch (self) {
            .decimal => |d| d,
            // Empty string is treated as zero so that optional/missing CSV
            // fields don't cause arithmetic failures — callers can gate with
            // COALESCE or IF if they need to distinguish "no value" from 0.
            // The non-finite tokens "nan"/"inf"/"-inf" (case-insensitive) are
            // treated the same as empty: they are missing/undefined numeric
            // data, typically a bad CSV export artifact (a division-by-zero or
            // dropped value), and must NOT turn an otherwise-working numeric
            // expression into a counted error. Coercing to 0 mirrors the
            // empty-field contract and reproduces the historical silent-skip
            // for index args (0 → not a positive index → "").
            // American thousands-separated numbers ("1,234.56") are tried
            // after the plain decimal parse fails, so they don't pay the
            // parseGroupedNumber overhead when the input is a plain decimal.
            .string => |s| if (s.len == 0 or isNonFiniteToken(s)) Decimal.zero else
                Decimal.parse(s) orelse
                parseGroupedNumber(s, ',', '.') orelse
                return error.NotANumber,
            .boolean => |b| if (b) Decimal.one else Decimal.zero,
        };
    }

    pub fn toBool(self: Value) bool {
        return switch (self) {
            .boolean => |b| b,
            .decimal => |d| !d.isZero(),
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
    /// alongside `lookup_table == null` (the inspect.annotateRaw deep
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
    /// Layer 0 input encoding for raw CSV field bytes (`csv_input_encoding`).
    /// `.utf8` (default) is a pass-through; any other value transcodes each
    /// accessed field value to UTF-8 in `field()`. JSON / xlsx inputs are
    /// always UTF-8 and leave this at the default.
    input_encoding: encoding.Encoding = .utf8,
    /// When non-null, the evaluator writes a human-readable description of the last
    /// error here before returning the error.  String is allocated with ctx.alloc.
    /// Caller sets this and resets the pointed value to "" before each eval call.
    error_detail: ?*[]const u8 = null,
    /// Phase G1: byte offset of the offending token in the expression
    /// source. Set by the Parser/Tokenizer alongside `error_detail` so
    /// callers (inspect.validateExpr stderr, inspect.annotateRaw $err_* shape)
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
        const trimmed = std.mem.trim(u8, self.fields[idx], " ");
        // Layer 0: transcode legacy single-byte input to UTF-8 on access. The
        // default `.utf8` short-circuits with no allocation (the hot path).
        // Structural CSV bytes are ASCII, so trimming first (ASCII spaces) and
        // transcoding the result is order-independent. Data-lenient: a transcode
        // failure (OOM) falls back to the raw bytes rather than propagating.
        if (self.input_encoding == .utf8) return trimmed;
        return encoding.decodeToUtf8(self.alloc, trimmed, self.input_encoding) catch trimmed;
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
    field_ref, // [ColumnName] (header-name lookup; positional access is FIELDS(n))
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
    /// Phase 3B (tokenize-once): when non-null, `next`/`peek` replay these
    /// pre-tokenized tokens instead of lexing `src` again. Built once per file
    /// by `tokenizeAll`; `cache_idx` is the replay cursor. `src` is kept as the
    /// original source so token slices and trace offsets stay valid.
    cache: ?[]const Token = null,
    cache_idx: usize = 0,

    fn init(src: []const u8) Tokenizer {
        return .{ .src = src, .pos = 0 };
    }

    /// Tokenizer that replays a cached token slice (no re-lexing). The slice
    /// must end with the `.eof` token produced by `tokenizeAll`.
    fn initCache(src: []const u8, toks: []const Token) Tokenizer {
        return .{ .src = src, .pos = 0, .cache = toks };
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
        // Phase 3B: replay from the token cache (no re-lexing). Keep `pos` and
        // `last_offset`/`last_len` in sync so error spans and the function-call
        // trace (which read `tok.pos` / `tok.src`) behave exactly as the lexing
        // path. Past the cached `.eof`, keep returning eof.
        if (self.cache) |c| {
            const tok = if (self.cache_idx < c.len)
                c[self.cache_idx]
            else
                Token{ .kind = .eof, .text = "", .offset = @intCast(self.src.len), .len = 0 };
            self.cache_idx += 1;
            self.last_offset = tok.offset;
            self.last_len = tok.len;
            self.pos = tok.offset + tok.len;
            return tok;
        }
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
        if (self.cache != null) {
            const saved = self.cache_idx;
            const tok = try self.next();
            self.cache_idx = saved;
            return tok;
        }
        const saved = self.pos;
        const tok = try self.next();
        self.pos = saved;
        return tok;
    }
};

/// Phase G4 date-format diagnostic shape. Re-exported for external
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
    /// `date_format` violation — bad format string literal.
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
            .positive_integer, .date_format => return true,
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
            // Mirrors the toPositiveIndex helper that runtime FIELDS /
            // SPLIT_PART use: a literal that overflows the fixed-point range
            // (e.g. `1e30`) is treated as a violation with bad_idx clamped to
            // a printable sentinel; otherwise the integer part is checked for
            // the "≤ 0" mistake.
            const d = Decimal.parse(first.text) orelse {
                out.split_part = .{
                    .bad_idx = 0,
                    .off = first.offset,
                    .len = first.len,
                };
                return;
            };
            const v = d.trunc();
            // Flag exactly what toPositiveIndex rejects at runtime: an
            // integer part below 1, or one beyond a usable usize index
            // (both yield a silent "" — worth surfacing in the editor).
            if (v < 1 or v > std.math.maxInt(usize)) out.split_part = .{
                .bad_idx = if (v >= std.math.minInt(i64) and v <= std.math.maxInt(i64)) @intCast(v) else 0,
                .off = first.offset,
                .len = first.len,
            };
        },
        .date_format => {
            if (first.kind != .string_lit) return;
            if (out.date_format != null) return;
            if (datefmt.firstInvalidFormatChar(first.text)) |pos| {
                out.date_format = .{
                    .fmt = first.text,
                    .pos = pos,
                    .off = first.offset,
                    .len = first.len,
                };
            }
        },
        // No static literal check: runtime-only domains + plain string /
        // expr args. (A literal-range warning for integer_in_range is a
        // deliberate non-goal — validateArgs clamps it at runtime.)
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

/// Phase G8: collect static cross-reference data from an expression
/// source. Walks tokens (no AST, no eval) and gathers:
///   - `fields` set: every `[ColumnName]` reference, by name. A bracketed
///     numeric `[4]` is just a header-name lookup for a column literally
///     named "4" (positional access is FIELDS(n), not `[n]`), so it is
///     recorded here like any other name.
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

        // [Name] field references — record by name. An all-digit bracket name
        // (`[4]`) is a header-name lookup for a column literally named "4", no
        // different from any other name: it goes into `fields` like the rest, so
        // constant-folding correctly treats it as a row-varying reference and the
        // typo consumer validates it against the real headers. (Positional access
        // by column number is FIELDS(n), not `[n]`.)
        if (t.kind == .field_ref) {
            if (t.text.len == 0) continue;
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

/// True when an expression's value is row-invariant — it references no input
/// column (`[Col]`), no positional field (`FIELDS(n)`) and no `LOOKUP` table,
/// and contains no nondeterministic builtin (`NOW`/`RAND`). Such an expression
/// yields the same value for every row, so it can be evaluated once per file
/// and the result reused (constant folding). Conservative: any uncertainty
/// (computed LOOKUP name, tokenizer error) returns false, leaving the
/// expression on the normal per-row path.
pub fn isRowInvariant(src: []const u8, alloc: std.mem.Allocator) bool {
    var refs = staticReferences(src, alloc) catch return false;
    defer refs.deinit();
    if (refs.fields.count() != 0) return false;
    if (refs.lookups.count() != 0) return false;
    if (refs.has_two_arg_lookup or refs.has_computed_lookup_name) return false;

    // Reject the two nondeterministic builtins (NOW/RAND) and the positional
    // field accessor FIELDS(n): the latter reads row state through a numeric
    // index, which carries no `[Name]` field_ref token for `staticReferences`
    // to catch, so it must be rejected here or it would be wrongly folded to a
    // single empty value. Token-level check (not a substring scan) so a string
    // literal like 'KNOW' is not mistaken for NOW.
    var tok = Tokenizer.init(src);
    while (true) {
        const t = tok.next() catch return false;
        if (t.kind == .eof) break;
        if (t.kind != .ident) continue;
        if (std.ascii.eqlIgnoreCase(t.text, "NOW")) return false;
        if (std.ascii.eqlIgnoreCase(t.text, "RAND")) return false;
        if (std.ascii.eqlIgnoreCase(t.text, "FIELDS")) return false;
    }
    return true;
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
    /// expression with N FN-calls translates to N writes. `inspect.evalTrace`
    /// (and the in-process `bridge_eval_expr_trace`)
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
            .decimal => |d| d.toString(self.ctx.alloc) catch return,
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
            const ord = ln.?.order(rn.?); // exact integer compare at the same scale
            return Value{ .boolean = switch (op) {
                .eq => ord == .eq,
                .neq => ord != .eq,
                .lt => ord == .lt,
                .gt => ord == .gt,
                .lte => ord != .gt,
                .gte => ord != .lt,
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
            const res = if (t.kind == .plus) l.add(r) else l.sub(r);
            left = Value{ .decimal = res orelse return error.NumberOverflow };
        }
        return left;
    }

    // cat_expr := mul_expr ('&' mul_expr)*
    fn parseCat(self: *Parser) anyerror!Value {
        const left = try self.parseMul();
        // Common case: no '&' — return the operand untouched, no allocation.
        if ((try self.tok.peek()).kind != .amp) return left;

        // One or more concatenations: collect every operand's string form and
        // join once at the end. Joining pairwise (`a & b & c & …`) would copy
        // the growing prefix per operator → O(n²); a single `concat` over the
        // segment list is O(total length).
        var segs: std.ArrayListUnmanaged([]const u8) = .empty;
        try segs.append(self.ctx.alloc, try left.toString(self.ctx.alloc));
        while (true) {
            const t = try self.tok.peek();
            if (t.kind != .amp) break;
            _ = try self.tok.next();
            const right = try self.parseMul();
            try segs.append(self.ctx.alloc, try right.toString(self.ctx.alloc));
        }
        return Value{ .string = try std.mem.concat(self.ctx.alloc, u8, segs.items) };
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
                if (l.div(r)) |q| {
                    left = Value{ .decimal = q };
                } else {
                    left = Value{ .string = "" };
                }
            } else {
                left = Value{ .decimal = l.mul(r) orelse return error.NumberOverflow };
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
            return Value{ .decimal = n.neg() orelse return error.NumberOverflow };
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
            // The lexer guarantees a syntactically valid number; parse can
            // still fail (null) on a literal that overflows the i128 range.
            .number_lit => return Value{ .decimal = Decimal.parse(t.text) orelse return error.NumberOutOfRange },
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

    /// Resolves [ColumnName] — a header-name lookup only.
    /// A numeric `[4]` is NOT positional access: it looks up a column literally
    /// named "4" (normally absent → ""). Positional access by column number is
    /// FIELDS(n). Keeping the two syntaxes disjoint avoids a numeric `[n]`
    /// silently constant-folding to "" (it carries no resolvable header).
    /// When decimal_sep_in is not '.', numeric-looking field values are normalized
    /// so that the decimal separator becomes '.' for correct arithmetic evaluation.
    fn evalFieldRef(self: *Parser, name: []const u8) !Value {
        const raw = self.ctx.fieldByName(name);

        // Record the field name so setNotANumber can include it in error
        // detail — "[Price]" in the message is far more actionable than
        // a bare "not a number: '1.234,56'" when decimal_sep_in is wrong.
        self.last_field_name = name;

        return Value{ .string = try normalizeFieldDecimalSep(raw, self.ctx) };
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
        // Args accumulate into an inline stack buffer for the common small-
        // arity case (no per-call allocation); only a variadic call
        // (COALESCE/IN/GREATEST/LEAST) exceeding the inline slots spills the
        // tail into the arena. The individual Value.string slices may point
        // into ctx.fields (no alloc) or into ctx.alloc-owned strings (concat,
        // date-format results, etc.); whichever backing the slice uses, the
        // strings it holds are either static or arena-owned and will outlive
        // the call frame.
        var arg_acc: ArgAccumulator = .empty;
        var t = try self.tok.peek();
        while (t.kind != .rparen and t.kind != .eof) {
            try arg_acc.append(self.ctx.alloc, try self.parseExpr());
            t = try self.tok.peek();
            if (t.kind == .comma) {
                _ = try self.tok.next();
                t = try self.tok.peek();
            }
        }
        _ = try self.tok.next(); // consume ')'
        const args = arg_acc.slice();

        // O(1) dispatch: uppercase the ident once and look it up in the
        // comptime `builtin_index`. Idents longer than any builtin name, or
        // not in the map, fall through to the unknown-function path. A lazy
        // entry (only IF today, already handled above) is never dispatched
        // here — its `impl` is null.
        if (name.len <= max_builtin_name_len) {
            var name_buf: [max_builtin_name_len]u8 = undefined;
            const upper = std.ascii.upperString(name_buf[0..name.len], name);
            if (builtin_index.get(upper)) |idx| {
                const b = builtins[idx];
                if (!b.lazy) {
                    if (try self.validateArgs(b.doc, args)) |short_circuit|
                        return short_circuit;
                    return b.impl.?(self, args);
                }
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
                .expr, .string, .literal_string, .date_format, .pre_pass_name => {},
                .number => _ = args[i].toNumber() catch {
                    switch (args[i]) {
                        .string => |s| self.setNotANumber(s),
                        else => {},
                    }
                    return error.NotANumber;
                },
                .finite_number => {
                    // The fixed-point core is always finite; this domain now
                    // only enforces that the arg is numeric at all.
                    _ = args[i].toNumber() catch {
                        switch (args[i]) {
                            .string => |s| self.setNotANumber(s),
                            else => {},
                        }
                        return error.NotANumber;
                    };
                },
                .positive_integer => {
                    // Split failure policy, preserving historical behavior:
                    // non-numeric input → loud NotANumber; a valid number
                    // that is not a positive index (≤ 0) → silent skip to "".
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
                        const t = n.trunc(); // integer part toward zero
                        const clamped = @max(@min(t, @as(i128, r.max)), @as(i128, r.min));
                        args[i] = .{ .decimal = Decimal.fromInt(clamped) };
                    } else |_| {}
                },
            }
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Catalog types — exposed via `inspect.docsJson` for the GUI's expression
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
/// `inspect.docsJson` JSON the GUI autocomplete reads.
///
/// Runtime failure policy is chosen per variant to preserve the historical
/// observable behavior of the impls these guards replaced — see the
/// `validateArgs` table below. Adding a new builtin = declare its arg
/// domains here; it is then safe-by-construction (no per-impl validation).
///
/// A `union(enum)` (not a plain enum) because `integer_in_range` carries a
/// `{min,max}` payload. GUI-facing tag names (`expr`, `string`,
/// `literal_string`, `date_format`, `pre_pass_name`) are deliberately
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
    /// Bare string literal containing a datefmt token pattern. Drives
    /// `expr.BadDateFormat` diagnostics for DATE_CONVERT arg[1]/arg[2].
    date_format,
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
    /// Runnable one-line example shown (and click-to-insert) in the
    /// bxp-gui FUNCTIONS doc panel. Empty (default) = no example. Every
    /// non-empty example must parse against a synthetic Context — guarded
    /// by the `FnDoc examples parse` test below.
    example: []const u8 = "",
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

/// Argument accumulator used by `evalCall`. Collects parsed args into an
/// inline stack array — covering every fixed-arity builtin (max 4 args) and
/// the typical variadic call — so the common path allocates nothing. A
/// variadic call (COALESCE/IN/GREATEST/LEAST) that exceeds the inline slots
/// migrates the inline contents into an arena-backed list on first overflow
/// so the returned slice stays contiguous.
const ArgAccumulator = struct {
    const inline_cap = 8;
    buf: [inline_cap]Value = undefined,
    n: usize = 0,
    spill: std.ArrayListUnmanaged(Value) = .empty,

    const empty: ArgAccumulator = .{};

    fn append(self: *ArgAccumulator, alloc: std.mem.Allocator, v: Value) !void {
        if (self.spill.items.len > 0) {
            try self.spill.append(alloc, v);
        } else if (self.n < inline_cap) {
            self.buf[self.n] = v;
            self.n += 1;
        } else {
            try self.spill.ensureTotalCapacity(alloc, inline_cap * 2);
            self.spill.appendSliceAssumeCapacity(self.buf[0..self.n]);
            self.spill.appendAssumeCapacity(v);
        }
    }

    /// Mutable view of the collected args — `validateArgs` may coerce in place.
    fn slice(self: *ArgAccumulator) []Value {
        return if (self.spill.items.len > 0) self.spill.items else self.buf[0..self.n];
    }
};

/// IF — lazy/short-circuit. The dispatcher matches IF by name BEFORE reaching
/// the table loop and parses its own arg list via Parser; no adapter exists.
const if_doc: FnDoc = .{
    .name = "IF",
    .signature = "IF(cond, yes, no)",
    .example = "IF(1 < 0, 'yes', 'no')",
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

/// True for the non-finite tokens `nan` / `inf` / `infinity` (case-insensitive,
/// optional leading sign, surrounding whitespace ignored). These are treated as
/// missing numeric data — coerced to 0 like an empty field — so a bad-export
/// artifact does not raise a (counted) error on an otherwise-working numeric
/// expression. See `Value.toNumber`.
fn isNonFiniteToken(s: []const u8) bool {
    var body = std.mem.trim(u8, s, " \t\r\n");
    if (body.len > 0 and (body[0] == '+' or body[0] == '-')) body = body[1..];
    return std.ascii.eqlIgnoreCase(body, "nan") or
        std.ascii.eqlIgnoreCase(body, "inf") or
        std.ascii.eqlIgnoreCase(body, "infinity");
}

/// Parses a number in thousands-grouped format, generalised over both
/// American (`thousands=','`, `decimal='.'`) and European (`thousands='.'`,
/// `decimal=','`) conventions. Accepts:
///   `[-]?d{1,3}(<thousands>d{3})+(<decimal>d+)?`
/// Requires at least one thousands group — plain numbers without grouping
/// (`"123"`, `"1,5"`, `"1.5"`) are the caller's `Decimal.parse` responsibility.
/// Returns null if `s` does not match the pattern for the given separators.
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
fn parseGroupedNumber(s: []const u8, thousands: u8, decimal: u8) ?Decimal {
    var i: usize = 0;
    if (i < s.len and s[i] == '-') i += 1;
    // 1–3 leading digits before the first thousands group
    const leading_start = i;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    const leading = i - leading_start;
    if (leading == 0 or leading > 3) return null;
    // At least one '<thousands>ddd' group required
    var groups: usize = 0;
    while (i < s.len and s[i] == thousands) {
        if (s.len < i + 4) return null;
        if (!std.ascii.isDigit(s[i + 1]) or
            !std.ascii.isDigit(s[i + 2]) or
            !std.ascii.isDigit(s[i + 3])) return null;
        i += 4;
        groups += 1;
        // A digit immediately after the group means >3 digits between separators → invalid
        if (i < s.len and std.ascii.isDigit(s[i])) return null;
    }
    if (groups == 0) return null;
    // Optional decimal part
    if (i < s.len) {
        if (s[i] != decimal) return null;
        i += 1;
        if (i >= s.len or !std.ascii.isDigit(s[i])) return null;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    }
    if (i != s.len) return null;
    // Strip thousands and rewrite the decimal char to '.' into a stack
    // buffer, then re-parse with the fixed-point decimal parser. The 40-byte
    // buffer covers any value the fixed-point range can hold (≈27 integer
    // digits + dot + 12 fractional), far beyond what 3+N*4 digits can express.
    var buf: [40]u8 = undefined;
    var bi: usize = 0;
    for (s) |c| {
        if (c == thousands) continue;
        if (bi >= buf.len) return null;
        buf[bi] = if (c == decimal) '.' else c;
        bi += 1;
    }
    return Decimal.parse(buf[0..bi]);
}

// ---------------------------------------------------------------------------
// Built-in function implementations
// ---------------------------------------------------------------------------

/// Convert a Decimal to a 1-based positive integer index, or return null for
/// "silent skip" semantics (caller should return Value{ .string = "" }).
///
/// The fixed-point core has no Inf/NaN, so the only gate left is the
/// integer-part value: anything below 1 (≤ 0) would underflow on the typical
/// `idx - 1` access, and a value past usize is clamped out.
///
/// Use this in every builtin that converts a user-supplied numeric arg to a
/// usize index (FIELDS, SPLIT_PART, future similar). The `positive_integer`
/// ArgKind domain wires the same gate into the central `validateArgs`.
fn toPositiveIndex(d: Decimal) ?usize {
    const t = d.trunc(); // integer part, toward zero
    if (t < 1 or t > std.math.maxInt(usize)) return null;
    return @intCast(t);
}

/// Sane upper bound (in days) for date-offset arithmetic — ±10 000 years,
/// far beyond any realistic settlement / maturity offset.
const MAX_DATE_OFFSET_DAYS: i64 = 3_652_500;

/// Convert a user-supplied Decimal day offset (DATEADD / WORKDAY arg `n`) to
/// an i64, or return null for "silent skip" — beyond ±MAX_DATE_OFFSET_DAYS.
/// Day offsets are always small (T+2, +30, +365), so rejecting huge values
/// matches the date builtins' "blank/invalid → ''" contract. Non-numeric args
/// are caught earlier by the `.number` domain.
fn toDayOffset(d: Decimal) ?i64 {
    const t = d.trunc();
    if (t > MAX_DATE_OFFSET_DAYS or t < -MAX_DATE_OFFSET_DAYS) return null;
    return @intCast(t);
}

/// Truncate a numeric arg to i32, or null when out of i32 range. Used by
/// integer-component date builtins (NTH_DOW) where `@intCast` from a wider
/// type would otherwise panic on absurd inputs.
fn toI32Arg(d: Decimal) ?i32 {
    const t = d.trunc();
    if (t > std.math.maxInt(i32) or t < std.math.minInt(i32)) return null;
    return @intCast(t);
}

/// Maximum decimal precision a ROUND call will honour. The fixed-point core
/// holds 12 fractional digits; values past that are clamped by ROUND itself.
/// Kept as the `integer_in_range` clamp bound for the `n` argument.
const ROUND_MAX_PRECISION: i32 = 30;

// ── ABS ─────────────────────────────────────────────────────────────────
const abs_doc: FnDoc = .{
    .name = "ABS",
    .signature = "ABS(f)",
    .example = "ABS(-12.5)",
    .description = "Absolute numeric value.",
    .args = &.{.{ .name = "f", .kind = .number }},
    .min_args = 1,
    .max_args = 1,
};
// Arity + the `.number` domain on `f` are enforced centrally in
// `validateArgs`, so the impl receives a guaranteed-numeric arg and the
// adapter no longer needs a NotANumber catch (plain signature forward).
fn builtinAbs(args: []Value) !Value {
    return Value{ .decimal = (try args[0].toNumber()).abs() orelse return error.NumberOverflow };
}
fn adaptAbs(_: *Parser, args: []Value) anyerror!Value {
    return builtinAbs(args);
}

// ── FIELDS ──────────────────────────────────────────────────────────────
const fields_doc: FnDoc = .{
    .name = "FIELDS",
    .signature = "FIELDS(n)",
    .example = "FIELDS(2)",
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
    .example = "PRICE_VALUE('$1,234.56')",
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
    .example = "PRICE_CURRENCY('$1,234.56')",
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
    .example = "TICKER('AAPL')",
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
    .example = "LOOKUP('AAPL', 'name')",
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
    // the historical "silent '' on miss" contract that inspect.validateExpr
    // also relies on (LOOKUP in bare contexts must not blow up).
    if (ctx.pre_pass_names) |names| {
        const name: []const u8 = if (args.len == 3) switch (args[0]) {
            .string => |v| v,
            else => return error.StringExpected,
        } else ctx.single_prepass_name orelse return error.LookupRequiresName;
        if (!names.contains(name)) return error.LookupUnknownPrePass;
        return Value{ .string = "" };
    }
    // No lookup_table → either validation context (inspect.validateExpr) or runtime
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
    .example = "SPLIT_PART('AAPL.US', '.', 1)",
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
    .example = "CONTAINS('Apple Inc', 'Inc')",
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
    .example = "REPLACE('A.B.C', '.', '-')",
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
    .example = "NOW()",
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
    .example = "TRIM('  hello  ')",
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
    .example = "ROUND(3.14159, 2)",
    .description = "Round `f` to `n` decimal places (half away from zero, like Excel: `ROUND(2.5,0)=3`). `n=0` rounds to the nearest integer; `n<0` rounds to tens/hundreds/etc. (`n=-2` → nearest 100); `n>=12` is a no-op (12 is the fixed-point scale). `n` is clamped to ±30.",
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
/// ROUND(f, n) — round f to n decimal places, half-away-from-zero (Excel-style).
/// n >= 0: round to n places after decimal point; n < 0: round to tens/hundreds/etc.
/// `validateArgs` clamps `n` to ±ROUND_MAX_PRECISION (the integer_in_range
/// domain) before this runs; the local clamp below stays as defence-in-depth.
fn builtinRound(args: []Value) !Value {
    const x = try args[0].toNumber();
    const n_t = (try args[1].toNumber()).trunc(); // integer part of n
    const n_clamped = @max(@min(n_t, @as(i128, ROUND_MAX_PRECISION)), -@as(i128, ROUND_MAX_PRECISION));
    return Value{ .decimal = x.round(@intCast(n_clamped)) };
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
    .example = "FLOOR(3.7)",
    .description = "Round `f` down to nearest integer.",
    .args = &.{.{ .name = "f", .kind = .number }},
    .min_args = 1,
    .max_args = 1,
};
/// FLOOR(f) — largest integer less than or equal to f.
fn builtinFloor(args: []Value) !Value {
    return Value{ .decimal = (try args[0].toNumber()).floor() };
}
fn adaptFloor(_: *Parser, args: []Value) anyerror!Value {
    return builtinFloor(args);
}

// ── CEILING ─────────────────────────────────────────────────────────────
const ceiling_doc: FnDoc = .{
    .name = "CEILING",
    .signature = "CEILING(f)",
    .example = "CEILING(3.2)",
    .description = "Round `f` up to nearest integer.",
    .args = &.{.{ .name = "f", .kind = .number }},
    .min_args = 1,
    .max_args = 1,
};
/// CEILING(f) — smallest integer greater than or equal to f.
fn builtinCeiling(args: []Value) !Value {
    return Value{ .decimal = (try args[0].toNumber()).ceil() };
}
fn adaptCeiling(_: *Parser, args: []Value) anyerror!Value {
    return builtinCeiling(args);
}

// ── RAND ────────────────────────────────────────────────────────────────
/// Upper bound on RAND(n) digit count. Matches MySQL's `DECIMAL(M,…)` max
/// precision (M ≤ 65) — the most widely-recognised "max digits" limit across
/// SQL engines. `n` is clamped to `[1, 65]` by the integer_in_range guard.
const RAND_MAX_DIGITS: i64 = 65;
const rand_doc: FnDoc = .{
    .name = "RAND",
    .signature = "RAND(n)",
    .example = "RAND(8)",
    .description = "A string of exactly `n` random digits (each position 0–9, except the first which is 1–9 so a leading zero can't be dropped by a downstream numeric import). Use it for synthetic IDs; `n` is clamped to [1, 65]. Cryptographically seeded — not for security tokens.",
    .args = &.{
        .{ .name = "n", .kind = .{ .integer_in_range = .{
            .min = 1,
            .max = RAND_MAX_DIGITS,
        } } },
    },
    .min_args = 1,
    .max_args = 1,
};
/// RAND(n) — a string of exactly n random digits (first digit 1–9, rest 0–9),
/// returned as a passthrough string so it bypasses the 12-decimal fixed-point
/// scale entirely (unbounded digit count up to n=65). `validateArgs` has
/// already clamped a numeric n to [1, 65] via the integer_in_range domain
/// before this runs.
fn adaptRand(p: *Parser, args: []Value) anyerror!Value {
    const t = (args[0].toNumber() catch {
        switch (args[0]) {
            .string => |s| p.setNotANumber(s),
            else => {},
        }
        return error.NotANumber;
    }).trunc();
    // Defence-in-depth: the guard clamps numeric args, but re-clamp here so the
    // length is always a sane usize even if the guard contract ever changes.
    const n: usize = @intCast(@max(1, @min(t, @as(i128, RAND_MAX_DIGITS))));
    const buf = try p.ctx.alloc.alloc(u8, n);
    buf[0] = '1' + std.crypto.random.intRangeLessThan(u8, 0, 9); // 1..9
    for (buf[1..]) |*c| c.* = '0' + std.crypto.random.intRangeLessThan(u8, 0, 10); // 0..9
    return Value{ .string = buf };
}

// ── COALESCE ────────────────────────────────────────────────────────────
const coalesce_doc: FnDoc = .{
    .name = "COALESCE",
    .signature = "COALESCE(a, b, ...)",
    .example = "COALESCE('', 'fallback')",
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
/// verbatim so callers can supply a default: COALESCE([a], [b], '0').
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
            .decimal, .boolean => return v,
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
    .example = "DATE_CONVERT('31.12.2024', 'DD.MM.YYYY', 'YYYY-MM-DD')",
    .description = "Reformat a date/time string. Format tokens: YYYY (year), MM/M (month), MMM/MMMM (month name), DD/D (day), hh/h (hour), mm/m (minute), ss/s (second), [literal] (literal characters), [*] (wildcard).",
    .args = &.{
        .{ .name = "f", .kind = .string },
        .{ .name = "from", .kind = .date_format },
        .{ .name = "to", .kind = .date_format },
    },
    .min_args = 3,
    .max_args = 3,
};
/// Parses the input string according to from_fmt, then formats the result
/// according to to_fmt.  Both format strings use the datefmt token syntax:
///   YYYY  MM/M  MMM/MMMM  DD/D  hh/h  mm/m  ss/s  [literal]  [*]=wildcard
/// See `datefmt.zig` for the full token list.
///
/// This is a pure field reshuffle (parse → DateParts → format); it never
/// round-trips through an epoch timestamp, so any year — including pre-1970 —
/// converts losslessly.
///
/// When from_fmt contains the MMM token, the input is pre-processed by
/// normalizeMonthAbbrev to handle non-standard 4-character month abbreviations
/// (e.g. "Sept" → "Sep") before parsing.
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
    // the 3-character form that the MMM token expects. Allocation happens only
    // when the input actually contains a matching word — the common case (no
    // MMM token in from_fmt) skips the work entirely.
    const normalized = if (containsMMM(from_fmt))
        try normalizeMonthAbbrev(input, alloc)
    else
        input;
    // Parse failures silently produce an empty string (no warning, no summary entry).
    // Rationale: broker files frequently contain rows where a date field is blank
    // (e.g. a cash row that has no settlement date). A silent "" is preferable to
    // an error that aborts processing of every subsequent row in the file.
    const parts = datefmt.parse(normalized, from_fmt) catch {
        return Value{ .string = "" };
    };
    return Value{ .string = try datefmt.format(alloc, parts, to_fmt) };
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
/// normalisation — it expects the full name ("September") and datefmt handles it
/// natively. Only MMM (abbreviated: "Sep") needs our pre-processing step because
/// some brokers export 4-letter variants that the MMM token doesn't recognise.
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
    .example = "LEFT('AAPL.US', 4)",
    .description = "Return the first `n` bytes of `s`. `n` is clamped to `[0, len(s)]`; negative `n` returns \"\".",
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
    const t = (try args[1].toNumber()).trunc(); // integer part of n
    if (t < 0) return Value{ .string = "" };
    const n: usize = if (t > s.len) s.len else @intCast(t);
    return Value{ .string = s[0..n] };
}
fn adaptLeft(_: *Parser, args: []Value) anyerror!Value {
    return builtinLeft(args);
}

// ── RIGHT ───────────────────────────────────────────────────────────────
const right_doc: FnDoc = .{
    .name = "RIGHT",
    .signature = "RIGHT(s, n)",
    .example = "RIGHT('AAPL.US', 2)",
    .description = "Return the last `n` bytes of `s`. `n` is clamped to `[0, len(s)]`; negative `n` returns \"\".",
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
    const t = (try args[1].toNumber()).trunc(); // integer part of n
    if (t < 0) return Value{ .string = "" };
    const n: usize = if (t > s.len) s.len else @intCast(t);
    return Value{ .string = s[s.len - n ..] };
}
fn adaptRight(_: *Parser, args: []Value) anyerror!Value {
    return builtinRight(args);
}

// ── SUBSTR ──────────────────────────────────────────────────────────────
const substr_doc: FnDoc = .{
    .name = "SUBSTR",
    .signature = "SUBSTR(s, start, length)",
    .example = "SUBSTR('AAPL.US', 1, 4)",
    .description = "Return `length` bytes from `s` starting at 1-based position `start`. Returns \"\" when `start` is non-positive / past end of `s`, or when `length` is negative. `length` is clamped to the bytes remaining from `start`.",
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
    const len_t = (try args[2].toNumber()).trunc(); // integer part of length
    if (len_t < 0) return Value{ .string = "" };
    if (start > s.len) return Value{ .string = "" };
    const begin = start - 1;
    const avail = s.len - begin;
    const len: usize = if (len_t > avail) avail else @intCast(len_t);
    return Value{ .string = s[begin .. begin + len] };
}
fn adaptSubstr(_: *Parser, args: []Value) anyerror!Value {
    return builtinSubstr(args);
}

// ── UPPER ───────────────────────────────────────────────────────────────
const upper_doc: FnDoc = .{
    .name = "UPPER",
    .signature = "UPPER(s)",
    .example = "UPPER('aapl')",
    .description = "Full-Unicode upper-case conversion: works across Latin, Greek, Cyrillic, etc. (café → CAFÉ, ß → SS); unicameral scripts (CJK, Arabic, Hebrew) pass through unchanged. Invalid UTF-8 bytes pass through verbatim.",
    .args = &.{.{ .name = "s", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinUpper(args: []Value, alloc: std.mem.Allocator) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    return Value{ .string = try unicode.toUpperStr(alloc, s) };
}
fn adaptUpper(p: *Parser, args: []Value) anyerror!Value {
    return builtinUpper(args, p.ctx.alloc);
}

// ── LOWER ───────────────────────────────────────────────────────────────
const lower_doc: FnDoc = .{
    .name = "LOWER",
    .signature = "LOWER(s)",
    .example = "LOWER('AAPL')",
    .description = "Full-Unicode lower-case conversion: works across Latin, Greek, Cyrillic, etc. (CAFÉ → café, Я → я); unicameral scripts (CJK, Arabic, Hebrew) pass through unchanged. Invalid UTF-8 bytes pass through verbatim.",
    .args = &.{.{ .name = "s", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinLower(args: []Value, alloc: std.mem.Allocator) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    return Value{ .string = try unicode.toLowerStr(alloc, s) };
}
fn adaptLower(p: *Parser, args: []Value) anyerror!Value {
    return builtinLower(args, p.ctx.alloc);
}

// ── UNACCENT ────────────────────────────────────────────────────────────
const unaccent_doc: FnDoc = .{
    .name = "UNACCENT",
    .signature = "UNACCENT(s)",
    .example = "UNACCENT('Café Crème')",
    .description = "Strip diacritics from Latin text (café → cafe, ÀÉÎ → AEI, ß → ss, ø → o). Latin-scope like Postgres unaccent: non-Latin letters keep their base script (Greek Ά → Α, not A) and CJK/Arabic pass through unchanged; ligatures are NOT folded. Invalid UTF-8 bytes pass through verbatim.",
    .args = &.{.{ .name = "s", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinUnaccent(args: []Value, alloc: std.mem.Allocator) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    return Value{ .string = try unicode.unaccentStr(alloc, s) };
}
fn adaptUnaccent(p: *Parser, args: []Value) anyerror!Value {
    return builtinUnaccent(args, p.ctx.alloc);
}

// ── STARTS_WITH ─────────────────────────────────────────────────────────
const starts_with_doc: FnDoc = .{
    .name = "STARTS_WITH",
    .signature = "STARTS_WITH(s, prefix)",
    .example = "STARTS_WITH('US123', 'US')",
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
    .example = "ENDS_WITH('AAPL.PR', '.PR')",
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
    .example = "NULLIF('N/A', 'N/A')",
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
        if (ln.?.eql(rn.?)) return Value{ .string = "" };
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
    .example = "IN('BUY', 'BUY', 'SELL')",
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
                if (l.eql(r)) return Value{ .boolean = true };
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
// The civil-date primitives live in `datefmt.zig` (the single date core that
// replaced the sunrise dependency). Aliased here so the builtins below read
// unchanged; `datefmt` implements Howard Hinnant's `days_from_civil` /
// `civil_from_days` — branch-free O(1), exact across the i32 year range,
// negative (pre-1970) dates included.
// ---------------------------------------------------------------------------

const DateParts = datefmt.DateParts;
const parseYmd = datefmt.parseIsoDate;
const ymdToEpochDay = datefmt.ymdToEpochDay;
const epochDayToYmd = datefmt.epochDayToYmd;
const isoWeekday = datefmt.isoWeekday;
const formatYmd = datefmt.formatIsoDate;

/// Parse arg[0] as a date string and return its epoch day. On parse failure
/// writes a descriptive diagnostic via `setDetail` and returns InvalidDate so
/// callers see a clickable error in the validator / GUI. Empty input must be
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
    .example = "DATEADD('2024-01-31', 7)",
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
    .example = "DATEDIFF('2024-01-01', '2024-12-31')",
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
    return Value{ .decimal = Decimal.fromInt(d1 - d2) };
}
fn adaptDateDiff(p: *Parser, args: []Value) anyerror!Value {
    return builtinDateDiff(p, args);
}

// ── WORKDAY ─────────────────────────────────────────────────────────────
const workday_doc: FnDoc = .{
    .name = "WORKDAY",
    .signature = "WORKDAY(d, n)",
    .example = "WORKDAY('2024-01-01', 10)",
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
    .example = "YEAR('2024-03-15')",
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
    return Value{ .decimal = Decimal.fromInt(parts.year) };
}
fn adaptYear(p: *Parser, args: []Value) anyerror!Value {
    return builtinYear(p, args);
}

// ── MONTH ───────────────────────────────────────────────────────────────
const month_doc: FnDoc = .{
    .name = "MONTH",
    .signature = "MONTH(d)",
    .example = "MONTH('2024-03-15')",
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
    return Value{ .decimal = Decimal.fromInt(parts.month) };
}
fn adaptMonth(p: *Parser, args: []Value) anyerror!Value {
    return builtinMonth(p, args);
}

// ── DAY ─────────────────────────────────────────────────────────────────
const day_doc: FnDoc = .{
    .name = "DAY",
    .signature = "DAY(d)",
    .example = "DAY('2024-03-15')",
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
    return Value{ .decimal = Decimal.fromInt(parts.day) };
}
fn adaptDay(p: *Parser, args: []Value) anyerror!Value {
    return builtinDay(p, args);
}

// ── WEEKDAY ─────────────────────────────────────────────────────────────
const weekday_doc: FnDoc = .{
    .name = "WEEKDAY",
    .signature = "WEEKDAY(d)",
    .example = "WEEKDAY('2024-03-15')",
    .description = "ISO day-of-week for date `d` (YYYY-MM-DD): Monday=1 … Sunday=7. Useful for weekend-trade detection: `WEEKDAY([Date]) > 5`.",
    .args = &.{.{ .name = "d", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinWeekday(p: *Parser, args: []Value) !Value {
    const s = switch (args[0]) { .string => |v| v, else => return error.StringExpected };
    if (s.len == 0) return Value{ .string = "" };
    const ep = try parseDateArg(p, s);
    return Value{ .decimal = Decimal.fromInt(isoWeekday(ep)) };
}
fn adaptWeekday(p: *Parser, args: []Value) anyerror!Value {
    return builtinWeekday(p, args);
}

// ── EOMONTH ─────────────────────────────────────────────────────────────
const eomonth_doc: FnDoc = .{
    .name = "EOMONTH",
    .signature = "EOMONTH(d)",
    .example = "EOMONTH('2024-02-10')",
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

// ── NTH_DOW ─────────────────────────────────────────────────────────────
const nth_dow_doc: FnDoc = .{
    .name = "NTH_DOW",
    .signature = "NTH_DOW(year, month, weekday, n)",
    .example = "NTH_DOW(2024, 3, 7, -1)",
    .description = "Date (YYYY-MM-DD) of the `n`-th `weekday` (ISO Mon=1 … Sun=7) in `year`/`month`. Positive `n` counts from the start (1 = first); negative counts from the end (-1 = last). Returns \"\" when the occurrence doesn't exist or an argument is out of range. Handy for DST boundaries — EU summer time is `NTH_DOW(YEAR(d), 3, 7, -1)` (last Sunday of March) to `NTH_DOW(YEAR(d), 10, 7, -1)` (last Sunday of October).",
    .args = &.{
        .{ .name = "year", .kind = .number },
        .{ .name = "month", .kind = .number },
        .{ .name = "weekday", .kind = .number },
        .{ .name = "n", .kind = .number },
    },
    .min_args = 4,
    .max_args = 4,
};
fn builtinNthDow(p: *Parser, args: []Value) !Value {
    const year = toI32Arg(try args[0].toNumber()) orelse return Value{ .string = "" };
    const month = toI32Arg(try args[1].toNumber()) orelse return Value{ .string = "" };
    const weekday = toI32Arg(try args[2].toNumber()) orelse return Value{ .string = "" };
    const n = toI32Arg(try args[3].toNumber()) orelse return Value{ .string = "" };
    const parts = datefmt.nthWeekdayOfMonth(year, month, weekday, n) orelse return Value{ .string = "" };
    return Value{ .string = try datefmt.formatIsoDate(p.ctx.alloc, parts) };
}
fn adaptNthDow(p: *Parser, args: []Value) anyerror!Value {
    return builtinNthDow(p, args);
}

// ── LEN ─────────────────────────────────────────────────────────────────
const len_doc: FnDoc = .{
    .name = "LEN",
    .signature = "LEN(s)",
    .example = "LEN('hello')",
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
    return Value{ .decimal = Decimal.fromInt(@intCast(s.len)) };
}
fn adaptLen(_: *Parser, args: []Value) anyerror!Value {
    return builtinLen(args);
}

// ── GREATEST ────────────────────────────────────────────────────────────
const greatest_doc: FnDoc = .{
    .name = "GREATEST",
    .signature = "GREATEST(a, b, ...)",
    .example = "GREATEST(3, 7, 5)",
    .description = "Largest numeric value among arguments. Per-row maximum (not aggregation across rows). Arguments are coerced to numbers; empty string coerces to 0, non-numeric strings raise an error.",
    // Variadic 1+ args. Like COALESCE, only the first arg is declared;
    // trailing args inherit `kind = .expr` semantically.
    .args = &.{.{ .name = "a", .kind = .number }},
    .min_args = 1,
    .max_args = 255,
};
fn builtinGreatest(args: []Value) !Value {
    var best: Decimal = try args[0].toNumber();
    for (args[1..]) |v| {
        const n = try v.toNumber();
        if (n.order(best) == .gt) best = n;
    }
    return Value{ .decimal = best };
}
fn adaptGreatest(p: *Parser, args: []Value) anyerror!Value {
    return builtinGreatest(args) catch |err| {
        for (args) |v| switch (v) {
            .string => |s| if (!stringIsNumeric(s)) {
                p.setNotANumber(s);
                return err;
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
    .example = "LEAST(3, 7, 5)",
    .description = "Smallest numeric value among arguments. Per-row minimum (not aggregation across rows). Arguments are coerced to numbers; empty string coerces to 0, non-numeric strings raise an error.",
    .args = &.{.{ .name = "a", .kind = .number }},
    .min_args = 1,
    .max_args = 255,
};
fn builtinLeast(args: []Value) !Value {
    var best: Decimal = try args[0].toNumber();
    for (args[1..]) |v| {
        const n = try v.toNumber();
        if (n.order(best) == .lt) best = n;
    }
    return Value{ .decimal = best };
}
fn adaptLeast(p: *Parser, args: []Value) anyerror!Value {
    return builtinLeast(args) catch |err| {
        for (args) |v| switch (v) {
            .string => |s| if (!stringIsNumeric(s)) {
                p.setNotANumber(s);
                return err;
            },
            else => {},
        };
        return err;
    };
}

/// True when `s` coerces to a number under the same rules as `Value.toNumber`
/// (empty → 0, plain decimal, or thousands-grouped). Used by GREATEST/LEAST
/// adapters to pinpoint the offending non-numeric argument for diagnostics.
fn stringIsNumeric(s: []const u8) bool {
    if (s.len == 0 or isNonFiniteToken(s)) return true;
    return Decimal.parse(s) != null or parseGroupedNumber(s, ',', '.') != null;
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

/// Applies `decimal_sep_in` locale normalisation to a raw field value: when the
/// configured separator is not '.', a recognised numeric shape has its separator
/// swapped to '.' so downstream arithmetic and output see a canonical decimal.
/// Two shapes are recognised:
///   * Plain decimal-only ("1234,56", "-1,5"): one alternate separator, digits
///     otherwise — validated by `isNumericWithSep`, converted by swapping it.
///   * Grouped EU thousands ("1.234,56", "-1.234.567,89"): '.' thousands groups +
///     optional decimal — validated by `parseGroupedNumber`, converted by
///     stripping '.' and swapping the decimal char.
///
/// This is a PURE STRING operation: it swaps the separator character WITHOUT
/// converting to a number (the `parseGroupedNumber` call is only a validity
/// predicate; its value is discarded). So a high-precision value — a 15-digit
/// coordinate "40,718807220458984" or a long ID — keeps every digit and never
/// touches the fixed-point core; nothing is quantised to 12 decimals.
///
/// Shared by the fused field-ref path (`Parser.evalFieldRef`) and the compiled
/// `col_ref` fast path so both locale-normalise identically. Non-numeric input,
/// or a default '.' separator, returns `raw` unchanged.
fn normalizeFieldDecimalSep(raw: []const u8, ctx: *const Context) ![]const u8 {
    if (ctx.decimal_sep_in == '.') return raw;
    const sep = ctx.decimal_sep_in;
    if (parseGroupedNumber(raw, '.', sep) != null) {
        const copy = try ctx.alloc.alloc(u8, raw.len);
        var ci: usize = 0;
        for (raw) |c| {
            if (c == '.') continue;
            copy[ci] = if (c == sep) '.' else c;
            ci += 1;
        }
        return copy[0..ci];
    }
    if (std.mem.indexOfScalar(u8, raw, sep) != null and Parser.isNumericWithSep(raw, sep)) {
        const copy = try ctx.alloc.dupe(u8, raw);
        std.mem.replaceScalar(u8, copy, sep, '.');
        return copy;
    }
    return raw;
}

/// True for numeric-looking strings that must NOT be re-formatted, because
/// doing so would corrupt them:
///   - leading-zero integers ("07666", "00012345") — ZIP / postal codes /
///     zero-padded IDs whose leading zeros carry meaning;
///   - long all-digit integers (>15 digits) — e.g. a 21-digit account/order
///     ID. Short-circuited verbatim before any numeric parse touches them.
fn isPrecisionSensitiveText(s: []const u8) bool {
    if (s.len >= 2 and s[0] == '0' and s[1] >= '0' and s[1] <= '9') return true;
    if (s.len > 15) {
        for (s) |c| if (c < '0' or c > '9') return false;
        return true;
    }
    return false;
}

/// Evaluates src and returns the result as a string allocated with ctx.alloc.
///
/// Only STRING results (passthrough fields, string literals, concatenation)
/// are canonicalised here, via canonicaliseNumericString. Computed .decimal
/// results are already exact (fixed-point) and formatted by Value.toString,
/// and must NOT be re-touched. Routing a passthrough string through the
/// numeric core would quantise it to 12 decimals, truncating high-precision
/// data (e.g. coordinates) — hence the string-only canonicalisation below.
pub fn evalString(src: []const u8, ctx: *const Context) ![]const u8 {
    const v = try eval(src, ctx);
    const s = try v.toString(ctx.alloc);
    return switch (v) {
        .string => canonicaliseNumericString(s, ctx.alloc),
        else => s,
    };
}

// ---------------------------------------------------------------------------
// Phase 3B — compile-once / eval-many (incremental, fallback-based)
// ---------------------------------------------------------------------------
//
// A `Node` is a compiled expression form, built once per file (when the file's
// `col_index` is known) and re-evaluated per row WITHOUT re-tokenizing or
// re-parsing the source string. The split is introduced incrementally: every
// shape `compile` does not yet specialise collapses to `.raw`, which simply
// re-invokes the fused `eval`/`evalString` — byte-identical to the legacy path.
// Each later phase teaches `compile` (and `evalNodeString`) one more node kind,
// shrinking the `.raw` fallback set, and is gated bit-by-bit on its own.

/// One compiled expression. Non-exhaustive in spirit: `.raw` is the catch-all
/// that preserves exact legacy behaviour for any construct not yet lowered.
pub const Node = union(enum) {
    /// Unspecialised: re-parse + evaluate `src` with the fused evaluator.
    raw: []const u8,
    /// A bare `[Name]` column reference, resolved against this file's header.
    /// `null` = the column is absent in this file (evaluates to "").
    col_ref: ?usize,
    /// Phase 3B (tokenize-once): the expression source plus its tokens, lexed
    /// once. Per row the parser/evaluator runs over `tokens` without re-lexing
    /// `src`. `src` is retained for trace offsets and error context.
    tokenized: struct { src: []const u8, tokens: []const Token },
};

/// Lex `src` into an owned token slice ending in `.eof`. Propagates the
/// tokenizer's `error.UnexpectedChar` so the caller can fall back to `.raw`.
fn tokenizeAll(src: []const u8, alloc: std.mem.Allocator) ![]const Token {
    var list: std.ArrayList(Token) = .empty;
    errdefer list.deinit(alloc);
    var tok = Tokenizer.init(src);
    while (true) {
        const t = try tok.next();
        try list.append(alloc, t);
        if (t.kind == .eof) break;
    }
    return list.toOwnedSlice(alloc);
}

/// Compile `src` against a (per-file) `col_index` into a `Node`. Never fails to
/// produce a node: anything unsupported becomes `.raw`.
pub fn compile(src: []const u8, col_index: *const std.StringHashMap(usize), alloc: std.mem.Allocator) Node {
    // Empty source: the fused evaluator short-circuits to "" — keep `.raw`.
    if (src.len == 0) return .{ .raw = src };
    // A source that is exactly one column reference `[Name]` — resolve the index
    // once (no per-row hash lookup). A numeric `[4]` is a name lookup for a column
    // named "4" like any other, so it qualifies too (col_index.get("4")).
    var tok = Tokenizer.init(src);
    const t0 = tok.next() catch return .{ .raw = src };
    if (t0.kind == .field_ref and t0.text.len > 0) {
        const t1 = tok.next() catch return .{ .raw = src };
        if (t1.kind == .eof) return .{ .col_ref = col_index.get(t0.text) };
    }
    // Tokenize-once: lex the whole expression now; per row the parser replays
    // these tokens. On a lex error, fall back to `.raw` (the per-row path
    // re-lexes and fails identically).
    const toks = tokenizeAll(src, alloc) catch return .{ .raw = src };
    return .{ .tokenized = .{ .src = src, .tokens = toks } };
}

/// Evaluate a compiled node to a `Value`, byte-identical to `eval(src, ctx)`
/// for the equivalent source. Used where the caller needs the raw value (e.g.
/// `row_rules` `when` → `.toBool()`), not the string coercion.
pub fn evalNode(node: *const Node, ctx: *const Context) !Value {
    switch (node.*) {
        .raw => |s| return eval(s, ctx),
        // Mirrors eval("[Name]"): the trimmed field value (or "" when absent),
        // locale-normalised exactly as `Parser.evalFieldRef` does, with no
        // numeric canonicalisation (that is an evalString concern).
        .col_ref => |idx| return Value{ .string = if (idx) |i| try normalizeFieldDecimalSep(ctx.field(i), ctx) else "" },
        .tokenized => |nd| {
            var p = Parser{ .tok = Tokenizer.initCache(nd.src, nd.tokens), .ctx = ctx };
            return p.parseExpr();
        },
    }
}

/// Evaluate a compiled node to its string form, byte-identical to
/// `evalString(src, ctx)` for the equivalent source.
pub fn evalNodeString(node: *const Node, ctx: *const Context) ![]const u8 {
    switch (node.*) {
        .raw => |s| return evalString(s, ctx),
        // Mirrors evalString("[Name]"): eval yields the trimmed, locale-
        // normalised field string (or "" when the column is absent), then
        // canonicaliseNumericString.
        .col_ref => |idx| {
            const raw = if (idx) |i| try normalizeFieldDecimalSep(ctx.field(i), ctx) else "";
            return canonicaliseNumericString(raw, ctx.alloc);
        },
        // Mirrors eval(src)+evalString coercion, but parses over cached tokens.
        .tokenized => {
            const v = try evalNode(node, ctx);
            const s = try v.toString(ctx.alloc);
            return switch (v) {
                .string => canonicaliseNumericString(s, ctx.alloc),
                else => s,
            };
        },
    }
}

/// Canonicalises a STRING value that may look numeric, WITHOUT quantising it
/// through the fixed-point core (which would truncate high-precision
/// passthrough data to 12 decimals):
///   - leading-zero / oversized integers → verbatim (isPrecisionSensitiveText);
///   - scientific notation ("1.23E+15")  → expanded to a plain decimal (the one
///     case that genuinely needs a numeric round-trip);
///   - plain decimals with trailing zeros → zeros trimmed as a STRING op, so
///     every significant digit survives ("1000.00"→"1000",
///     "0.0313646200"→"0.03136462", but "40.7940823884086" is kept intact);
///   - non-numeric strings and plain integers → verbatim.
///
/// `Decimal.parse` serves only as the "is this numeric (and in range)?"
/// predicate and to expand scientific notation; the plain-decimal branch
/// trims the ORIGINAL string so no precision is lost.
fn canonicaliseNumericString(s: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    if (isPrecisionSensitiveText(s)) return s;
    // Must parse as a fixed-point number to be treated as numeric at all
    // (e.g. "BUY", grouped "1,234.56", out-of-range "1e30" → verbatim).
    const d = Decimal.parse(s) orelse return s;
    // Scientific notation is the only form needing numeric expansion.
    if (std.mem.indexOfAny(u8, s, "eE")) |_| {
        return d.toString(alloc);
    }
    // Plain decimal: trim trailing zeros (and a dangling '.') as a string op.
    if (std.mem.indexOfScalar(u8, s, '.')) |_| {
        var end = s.len;
        while (end > 1 and s[end - 1] == '0') end -= 1;
        if (end > 0 and s[end - 1] == '.') end -= 1;
        return s[0..end];
    }
    return s;
}

// ---------------------------------------------------------------------------
// Catalog — single source of truth for FnDoc / OperatorDoc / KeywordDoc /
// TokenDoc surfaced by `inspect.docsJson` and consumed by the GUI. Per-fn
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
    .{ .name = "UNACCENT",       .doc = unaccent_doc,       .impl = adaptUnaccent },
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
    .{ .name = "NTH_DOW",        .doc = nth_dow_doc,        .impl = adaptNthDow },
};

/// Longest builtin name (PRICE_CURRENCY = 14). `evalCall` uppercases the call
/// ident into a stack buffer of this size for the `builtin_index` lookup; a
/// longer ident cannot match any builtin, so it skips the map and falls
/// straight to the unknown-function path.
pub const max_builtin_name_len = blk: {
    var m: usize = 0;
    for (builtins) |b| m = @max(m, b.name.len);
    break :blk m;
};

/// Comptime name → `builtins` index map. Names in the catalog are already
/// uppercase, so `evalCall` uppercases the call ident once and does an O(1)
/// lookup here instead of a linear `eqlIgnoreCase` scan per call per row.
const builtin_index = std.StaticStringMap(usize).initComptime(blk: {
    var entries: [builtins.len]struct { []const u8, usize } = undefined;
    for (builtins, 0..) |b, i| entries[i] = .{ b.name, i };
    break :blk entries;
});

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

/// Test helper: build a Value.decimal from a literal numeric string.
fn dec(s: []const u8) Value {
    return Value{ .decimal = Decimal.parse(s).? };
}
/// Test helper: assert a toNumber() result equals the given literal.
fn expectNum(want: []const u8, v: Value) !void {
    try testing.expectEqual(Decimal.parse(want).?.raw, (try v.toNumber()).raw);
}

test "Value.toString: integer-valued decimal has no decimal point" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("7", try dec("7").toString(arena.allocator()));
    try testing.expectEqualStrings("-3", try dec("-3").toString(arena.allocator()));
    try testing.expectEqualStrings("0", try dec("0").toString(arena.allocator()));
}

test "Value.toString: decimal trims trailing zeros" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("1.5", try dec("1.5").toString(arena.allocator()));
    try testing.expectEqualStrings("1.25", try dec("1.25").toString(arena.allocator()));
}

test "Value.toString: bool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("true", try (Value{ .boolean = true }).toString(arena.allocator()));
    try testing.expectEqualStrings("false", try (Value{ .boolean = false }).toString(arena.allocator()));
}

test "Value.toNumber: empty string returns 0" {
    try testing.expectEqual(@as(i128, 0), (try (Value{ .string = "" }).toNumber()).raw);
}

test "Value.toNumber: numeric string is parsed" {
    try expectNum("42", Value{ .string = "42" });
    try expectNum("-1.5", Value{ .string = "-1.5" });
}

test "Value.toNumber: non-numeric string returns error" {
    try testing.expectError(error.NotANumber, (Value{ .string = "abc" }).toNumber());
}

test "Value.toNumber: American thousands-separated format" {
    try expectNum("1234.56", Value{ .string = "1,234.56" });
    try expectNum("1234567", Value{ .string = "1,234,567" });
    try expectNum("-1234.5", Value{ .string = "-1,234.5" });
    try expectNum("1000", Value{ .string = "1,000" });
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

test "evalString: leading zeros and oversized ids preserved; exp/normal still normalised" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    try h.col_index.put("Zip", 0);
    try h.col_index.put("Id", 1);
    try h.col_index.put("Sci", 2);
    try h.col_index.put("Amount", 3);
    const ctx = h.ctx(&.{ "07666", "123456789012345678901", "1.23E+15", "1000.00" }, a);
    // Leading-zero integers (ZIP / zero-padded IDs) must survive verbatim.
    try testing.expectEqualStrings("07666", try evalString("[Zip]", &ctx));
    try testing.expectEqualStrings("007", try evalString("'007'", &ctx));
    // Oversized integer ID — never enters the numeric core, so no corruption.
    try testing.expectEqualStrings("123456789012345678901", try evalString("[Id]", &ctx));
    // Scientific notation still expands to a plain decimal.
    try testing.expectEqualStrings("1230000000000000", try evalString("[Sci]", &ctx));
    // In-range plain decimal is still normalised (trailing zeros dropped).
    try testing.expectEqualStrings("1000", try evalString("[Amount]", &ctx));
}

test "evalString: high-precision passthrough decimals keep every significant digit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    try h.col_index.put("Lat", 0);
    try h.col_index.put("Lon", 1);
    try h.col_index.put("Padded", 2);
    const ctx = h.ctx(&.{ "40.7940823884086", "-73.9561344937861", "0.0313646200" }, a);
    // A passthrough coordinate string must NOT be quantised to 12 decimals
    // by the numeric core — it has no trailing zeros, so it survives verbatim
    // (13 fractional digits, beyond the fixed-point scale, kept intact).
    try testing.expectEqualStrings("40.7940823884086", try evalString("[Lat]", &ctx));
    try testing.expectEqualStrings("-73.9561344937861", try evalString("[Lon]", &ctx));
    // Zero-padded broker quantities are still canonicalised by a string-only
    // trailing-zero trim (no precision loss, byte-identical to the old output).
    try testing.expectEqualStrings("0.03136462", try evalString("[Padded]", &ctx));
    // Computed (.decimal) results are now exact fixed-point: the literal
    // 8.6299999999974 (13 frac digits) quantises to 12 places (13th digit 4 →
    // rounds down). No {d:.8} cap masks it any more — represented faithfully.
    try testing.expectEqualStrings("8.629999999997", try evalString("ABS(0 - 8.6299999999974)", &ctx));
}

test "Value.toBool: empty string is false, non-empty is true (even '0')" {
    try testing.expect(!(Value{ .string = "" }).toBool());
    try testing.expect((Value{ .string = "0" }).toBool()); // non-empty string → true!
    try testing.expect((Value{ .string = "hello" }).toBool());
}

test "Value.toBool: numeric zero is false, non-zero is true" {
    try testing.expect(!dec("0").toBool());
    try testing.expect(dec("1").toBool());
    try testing.expect(dec("-1").toBool());
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

test "eval: [n] numeric is a name lookup, not positional (use FIELDS for position)" {
    // Bracket refs resolve by header name only. A numeric `[1]` looks up a
    // column literally named "1"; with no such header it yields "". Positional
    // access by column number is FIELDS(n) (covered by the FIELDS tests).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{ "first", "second", "third" }, a);
    try testing.expectEqualStrings("", try evalString("[1]", &ctx));
    try testing.expectEqualStrings("first", try evalString("FIELDS(1)", &ctx));
    // A header genuinely named "1" is resolved by name like any other column.
    var h2 = TestHelper.init(a);
    try h2.col_index.put("1", 0);
    const ctx2 = h2.ctx(&.{"hit"}, a);
    try testing.expectEqualStrings("hit", try evalString("[1]", &ctx2));
}

test "isRowInvariant: numeric bracket [4] counts as a field ref (never folded)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `[4]` references a column literally named "4" — row-varying, so constant
    // folding must NOT prove it invariant (else a real "4" column would freeze
    // to one row's value).
    try testing.expect(!isRowInvariant("[4]", a));
    try testing.expect(!isRowInvariant("SPLIT_PART([4], '^', 1)", a));
    // Sanity: a pure literal still folds; FIELDS(n) and [Name] do not.
    try testing.expect(isRowInvariant("'xT212'", a));
    try testing.expect(!isRowInvariant("FIELDS(4)", a));
    try testing.expect(!isRowInvariant("[Valeur]", a));
}

test "eval: unknown column name returns empty string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{ "only" }, a);
    try testing.expectEqualStrings("", try evalString("[Missing]", &ctx));
}

test "eval: decimal_sep_in=',' normalises numeric field value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    try h.col_index.put("V", 0);
    var ctx = h.ctx(&.{ "1,5" }, a);
    ctx.decimal_sep_in = ',';
    // The field "1,5" is recognised as numeric → comma replaced by dot → "1.5"
    try testing.expectEqualStrings("1.5", try evalString("[V]", &ctx));
}

test "eval: decimal_sep_in=',' leaves non-numeric fields unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    try h.col_index.put("V", 0);
    var ctx = h.ctx(&.{ "hello,world" }, a);
    ctx.decimal_sep_in = ',';
    try testing.expectEqualStrings("hello,world", try evalString("[V]", &ctx));
}

test "eval: decimal_sep_in=',' parses EU thousands group (1.234,56)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    try h.col_index.put("V", 0);
    var ctx = h.ctx(&.{ "1.234,56" }, a);
    ctx.decimal_sep_in = ',';
    try testing.expectEqualStrings("1234.56", try evalString("[V]", &ctx));
}

test "eval: decimal_sep_in=',' parses multi-group EU thousands (-1.234.567,89)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    try h.col_index.put("V", 0);
    var ctx = h.ctx(&.{ "-1.234.567,89" }, a);
    ctx.decimal_sep_in = ',';
    try testing.expectEqualStrings("-1234567.89", try evalString("[V]", &ctx));
}

test "eval: decimal_sep_in=',' parses integer-only EU thousands (1.234)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    try h.col_index.put("V", 0);
    var ctx = h.ctx(&.{ "1.234" }, a);
    ctx.decimal_sep_in = ',';
    try testing.expectEqualStrings("1234", try evalString("[V]", &ctx));
}

test "eval: decimal_sep_in=',' rejects invalid grouping (1.5)" {
    // '.' followed by fewer than 3 digits is not a valid thousands group
    // in EU notation → field is left raw, not converted to "15".
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    try h.col_index.put("V", 0);
    var ctx = h.ctx(&.{ "1.5" }, a);
    ctx.decimal_sep_in = ',';
    try testing.expectEqualStrings("1.5", try evalString("[V]", &ctx));
}

test "eval: decimal_sep_in=',' arithmetic on EU thousands group" {
    // End-to-end: EU thousands value flows through field access into
    // arithmetic and produces the expected numeric result.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    try h.col_index.put("V", 0);
    var ctx = h.ctx(&.{ "1.234,50" }, a);
    ctx.decimal_sep_in = ',';
    try testing.expectEqualStrings("2469", try evalString("[V] * 2", &ctx));
}

test "parseGroupedNumber: American format" {
    try testing.expectEqual(Decimal.parse("1234.56").?.raw, parseGroupedNumber("1,234.56", ',', '.').?.raw);
    try testing.expectEqual(Decimal.parse("-1234567").?.raw, parseGroupedNumber("-1,234,567", ',', '.').?.raw);
    try testing.expectEqual(Decimal.parse("1000").?.raw, parseGroupedNumber("1,000", ',', '.').?.raw);
    try testing.expect(parseGroupedNumber("123", ',', '.') == null);
    try testing.expect(parseGroupedNumber("1,5", ',', '.') == null);
    try testing.expect(parseGroupedNumber("1,2345", ',', '.') == null);
}

test "parseGroupedNumber: European format" {
    try testing.expectEqual(Decimal.parse("1234.56").?.raw, parseGroupedNumber("1.234,56", '.', ',').?.raw);
    try testing.expectEqual(Decimal.parse("-1234567.89").?.raw, parseGroupedNumber("-1.234.567,89", '.', ',').?.raw);
    try testing.expectEqual(Decimal.parse("1234").?.raw, parseGroupedNumber("1.234", '.', ',').?.raw);
    try testing.expect(parseGroupedNumber("1.5", '.', ',') == null);
    try testing.expect(parseGroupedNumber("1.234.5", '.', ',') == null);
    try testing.expect(parseGroupedNumber("1,234.56", '.', ',') == null);
}

// ------------------------------------------------------------
// evalString normalization
// ------------------------------------------------------------

test "evalString: normalises numeric string result (99.00 → 99)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    // Field contains "99.00"; evalString canonicalises it (Decimal-validated,
    // trailing zeros trimmed as a string op) → "99".
    try h.col_index.put("V", 0);
    const ctx = h.ctx(&.{ "99.00" }, a);
    try testing.expectEqualStrings("99", try evalString("[V]", &ctx));
}

test "col_ref fast-path: decimal_sep_in normalisation matches fused evalFieldRef" {
    // Regression: the compiled `.col_ref` fast path for a bare `[Name]` used to
    // call ctx.field() directly, skipping the decimal_sep_in locale swap that
    // the fused evalFieldRef applies — so a passthrough `[Valeur]` kept its
    // French comma. Both paths must now produce byte-identical output.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "346,50", .want = "346.5" }, // plain comma decimal
        .{ .in = "1.234,56", .want = "1234.56" }, // EU thousands grouping
        // High-precision comma coordinate: separator swapped, every digit kept
        // (pure string op — never quantised through the fixed-point core).
        .{ .in = "40,718807220458984", .want = "40.718807220458984" },
    };
    for (cases) |c| {
        var h = TestHelper.init(a);
        try h.col_index.put("V", 0);
        var ctx = h.ctx(&.{c.in}, a);
        ctx.decimal_sep_in = ',';
        const node = compile("[V]", &h.col_index, a);
        try testing.expect(std.meta.activeTag(node) == .col_ref); // exercise the fast path
        const compiled = try evalNodeString(&node, &ctx);
        const fused = try evalString("[V]", &ctx);
        try testing.expectEqualStrings(c.want, fused); // fused is the oracle
        try testing.expectEqualStrings(fused, compiled); // col_ref == fused
    }
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

test "eval: RAND(n) returns exactly n digits, first non-zero" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    for ([_]usize{ 1, 5, 12, 20, 65 }) |want| {
        const expr = try std.fmt.allocPrint(a, "RAND({d})", .{want});
        for (0..20) |_| {
            const v = try eval(expr, &ctx);
            const s = v.string;
            try testing.expectEqual(want, s.len);
            try testing.expect(s[0] >= '1' and s[0] <= '9');
            for (s) |c| try testing.expect(c >= '0' and c <= '9');
        }
    }
}

test "eval: RAND(n) clamps out-of-range n to [1, 65]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqual(@as(usize, 1), (try eval("RAND(0)", &ctx)).string.len);
    try testing.expectEqual(@as(usize, 1), (try eval("RAND(-3)", &ctx)).string.len);
    try testing.expectEqual(@as(usize, 65), (try eval("RAND(100)", &ctx)).string.len);
}

test "eval: RAND requires exactly one arg" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectError(error.WrongArgCount, eval("RAND()", &ctx));
    try testing.expectError(error.WrongArgCount, eval("RAND(5, 6)", &ctx));
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

// 'inf'/'nan' are treated as missing data (→ 0, like an empty field), so a
// positive_integer index of 'inf'/'nan' silently skips to "" (0 is not a valid
// 1-based index) — no counted error. Reproduces the historical silent-skip and
// avoids false errors from bad-export artifacts.
test "eval: FIELDS 'inf'/'nan' index silently skips to empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{"only"}, a);
    try testing.expectEqualStrings("", try evalString("FIELDS('inf')", &ctx));
    try testing.expectEqualStrings("", try evalString("FIELDS('-inf')", &ctx));
    try testing.expectEqualStrings("", try evalString("FIELDS('nan')", &ctx));
}

test "eval: SPLIT_PART 'inf'/'nan' index silently skips to empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("", try evalString("SPLIT_PART('a,b', ',', 'inf')", &ctx));
    try testing.expectEqualStrings("", try evalString("SPLIT_PART('a,b', ',', 'nan')", &ctx));
}

test "eval: 'nan'/'inf' field coerces to 0 in arithmetic (no error)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    try h.col_index.put("Fee", 0);
    // A bad-export 'nan'/'inf' fee degrades to 0, so [Total] - [Fee] still works.
    var ctx = h.ctx(&.{"nan"}, a);
    try testing.expectEqualStrings("100", try evalString("100 - [Fee]", &ctx));
    ctx = h.ctx(&.{"inf"}, a);
    try testing.expectEqualStrings("100", try evalString("100 - [Fee]", &ctx));
}

// staticCheckCalls panic regression — the literal-int-positive arg
// scanner cast `parseFloat(f80) -> i64` without bounds-checking, so a
// finite-but-huge literal (e.g. `1e30`) or a parse-as-Inf literal
// triggered `@intFromFloat` UB. Reachable from user input in three
// places: inspect.validateExpr / --config, bxp-gui-bridge bridge_eval_expr,
// BrokerConfig.validate at startup. Guard now flags such literals as
// "violation with bad_idx=0" and returns without invoking @intFromFloat.
test "staticCheckCalls: SPLIT_PART literal index out-of-i64 range does not panic" {
    // 24-digit positive literal is ≈ 1e24, well past i64 max (~9.22e18) —
    // it parses fine via the i128 Decimal core but is out of usize index
    // range, so it is flagged with the bad_idx=0 printable sentinel.
    // Historically the pre-Decimal scanner cast `parseFloat(f80) → i64`
    // here, which was undefined behaviour and panicked in Debug/ReleaseSafe.
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

// 'inf'/'nan' precision args coerce to 0 (missing → empty contract), so
// ROUND(x, 'inf') rounds to 0 places rather than raising an error.
test "eval: ROUND 'inf'/'nan' precision coerces to 0 places (no error)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("3", try evalString("ROUND(3.14, 'inf')", &ctx));
    try testing.expectEqualStrings("3", try evalString("ROUND(3.14, '-inf')", &ctx));
    try testing.expectEqualStrings("3", try evalString("ROUND(3.14, 'nan')", &ctx));
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
// field-string coercion (Value.toNumber), which still sees them.
// With the fixed-point core there is no Inf/NaN. An in-range huge index clamps
// to the string length; a non-finite token ("Inf"/"NaN") coerces to 0 (missing
// → empty contract) so the length is 0 → ""; a genuinely out-of-range value
// ("1e30", a valid number past ±1.7e26) is a loud NotANumber. The former
// @intFromFloat panic class is gone.
test "eval: LEFT/RIGHT/SUBSTR huge index clamps; 'inf'→0; out-of-range errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    try h.col_index.put("Big", 0); // representable, far past any string length
    try h.col_index.put("Over", 1); // overflows the fixed-point range
    try h.col_index.put("Inf", 2);
    const ctx = h.ctx(&.{ "999999999", "1e30", "Inf" }, a);
    // In-range huge index clamps to the available length.
    try testing.expectEqualStrings("hello", try evalString("LEFT('hello', [Big])", &ctx));
    try testing.expectEqualStrings("hello", try evalString("RIGHT('hello', [Big])", &ctx));
    try testing.expectEqualStrings("ello",  try evalString("SUBSTR('hello', 2, [Big])", &ctx));
    // 'Inf' coerces to 0 → length 0 → "".
    try testing.expectEqualStrings("", try evalString("LEFT('hello', [Inf])", &ctx));
    try testing.expectEqualStrings("", try evalString("RIGHT('hello', [Inf])", &ctx));
    // A genuinely out-of-range value still raises NotANumber.
    try testing.expectError(error.NotANumber, evalString("LEFT('hello', [Over])", &ctx));
    try testing.expectError(error.NotANumber, evalString("SUBSTR('hello', 2, [Over])", &ctx));
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

// UPPER/LOWER are full-Unicode codepoint walks (see unicode.zig), so accented
// and non-Latin letters case-map correctly instead of passing through.
test "eval: UPPER/LOWER are full-Unicode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    // Czech caron letters case-map both ways (Č↔č).
    try testing.expectEqualStrings("ČAU", try evalString("UPPER('Čau')", &ctx));
    try testing.expectEqualStrings("čau", try evalString("LOWER('ČaU')", &ctx));
    // German sharp s expands on upper-case (ß → SS).
    try testing.expectEqualStrings("STRASSE", try evalString("UPPER('straße')", &ctx));
    // Unicameral scripts pass through unchanged.
    try testing.expectEqualStrings("日本語", try evalString("UPPER('日本語')", &ctx));
}

test "eval: UNACCENT strips Latin diacritics" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("Creme brulee", try evalString("UNACCENT('Crème brûlée')", &ctx));
    try testing.expectEqualStrings("strasse", try evalString("UNACCENT('straße')", &ctx));
    try testing.expectEqualStrings("Zlutoucky kun", try evalString("UNACCENT('Žluťoučký kůň')", &ctx));
    // non-Latin keeps its script (no romanisation)
    try testing.expectEqualStrings("日本語", try evalString("UNACCENT('日本語')", &ctx));
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

test "eval: NTH_DOW DST boundaries + lenient empty on invalid" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    // EU DST window: last Sunday of March / October 2024.
    try testing.expectEqualStrings("2024-03-31", try evalString("NTH_DOW(2024, 3, 7, -1)", &ctx));
    try testing.expectEqualStrings("2024-10-27", try evalString("NTH_DOW(2024, 10, 7, -1)", &ctx));
    // nth-from-start + pre-1970.
    try testing.expectEqualStrings("2024-03-10", try evalString("NTH_DOW(2024, 3, 7, 2)", &ctx));
    try testing.expectEqualStrings("1924-03-30", try evalString("NTH_DOW(1924, 3, 7, -1)", &ctx));
    // Non-existent occurrence / out-of-range args → "" (data-lenient).
    try testing.expectEqualStrings("", try evalString("NTH_DOW(2023, 2, 7, 5)", &ctx));
    try testing.expectEqualStrings("", try evalString("NTH_DOW(2024, 13, 7, 1)", &ctx));
    // The full EU Europe/Prague offset idiom (DATEDIFF since string >= is unsupported).
    try testing.expectEqualStrings(
        "+02:00",
        try evalString("IF(DATEDIFF('2024-07-20', NTH_DOW(2024,3,7,-1)) >= 0 AND DATEDIFF('2024-07-20', NTH_DOW(2024,10,7,-1)) < 0, '+02:00', '+01:00')", &ctx),
    );
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
    // Extreme negative arithmetic crosses year 0 → a negative result year.
    // -3652500 is exactly -MAX_DATE_OFFSET_DAYS (in range, not silent-skipped),
    // so it reaches formatIsoDate with a negative year → InvalidDate, not UB.
    try testing.expectError(error.InvalidDate, eval("DATEADD('0001-06-15', -3652500)", &ctx));
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

test "FnDoc examples: every builtin has one that parses + evaluates" {

    // Guards example rot: a new builtin without an example fails here,

    // and any example that stops parsing/evaluating against a blank

    // Context is caught before it ships to the GUI doc panel.

    var helper = TestHelper.init(testing.allocator);

    defer helper.col_index.deinit();

    defer helper.ticker_map.deinit();



    for (builtins) |entry| {

        try testing.expect(entry.doc.example.len > 0);

        var arena = std.heap.ArenaAllocator.init(testing.allocator);

        defer arena.deinit();

        var ctx = helper.ctx(&[_][]const u8{}, arena.allocator());

        _ = evalString(entry.doc.example, &ctx) catch |err| {

            std.debug.print("example for {s} failed: {s} -> {}\n", .{ entry.name, entry.doc.example, err });

            return err;

        };

    }

}
