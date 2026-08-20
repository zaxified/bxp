//! Expression evaluator used to compute input_schema variable values.
//!
//! Expressions are evaluated against a single CSV row represented by a Context.
//! The evaluator is a single-pass recursive-descent parser that produces a Value
//! (string, fixed-point decimal, or boolean) without building an intermediate AST.
//! Numeric values use a fixed-point Decimal core (i128 @ scale 1e12) — see
//! the `decimal` module — so decimal money math is exact (`0.02 + 0.08 == 0.10`).
//!
//! Operator precedence (highest to lowest):
//!   unary -
//!   * /       (numeric multiply / divide)
//!   &         (string concatenation)
//!   + -       (numeric add / subtract)
//!   = != < > <= >=  (comparison; string equality only for = and !=)
//!   NOT       (boolean negation; binds looser than comparison, tighter than AND)
//!   AND
//!   OR
//!
//! Built-in functions:
//!   [ColumnName]              — field value by CSV header name
//!   FIELDS(n)                 — field value by 1-based column index
//!   'text'                    — string literal
//!   IF(cond, yes, no)         — short-circuit conditional
//!   ABS(f)                    — absolute numeric value
//!   NOW()                     — current UTC datetime as ISO 8601 string (YYYY-MM-DDTHH:MM:SSZ)
//!   TRIM(f)                   — strip leading and trailing whitespace from string
//!   ROUND(f, n)               — round f to n decimal places
//!   FLOOR(f)                  — round f down to nearest integer
//!   CEILING(f)                — round f up to nearest integer
//!   RAND(n)                   — string of n random digits (first 1–9, rest 0–9; n clamped 1–65)
//!   COALESCE(a, b, ...)       — first non-empty argument (empty = whitespace-only string)
//!   DATE_CONVERT(f, from, to) — reformat a date/time string; format tokens use datefmt syntax
//!   PRICE_VALUE(f)            — strip currency symbol/code, return numeric string
//!   PRICE_CURRENCY(f)         — extract currency code from a price string
//!   REMAP(s, 'name'|k,v,...)  — whole-value lookup through a `maps` entry / inline pairs
//!   LOOKUP([name,] key, field) — retrieve a value stored by a pre_pass table
//!
//! The list above is an illustrative sample, not the full set (~70 builtins).
//! The authoritative, complete catalog is the per-builtin `FnDoc` declarations
//! further down this file — search for the `── <NAME> ──` section headers.
const std = @import("std");
const datefmt = @import("datefmt");
const tz = @import("tz");
const unicode = @import("unicode.zig");
const encoding = @import("encoding");
const Decimal = @import("decimal").Decimal;
/// Arbitrary-precision sibling of `Decimal`, used by POWER / SQRT only. The
/// fixed-point core deliberately carries no `pow`/`sqrt`: an exact power grows
/// past i128 long before its exponent looks unreasonable, and a root is
/// irrational in the general case. Both are computed in this arbitrary-precision
/// form and rounded back into the 12-digit scale exactly once, so neither
/// builtin introduces a float — see the `decimal` module's own contract.
const BigDecimal = @import("decimal").BigDecimal;
// The regex module root file IS the Regex type (`const Regex = @This()`), so the
// import binds directly to the type — `Regex.compile`, `Regex.Match`, etc.
const Regex = @import("regex");

/// Re-export so callers that already import the `expr` module (bxp-cli pipeline,
/// the inspect core, bxp-mcp) can name the encoding type / helpers without a separate dependency.
pub const Encoding = encoding.Encoding;

/// `Decimal.fromInt` is fallible in the zig-libs numeric core (the local copy
/// wrapped silently). Every caller below feeds a small integer — a year, a
/// month, a string length, a record number — so the overflow arm is
/// unreachable in practice, but it is mapped onto bxp's own error name rather
/// than asserted: `unreachable` is undefined behaviour in the ReleaseSmall
/// builds we ship, and this keeps user-facing error text unchanged.
fn fromIntChecked(n: i128) !Decimal {
    return Decimal.fromInt(n) catch error.NumberOverflow;
}

// ---------------------------------------------------------------------------
// Value — the three types an expression can produce
// ---------------------------------------------------------------------------

pub const Value = union(enum) {
    string: []const u8,
    decimal: Decimal,
    boolean: bool,

    /// Returns the value as a string slice, allocated with alloc when needed.
    /// Decimals format their integer part, then up to 12 fractional digits
    /// with trailing zeros trimmed (no float formatter — see the `decimal` module).
    pub fn toString(self: Value, alloc: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .string => |s| s,
            .decimal => |d| blk: {
                var num_buf: [Decimal.str_buf_len]u8 = undefined;
                break :blk try alloc.dupe(u8, d.toString(&num_buf));
            },
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
            // `Decimal.parse` reports WHY it failed (the pre-migration `?Decimal`
            // could not): a well-formed magnitude that does not fit the i128
            // range is not junk, and the grouped-number fallback cannot rescue
            // it either, so it is reported as out-of-range instead of being
            // blamed for its shape. Both stay data errors, so IFERROR still
            // catches them (see isDataError).
            .string => |s| if (s.len == 0 or isNonFiniteToken(s)) Decimal.zero else
                Decimal.parse(s) catch |e| switch (e) {
                    error.Overflow => return error.NumberOutOfRange,
                    error.InvalidCharacter => parseGroupedNumber(s, ',', '.') orelse
                        return error.NotANumber,
                },
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

/// A single named map: ordered `key→value` pairs. `StringArrayHashMap`
/// preserves insertion (JSON) order — `REPLACE` applies pairs first-match-wins
/// in order — while still giving O(1) `get` for `REMAP`'s whole-value lookup.
pub const NamedMap = std.StringArrayHashMapUnmanaged([]const u8);
/// Registry of named maps (the `maps` config block; global + template-local
/// already merged into one per-template view).
pub const MapRegistry = std.StringHashMap(NamedMap);

pub const Context = struct {
    /// Field values for the current CSV row, in column order.
    fields: []const []const u8,
    /// Maps CSV column header names to 0-based column indices.
    col_index: *const std.StringHashMap(usize),
    /// Named `key→value` maps (`maps` config block, global + template-local
    /// merged) resolved by `REMAP` (whole-value) and `REPLACE` (substring).
    /// Null in bare/stateless eval contexts.
    maps: ?*const MapRegistry = null,
    /// Validate-mode whitelist of map names. Set non-null (the
    /// inspect.annotateRaw deep pass) so `REMAP`/`REPLACE` can flag a name
    /// referencing an undefined map at parse time instead of silently passing
    /// the value through. Runtime callers leave this null (silent passthrough
    /// on miss is intentional there), mirroring `pre_pass_names`.
    map_names: ?*const std.StringHashMap(void) = null,
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
    /// I/O implementation for the two builtins that need OS services in 0.16 —
    /// NOW() (wall clock via `std.Io.Timestamp`) and RAND() (CSPRNG entropy via
    /// `io.randomSecure`). 0.16 moved time + entropy behind the io interface.
    /// Defaults to `.failing`: contexts that never evaluate NOW()/RAND()
    /// (validate-only paths, most unit tests) can ignore it; the real eval entry
    /// points (bxp-cli pipeline, inspect, the NOW/RAND tests) set a real io.
    io: std.Io = .failing,
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
    /// Per-file source name behind `FILENAME()` — the input file stem with the
    /// directory and the matched `file_pattern_in` suffix removed. Row-invariant
    /// within a file but VARIES between files; the pipeline sets it once per
    /// file. Default "" (stateless inspect eval has no source file).
    filename: []const u8 = "",
    /// Per-file source sheet behind `SHEET_NAME()` — the configured
    /// `xlsx_sheet.name` for an xlsx-derived input, else "". Same per-file
    /// invariance caveat as `filename`.
    sheet_name: []const u8 = "",
    /// 1-based input record number of the current row behind `RECORD_NUM()`.
    /// Set per row by the pipeline; 0 when unknown (stateless inspect eval,
    /// or the pre_pass scan where no main-pass record counter exists).
    record_num: u64 = 0,

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
    /// Today populated by DATE_CONVERT args[1]/[2] and IS_DATE arg[1];
    /// carries the offending format text + 0-based offset of the bad
    /// character plus the absolute source span of the literal token.
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
            const d = Decimal.parse(first.text) catch {
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
        .map_name,
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

    // Reject any builtin flagged `row_varying` in the catalog: the
    // nondeterministic ones (NOW/RAND) and the per-row / per-file context
    // readers (FIELDS/RECORD_NUM/FILENAME/SHEET_NAME). None carries a `[Name]`
    // field_ref token for `staticReferences` to catch, so they must be rejected
    // here or they would be wrongly folded to a single value (folding a
    // per-file value once per template would freeze the first file's value —
    // see the evalFieldRef fast-path lesson). The reject set is the FnDoc
    // catalog (`row_varying`), so a new impure builtin can't drift out of sync.
    // Token-level check (not a substring scan) so a literal like 'KNOW' isn't
    // taken for NOW.
    var tok = Tokenizer.init(src);
    while (true) {
        const t = tok.next() catch return false;
        if (t.kind == .eof) break;
        if (t.kind != .ident) continue;
        if (isRowVaryingBuiltin(t.text)) return false;
    }
    return true;
}

/// True if `name` is a builtin the catalog flags `row_varying` — read live from
/// `builtins`, so the constant-folding reject set and the FnDoc catalog can
/// never diverge (replaces the former hand-maintained name list).
fn isRowVaryingBuiltin(name: []const u8) bool {
    inline for (builtins) |b| {
        if (b.doc.row_varying and std.ascii.eqlIgnoreCase(name, b.name)) return true;
    }
    return false;
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

/// Maximum (sub)expression nesting depth. Every `(...)`, function argument,
/// and IF/CASE/IFERROR branch re-enters `parseExpr`, and the tree-walking
/// parser recurses on the native stack — without a cap a deeply nested
/// expression overflows the stack into an uncatchable SIGSEGV (stack overflow
/// bypasses ReleaseSafe checks; reachable from the agent/GUI/CLI input surface
/// with untrusted expression text). 256 is far beyond any hand-written or
/// realistically generated config expression, while keeping the worst-case
/// frame count (~256 × the ~10-deep precedence chain) safely inside the thread
/// stack on every build mode.
const MAX_PARSE_DEPTH: u16 = 256;

const Parser = struct {
    tok: Tokenizer,
    ctx: *const Context,
    last_field_name: []const u8 = "",
    /// Current recursion depth, bounded by [MAX_PARSE_DEPTH]. Incremented on
    /// entry to `parseExpr` (the single re-entry point for every nested
    /// sub-expression) and decremented on return.
    depth: u16 = 0,

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
        // Buffer lives in this frame: `toString` returns a slice INTO it, so a
        // per-branch local would dangle the moment the switch expression ends.
        var num_buf: [Decimal.str_buf_len]u8 = undefined;
        const value_str: []const u8 = switch (value) {
            .decimal => |d| d.toString(&num_buf),
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

    /// Detail for a failed `toNumber` coercion. The error tells the two failure
    /// modes apart, so the detail has to follow it rather than always claiming
    /// "not a number": an out-of-range value IS a number, it just does not fit
    /// the i128 core. Pass the error straight from the `catch |err|` binding.
    fn setNumericDetail(self: *Parser, err: anyerror, s: []const u8) void {
        if (err != error.NumberOutOfRange) return self.setNotANumber(s);
        if (self.last_field_name.len > 0) {
            self.setDetail("number out of range: \"{s}\" (in [{s}])", .{ s, self.last_field_name });
        } else {
            self.setDetail("number out of range: \"{s}\"", .{s});
        }
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
        // Depth guard: every nested sub-expression (`(...)`, function arg,
        // IF/CASE/IFERROR branch) re-enters here, so a single counter here
        // bounds the native-stack recursion and turns a pathological nesting
        // into a normal template error instead of a SIGSEGV. See MAX_PARSE_DEPTH.
        if (self.depth >= MAX_PARSE_DEPTH) {
            self.setDetail("expression nested too deeply (max {d} levels)", .{MAX_PARSE_DEPTH});
            return error.ExpressionTooDeep;
        }
        self.depth += 1;
        defer self.depth -= 1;
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
                switch (left) { .string => |s| self.setNumericDetail(err, s), else => {} }
                return err;
            };
            const r = right.toNumber() catch |err| {
                switch (right) { .string => |s| self.setNumericDetail(err, s), else => {} }
                return err;
            };
            const res = if (t.kind == .plus) l.add(r) else l.sub(r);
            left = Value{ .decimal = res catch return error.NumberOverflow };
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
                switch (left) { .string => |s| self.setNumericDetail(err, s), else => {} }
                return err;
            };
            const r = right.toNumber() catch |err| {
                switch (right) { .string => |s| self.setNumericDetail(err, s), else => {} }
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
                } else |err| switch (err) {
                    // Blank divisor / zero → blank cell, per the note above.
                    error.DivisionByZero => left = Value{ .string = "" },
                    // Overflow is a real numeric failure, not a blank field, so
                    // it is loud like `*` is. The local Decimal returned plain
                    // `null` here and the caller could not tell the two apart —
                    // it `@intCast`-panicked on this path instead.
                    error.Overflow => return error.NumberOverflow,
                }
            } else {
                left = Value{ .decimal = l.mul(r) catch return error.NumberOverflow };
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
                switch (v) { .string => |s| self.setNumericDetail(err, s), else => {} }
                return err;
            };
            return Value{ .decimal = n.neg() catch return error.NumberOverflow };
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
            // The lexer accepts any run of digits and dots, so a typo like
            // `1.2.3` reaches here as a "syntactically valid" number token.
            // `Decimal.parse` tells that apart from a magnitude the i128 core
            // cannot hold, and the two get different names: blaming a typo on
            // range sends the template author looking in the wrong place.
            // MalformedNumber is deliberately NOT a data error (isDataError),
            // so IFERROR does not muffle a broken literal.
            .number_lit => return Value{ .decimal = Decimal.parse(t.text) catch |e| switch (e) {
                error.Overflow => return error.NumberOutOfRange,
                error.InvalidCharacter => {
                    self.setDetail("malformed number literal: \"{s}\"", .{t.text});
                    return error.MalformedNumber;
                },
            } },
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

    /// CASE(subject, m1, r1, m2, r2, …, default?) — lazy multi-branch mapping.
    /// Evaluates `subject` once, then walks the match/result pairs in order
    /// and returns the first result whose match equals `subject` (same
    /// equality as the `=` operator / IN — numeric when both parse as numbers,
    /// else byte-exact string). A lone trailing arg is the default returned
    /// when nothing matches; with no default an unmatched CASE returns "".
    /// Only the selected result expression is evaluated; the rest are skipped.
    /// The dispatcher has already consumed the opening '('.
    fn evalCase(self: *Parser) anyerror!Value {
        const subject = try self.parseExpr();
        if ((try self.tok.next()).kind != .comma) return error.ExpectedComma;
        var pairs: usize = 0;
        while (true) {
            const cand = try self.parseExpr();
            const after = try self.tok.peek();
            if (after.kind == .rparen) {
                _ = try self.tok.next(); // consume ')'
                // A lone trailing arg is the default. Require at least one
                // match/result pair so CASE(x, y) is a loud arity error rather
                // than a silent "always y".
                if (pairs == 0) return error.WrongArgCount;
                return cand;
            }
            if (after.kind != .comma) return error.ExpectedComma;
            _ = try self.tok.next(); // consume comma after the match value
            pairs += 1;
            if (try valuesEqual(subject, cand, self.ctx.alloc)) {
                const result = try self.parseExpr();
                // Drain the remaining unmatched pairs + optional default
                // without evaluating them.
                var t = try self.tok.peek();
                while (t.kind == .comma) {
                    _ = try self.tok.next();
                    try self.skipExpr();
                    t = try self.tok.peek();
                }
                if (t.kind != .rparen) return error.ExpectedRParen;
                _ = try self.tok.next();
                return result;
            }
            // No match: skip this pair's result unevaluated, then continue to
            // the next pair or the trailing default.
            try self.skipExpr();
            const t = try self.tok.peek();
            if (t.kind == .rparen) {
                _ = try self.tok.next();
                return Value{ .string = "" }; // pairs but no default, nothing matched
            }
            if (t.kind != .comma) return error.ExpectedComma;
            _ = try self.tok.next(); // consume comma, loop
        }
    }

    /// IFERROR(expr, fallback) — return `expr`'s value, or `fallback` when
    /// evaluating `expr` raises a DATA error (see `isDataError`: bad number,
    /// bad date, numeric overflow, unordered string compare). `fallback` is
    /// evaluated only on error. Template errors (unknown function, wrong arg
    /// count, syntax) propagate unchanged — IFERROR is a runtime safety net
    /// for messy data, not a way to silence template mistakes. The dispatcher
    /// has already consumed the opening '('.
    fn evalIferror(self: *Parser) anyerror!Value {
        // Snapshot the tokenizer so a data-error in `expr` can be rolled back
        // and the (syntactically valid) guarded expression skipped cleanly,
        // regardless of where mid-expression evaluation stopped.
        const saved = self.tok;
        if (self.parseExpr()) |val| {
            if ((try self.tok.next()).kind != .comma) return error.ExpectedComma;
            try self.skipExpr(); // fallback not needed
            if ((try self.tok.next()).kind != .rparen) return error.ExpectedRParen;
            return val;
        } else |err| {
            if (!isDataError(err)) return err;
            self.tok = saved;
            try self.skipExpr(); // skip the guarded expr unevaluated
            if ((try self.tok.next()).kind != .comma) return error.ExpectedComma;
            const fallback = try self.parseExpr();
            if ((try self.tok.next()).kind != .rparen) return error.ExpectedRParen;
            return fallback;
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

        // CASE / IFERROR: also lazy — they parse their own arg lists so only
        // the selected / non-erroring branch is evaluated (see if_doc note).
        if (std.ascii.eqlIgnoreCase(name, "CASE")) return self.evalCase();
        if (std.ascii.eqlIgnoreCase(name, "IFERROR")) return self.evalIferror();

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
                .expr, .string, .literal_string, .date_format, .pre_pass_name, .map_name => {},
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
                        args[i] = .{ .decimal = try fromIntChecked(clamped) };
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
    /// `expr.BadDateFormat` diagnostics for DATE_CONVERT arg[1]/arg[2]
    /// and IS_DATE arg[1].
    date_format,
    /// Bare string literal naming a pre_pass block. Drives autocomplete
    /// in bxp-gui (no static check today — runtime-resolved via
    /// Context.pre_pass_names; documented for catalog completeness).
    pre_pass_name,
    /// Bare string literal naming a `maps` entry (REMAP/REPLACE named form).
    /// Drives autocomplete; resolved at runtime via Context.maps, with the
    /// validate-mode Context.map_names whitelist flagging unknown names —
    /// mirrors `pre_pass_name`.
    map_name,
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

/// Editorial grouping of the builtins, used by the docs pipeline to split the
/// `expr-functions.md` reference into sections. Lives here (not in docs.zig)
/// because the category is a stable property of each function — it belongs next
/// to the builtin it classifies, single-sourced on its `FnDoc`. The section
/// titles + intros (pure presentation) stay in docs.zig's `fn_groups`.
pub const FnCategory = enum { logic, text, regex, lookup, number, date, source };

/// Context a builtin requires beyond its arguments — see `FnDoc.needs`.
///
/// The three non-`none` cases are deliberately distinct because a stateless
/// caller can satisfy them independently:
///   * `fields`  — needs the row's field values. `inspect.evalBatch` DOES
///                 supply these, so a caller that passes a row gets a real
///                 answer; one that passes none gets "".
///   * `source`  — needs the per-file source context (file name, sheet name,
///                 record position). No stateless entry point carries it, so
///                 these always answer ""/0 outside a real conversion — which
///                 is what each of their descriptions already states.
///   * `prepass` — needs a pre_pass table to have been built.
pub const FnNeeds = enum { none, fields, source, prepass };

pub const FnDoc = struct {
    name: []const u8,
    /// Reference-page grouping (see `FnCategory`). No default: every builtin
    /// must classify itself, so a new builtin is a compile error here until it
    /// declares a category — the drift guard that used to live in docs.zig.
    category: FnCategory,
    /// True when a call to this builtin makes the containing expression
    /// non-row-invariant, excluding it from constant folding: nondeterministic
    /// (NOW/RAND) or reads per-row / per-file source context
    /// (FIELDS/RECORD_NUM/FILENAME/SHEET_NAME). No default: every builtin must
    /// state its folding behaviour, so a new impure builtin cannot be silently
    /// constant-folded (the old hand-maintained reject list in `isRowInvariant`).
    /// LOOKUP is NOT flagged here — its non-invariance is detected structurally
    /// via its table reference in `staticReferences`, not this token scan.
    row_varying: bool,
    /// What the builtin needs from its surroundings beyond its own arguments.
    /// `.none` (the default, and the case for all but five builtins) means the
    /// call is self-contained and evaluates identically anywhere.
    ///
    /// Deliberately NOT derived from `row_varying`: that flag answers a
    /// different question (is the expression constant-foldable) and the two
    /// sets only overlap. NOW/RAND are row_varying but self-contained — they
    /// need no context, just a clock. LOOKUP is the mirror image: not
    /// row_varying at all, yet useless without a pre_pass table.
    ///
    /// Consumed by the generated reference page, whose scratchpad evaluates an
    /// example against no row at all: without this the five affected builtins
    /// would come back empty with nothing to explain why.
    needs: FnNeeds = .none,
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

/// Equality test shared by CASE — numeric when both sides parse as numbers,
/// otherwise byte-exact string compare. Mirrors the `=` operator and IN().
fn valuesEqual(a: Value, b: Value, alloc: std.mem.Allocator) !bool {
    const an = a.toNumber() catch null;
    const bn = b.toNumber() catch null;
    if (an != null and bn != null) return an.?.eql(bn.?);
    const as = try a.toString(alloc);
    const bs = try b.toString(alloc);
    return std.mem.eql(u8, as, bs);
}

/// True for the data-driven evaluation errors IFERROR catches — the ones a
/// messy CSV value (not a real number, malformed date, out-of-range magnitude)
/// can trigger. Structural / template errors (unknown function, wrong arg
/// count, syntax) and systemic OutOfMemory are deliberately NOT in this set so
/// they stay loud: IFERROR is a data safety net, not a template-error muffler.
fn isDataError(err: anyerror) bool {
    return switch (err) {
        error.NotANumber,
        error.InvalidDate,
        error.NumberOverflow,
        error.NumberOutOfRange,
        error.StringComparisonUnsupported,
        => true,
        else => false,
    };
}

/// IF — lazy/short-circuit. The dispatcher matches IF by name BEFORE reaching
/// the table loop and parses its own arg list via Parser; no adapter exists.
const if_doc: FnDoc = .{
    .name = "IF",
    .category = .logic,
    .row_varying = false,
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

/// CASE — lazy multi-branch. Like IF, the dispatcher matches it by name and it
/// parses its own arg list via `Parser.evalCase`; no adapter exists.
const case_doc: FnDoc = .{
    .name = "CASE",
    .category = .logic,
    .row_varying = false,
    .signature = "CASE(expr, m1, r1, …, default)",
    .example = "CASE('B', 'B', 'BUY', 'S', 'SELL', '?')",
    .description = "Multi-branch mapping. Compares `expr` against each `m`/`r` pair in order and returns the first matching `r`; returns the trailing `default` when nothing matches (or \"\" if no default is given). Equality matches the `=` operator (numeric when both sides parse as numbers, else byte-exact string). Only the selected result is evaluated. Collapses nested `IF(IF(IF(…)))` chains.",
    .args = &.{
        .{ .name = "expr" },
        .{ .name = "m1" },
        .{ .name = "r1" },
    },
    .min_args = 3,
    .max_args = 255,
};

/// IFERROR — lazy. Matched by name; parses its own args via `Parser.evalIferror`.
const iferror_doc: FnDoc = .{
    .name = "IFERROR",
    .category = .logic,
    .row_varying = false,
    .signature = "IFERROR(expr, fallback)",
    .example = "IFERROR(YEAR('not-a-date'), '')",
    .description = "Return `expr`'s value, or `fallback` if evaluating `expr` raises a data error (not-a-number, bad date, numeric overflow). `fallback` is evaluated only on error. Template errors — unknown function, wrong argument count, syntax — are NOT caught: IFERROR guards against messy data, not template mistakes.",
    .args = &.{
        .{ .name = "expr" },
        .{ .name = "fallback" },
    },
    .min_args = 2,
    .max_args = 2,
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

/// Parses a number in thousands-grouped format, generalised over both American
/// (`thousands=','`, `decimal='.'`) and European (`thousands='.'`,
/// `decimal=','`) conventions — `[-]?d{1,3}(<thousands>d{3})+(<decimal>d+)?`,
/// null when `s` does not match for the given separator pair.
///
/// The implementation lives in the zig-libs `numparse` module; it was
/// extracted from this file, so the code is the same scan, and it returns the
/// same `decimal` core wired in above. Three properties the call sites here
/// depend on, all upstream-documented:
///   * At least one thousands group is REQUIRED, so plain numbers ("123",
///     "1,5", "1.5") stay `Decimal.parse`'s job and this is only ever the
///     fallback.
///   * The strict structure (1–3 leading digits, exact 3-digit groups, no
///     trailing junk) is what keeps "2025,06,01" and American input read
///     under European separators from parsing as numbers.
///   * The `?Decimal` contract is deliberate: callers treat "not a number" as
///     a fallback condition, not an error to propagate, so the optional stops
///     at this boundary (see the `decimal` note in bxp-core/CLAUDE.md).
const parseGroupedNumber = @import("numparse").parseGroupedNumber;

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
    .category = .number,
    .row_varying = false,
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
    return Value{ .decimal = (try args[0].toNumber()).abs() catch return error.NumberOverflow };
}
fn adaptAbs(_: *Parser, args: []Value) anyerror!Value {
    return builtinAbs(args);
}

// ── FIELDS ──────────────────────────────────────────────────────────────
const fields_doc: FnDoc = .{
    .name = "FIELDS",
    .category = .source,
    .row_varying = true,
    .needs = .fields,
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
    .category = .number,
    .row_varying = false,
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
    .category = .number,
    .row_varying = false,
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

// ── REMAP ───────────────────────────────────────────────────────────────
const remap_doc: FnDoc = .{
    .name = "REMAP",
    .category = .lookup,
    .row_varying = false,
    .signature = "REMAP(s, 'name' | k, v, ...)",
    .example = "REMAP('VOW.DE', 'VOW.DE', 'VOW.DE.XETRA')",
    .description = "Whole-value lookup: if `s` exactly equals a map key, return that key's value, else return `s` unchanged. Named form REMAP(s, 'mapname') resolves a `maps` registry entry; inline form REMAP(s, k1,v1, k2,v2, ...) gives the pairs directly. The whole-value sibling of REPLACE (which matches substrings) — use it to remap symbols, codes or enum values.",
    .args = &.{
        .{ .name = "s", .kind = .string },
        .{ .name = "name", .kind = .map_name },
    },
    .min_args = 2,
    .max_args = 255,
};
/// REMAP(s, 'name' | k,v,...) — whole-value map lookup, passthrough on miss.
///   Named (2 args):  REMAP(s, 'mapname')  — resolve a `maps` registry entry.
///   Inline (odd ≥3): REMAP(s, k1,v1, ...) — first key equal to `s` wins.
/// Exact match of the entire `s` against a key (not substring — that is
/// REPLACE). Returns `s` unchanged when nothing matches.
fn builtinRemap(args: []Value, ctx: *const Context) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };

    // Named form: REMAP(s, 'mapname').
    if (args.len == 2) {
        const name = switch (args[1]) {
            .string => |v| v,
            else => return error.StringExpected,
        };
        const map = (try resolveNamedMap(ctx, name)) orelse return Value{ .string = s };
        return Value{ .string = map.get(s) orelse s };
    }

    // Inline pairs: REMAP(s, k1,v1, k2,v2, ...). String plus an even number of
    // pair operands ⇒ the total arg count must be odd.
    if (args.len % 2 == 0) return error.WrongArgCount;
    var k: usize = 1;
    while (k + 1 < args.len) : (k += 2) {
        const key = switch (args[k]) {
            .string => |v| v,
            else => return error.StringExpected,
        };
        if (std.mem.eql(u8, s, key)) {
            return switch (args[k + 1]) {
                .string => |v| Value{ .string = v },
                else => error.StringExpected,
            };
        }
    }
    return Value{ .string = s };
}
fn adaptRemap(p: *Parser, args: []Value) anyerror!Value {
    return builtinRemap(args, p.ctx);
}

// ── LOOKUP ──────────────────────────────────────────────────────────────
const lookup_doc: FnDoc = .{
    .name = "LOOKUP",
    .category = .lookup,
    .row_varying = false,
    .needs = .prepass,
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
    .category = .text,
    .row_varying = false,
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
    .category = .text,
    .row_varying = false,
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

// ── REGEX_MATCH / REGEX_EXTRACT ─────────────────────────────────────────
//
// Regex sits at the top of a deliberate cost hierarchy: O(1) hash lookup
// (IN/REMAP) < literal substring scan (CONTAINS/REPLACE) < regex engine. It is
// the extraction-only sibling for "pull a substring by pattern" jobs the cheaper
// tools cannot express — NOT a superset that replaces them.
//
// Backed by the Pike-VM engine (quangd/regex.zig, a pinned fetch dependency —
// see bxp-core/build.zig.zon): linear-time matching, so a pathological pattern
// degrades gracefully instead of
// exploding (ReDoS-proof by construction). The pattern is a template-authored
// literal — a compile failure is a loud template error (attributed to the
// pattern arg), while a non-matching *data* row is the lenient case ("" / false),
// matching the template-strict / data-lenient contract elsewhere in the engine.
//
// Unicode-scalar mode is on, so `.` and character-class ranges span whole code
// points. `\d`/`\w`/`\s` stay ASCII (upstream behaviour), so Czech-diacritic
// runs match via an explicit scalar class like `[A-ZÁ-Ž]`, not `\w` (`\p{...}`
// is upstream-PLANNED). The pattern compiles per call — consistent with the
// fused parse+eval engine that re-parses the whole expression each row; a
// compiled-pattern cache belongs to the deferred AST/IR work, not here.
const regex_opts: Regex.CompileOptions = .{ .syntax = .{ .unicode = true } };

/// Compile `pattern` or raise a loud, pattern-attributed template error.
fn compileRegex(p: *Parser, pattern: []const u8) anyerror!Regex {
    return Regex.compile(p.ctx.alloc, pattern, regex_opts) catch |err| {
        p.setDetail("invalid regex pattern \"{s}\": {s}", .{ pattern, @errorName(err) });
        return error.BadRegexPattern;
    };
}

const regex_match_doc: FnDoc = .{
    .name = "REGEX_MATCH",
    .category = .regex,
    .row_varying = false,
    .signature = "REGEX_MATCH(s, pattern)",
    .example = "REGEX_MATCH('AAPL US Equity', '[A-Z]+')",
    .description = "Returns \"true\" if regular-expression `pattern` matches anywhere in `s`, else \"false\". `pattern` is a regex literal: anchors `^ $`, classes `[...]`, quantifiers `* + ? {m,n}`, groups, and alternation `|` — linear-time (no backreferences or lookaround). Unicode-scalar mode is on, so `.` and class ranges span whole code points, but `\\d`/`\\w`/`\\s` stay ASCII — match accented letters with an explicit class like `[A-ZÁ-Ž]`. Pay for the cheapest tool that does the job: CONTAINS for a literal substring, IN/REMAP for whole-value sets, regex only for a real pattern.",
    .args = &.{
        .{ .name = "s", .kind = .string },
        .{ .name = "pattern", .kind = .string },
    },
    .min_args = 2,
    .max_args = 2,
};
/// REGEX_MATCH(s, pattern) → bool — true when `pattern` matches anywhere in `s`.
fn builtinRegexMatch(p: *Parser, args: []Value) anyerror!Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const pattern = switch (args[1]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    var re = try compileRegex(p, pattern);
    defer re.deinit();
    return Value{ .boolean = re.match(s) };
}

const regex_extract_doc: FnDoc = .{
    .name = "REGEX_EXTRACT",
    .category = .regex,
    .row_varying = false,
    .signature = "REGEX_EXTRACT(s, pattern)",
    .example = "REGEX_EXTRACT('Qualified Dividend AAPL 100', '[A-Z]{2,}')",
    .description = "Returns the first part of `s` that regular-expression `pattern` matches, or \"\" if there is no match. When `pattern` has a capture group `(...)`, the first group's text is returned; otherwise the whole match is returned — so group a repeated alternative as non-capturing `(?:...)` when you want the whole run, since a capturing group under a repeat yields only its last repetition. `pattern` is a regex literal (same syntax + Unicode notes as REGEX_MATCH): linear-time, no backreferences or lookaround, and accented letters need an explicit class like `[A-ZÁ-Ž]` (not `\\w`). Use it to pull a ticker, code, or token a literal REPLACE/SPLIT_PART cannot isolate.",
    .args = &.{
        .{ .name = "s", .kind = .string },
        .{ .name = "pattern", .kind = .string },
    },
    .min_args = 2,
    .max_args = 2,
};
/// REGEX_EXTRACT(s, pattern) → string — first capture group, else whole match,
/// else "" on no match. The returned slice points into `s` (no copy); `s` is the
/// caller's per-row arena value, so it outlives the call.
fn builtinRegexExtract(p: *Parser, args: []Value) anyerror!Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const pattern = switch (args[1]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    var re = try compileRegex(p, pattern);
    defer re.deinit();
    const caps = re.findCaptures(s) orelse return Value{ .string = "" };
    // Group 0 is the whole match; group 1 is the first user capture. Prefer the
    // capture when the pattern declares (and this match filled) one.
    const m: Regex.Match = blk: {
        if (caps.len() > 1) {
            if (caps.get(1)) |g| break :blk g;
        }
        break :blk caps.span();
    };
    return Value{ .string = m.bytes(s) };
}

// ── REPLACE ─────────────────────────────────────────────────────────────
const replace_doc: FnDoc = .{
    .name = "REPLACE",
    .category = .lookup,
    .row_varying = false,
    .signature = "REPLACE(s, 'name' | from, to, ...)",
    .example = "REPLACE('1 234,56', ' ', '', ',', '.')",
    .description = "Replace substrings in `s`. Named form REPLACE(s, 'mapname') applies a `maps` registry entry's pairs. Inline single-pair REPLACE(s, from, to) replaces every occurrence of `from` with `to` (case-sensitive byte match, so multi-byte UTF-8 needles work — this is substring replace, not char-by-char). Inline variadic REPLACE(s, from1, to1, from2, to2, ...) applies the pairs in one left-to-right pass: at each position the first pair (in declared order) whose `from` matches wins and the emitted `to` is not re-scanned, so one pass replaces several tokens at once without nesting. An empty `from` matches nothing. Whole-value sibling: REMAP.",
    .args = &.{
        .{ .name = "s", .kind = .string },
        .{ .name = "name", .kind = .map_name },
        .{ .name = "to", .kind = .string },
    },
    .min_args = 2,
    .max_args = 255,
};
/// REPLACE(s, from, to[, from2, to2, ...]) — substring replacement.
///
/// One pair: every non-overlapping, left-to-right occurrence of `from` becomes
/// `to` (a byte-substring match, so a multi-byte UTF-8 `from` is replaced as a
/// whole sequence — not SQL/Perl-style char translation). `from` empty returns
/// `s` unchanged.
///
/// Multiple pairs: applied in a single left-to-right scan. At each position the
/// first pair (in argument order) whose non-empty `from` matches wins; scanning
/// resumes after the emitted `to`, so a replacement's output is never re-matched
/// by a later pair. This is the one-allocation, one-pass alternative to nesting
/// REPLACE calls (which allocates and rescans per pair). Requires an odd arg
/// count (the string plus N from/to pairs).
fn builtinReplace(args: []Value, ctx: *const Context) !Value {
    const alloc = ctx.alloc;
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };

    // Named form: REPLACE(s, 'mapname') — apply the named map's ordered pairs
    // as substring replacements (same single-pass scan as the inline form).
    if (args.len == 2) {
        const name = switch (args[1]) {
            .string => |v| v,
            else => return error.StringExpected,
        };
        const map = (try resolveNamedMap(ctx, name)) orelse return Value{ .string = s };
        return Value{ .string = try replaceScan(alloc, s, map.keys(), map.values()) };
    }

    // Single-pair fast path — byte-identical to the historical impl, including
    // the "empty `from` returns `s` unchanged" contract and the std.mem jump
    // scan (faster than a per-byte loop for the common one-pair case).
    if (args.len == 3) {
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

    // Inline variadic form: REPLACE(s, from1, to1, from2, to2, ...). The string
    // plus an even number of pair operands ⇒ the total arg count must be odd.
    if (args.len % 2 == 0) return error.WrongArgCount;
    const npairs = (args.len - 1) / 2;
    // Heap the pair tables rather than a fixed stack array: max_args = 255 is
    // treated as unbounded by validateArgs, so the pair count is parser-limited,
    // not capped at a small constant.
    const froms = try alloc.alloc([]const u8, npairs);
    const tos = try alloc.alloc([]const u8, npairs);
    for (0..npairs) |k| {
        froms[k] = switch (args[1 + 2 * k]) {
            .string => |v| v,
            else => return error.StringExpected,
        };
        tos[k] = switch (args[2 + 2 * k]) {
            .string => |v| v,
            else => return error.StringExpected,
        };
    }
    return Value{ .string = try replaceScan(alloc, s, froms, tos) };
}
fn adaptReplace(p: *Parser, args: []Value) anyerror!Value {
    return builtinReplace(args, p.ctx);
}

/// Single left-to-right substring pass shared by REPLACE's inline and named
/// forms: at each position the first pair (declared order) whose non-empty
/// `from` matches wins; scanning resumes after the emitted `to`, so a
/// replacement's output is never re-matched. One allocation for the result.
fn replaceScan(
    alloc: std.mem.Allocator,
    s: []const u8,
    froms: []const []const u8,
    tos: []const []const u8,
) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    scan: while (i < s.len) {
        for (froms, tos) |from, to| {
            if (from.len > 0 and std.mem.startsWith(u8, s[i..], from)) {
                try out.appendSlice(alloc, to);
                i += from.len;
                continue :scan;
            }
        }
        try out.append(alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// Resolve a named `maps` entry for REMAP/REPLACE. In validate mode
/// (`ctx.map_names` set) an unknown name is a loud error so the GUI can flag a
/// typo / undefined map; at runtime an unknown name or absent registry yields
/// null and the caller passes the value through unchanged — the same silent-miss
/// contract `LOOKUP` uses via `ctx.pre_pass_names` / `ctx.lookup_table`.
fn resolveNamedMap(ctx: *const Context, name: []const u8) !?*const NamedMap {
    if (ctx.map_names) |names| {
        if (!names.contains(name)) {
            if (ctx.error_detail) |d| d.* = std.fmt.allocPrint(
                ctx.alloc,
                "unknown named map '{s}' — define it under the top-level `maps` registry or the template's `maps` block",
                .{name},
            ) catch "unknown named map";
            return error.MapUnknownName;
        }
    }
    const reg = ctx.maps orelse return null;
    return reg.getPtr(name);
}

// ── NOW ─────────────────────────────────────────────────────────────────
const now_doc: FnDoc = .{
    .name = "NOW",
    .category = .date,
    .row_varying = true,
    .signature = "NOW()",
    .example = "NOW()",
    .description = "Current UTC datetime as ISO 8601 string (YYYY-MM-DDTHH:MM:SSZ).",
    .args = &.{},
    .min_args = 0,
    .max_args = 0,
};
/// NOW() — current UTC datetime as ISO 8601 string: YYYY-MM-DDTHH:MM:SSZ.
fn builtinNow(args: []Value, alloc: std.mem.Allocator, io: std.Io) !Value {
    if (args.len != 0) return error.WrongArgCount;
    const epoch = std.time.epoch;
    const secs: u64 = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());
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
    return builtinNow(args, p.ctx.alloc, p.ctx.io);
}

// ── TRIM ────────────────────────────────────────────────────────────────
const trim_doc: FnDoc = .{
    .name = "TRIM",
    .category = .text,
    .row_varying = false,
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
    .category = .number,
    .row_varying = false,
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
    .category = .number,
    .row_varying = false,
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
    .category = .number,
    .row_varying = false,
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

// ── TRUNC ───────────────────────────────────────────────────────────────
/// Widest power of ten that still fits the fixed-point core's i128. 10^38 is
/// under the i128 ceiling (~1.7e38) and 10^39 is over it, so any truncation
/// unit past this is coarser than the largest representable value and the
/// answer is zero by construction — computed rather than attempted.
const TRUNC_MAX_UNIT_POW10: i32 = 38;
const trunc_doc: FnDoc = .{
    .name = "TRUNC",
    .category = .number,
    .row_varying = false,
    .signature = "TRUNC(x [, n])",
    .example = "TRUNC(-3.999, 2)",
    .description = "Cut `x` off after `n` decimal places (default 0) **toward zero**, discarding the rest rather than rounding it. This is what separates it from its neighbours, and only on negatives: `TRUNC(-3.999)` is `-3` where `FLOOR(-3.999)` is `-4`, and `TRUNC(-3.999, 2)` is `-3.99` where `ROUND(-3.999, 2)` is `-4`. Use it where a value must never grow in magnitude — a payout truncated to whole cents, a tax base that is never rounded up. `n<0` cuts at tens/hundreds (`n=-2` → multiples of 100, still toward zero); `n>=12` is a no-op (12 is the fixed-point scale); `n` is clamped to ±30.",
    .args = &.{
        .{ .name = "x", .kind = .number },
        .{ .name = "n", .kind = .{ .integer_in_range = .{
            .min = -@as(i64, ROUND_MAX_PRECISION),
            .max = @as(i64, ROUND_MAX_PRECISION),
        } } },
    },
    .min_args = 1,
    .max_args = 2,
};
/// TRUNC(x, n) — truncate toward zero at n decimal places.
///
/// Done on the raw fixed-point integer rather than through the decimal core's
/// rounding modes: `@divTrunc` already truncates toward zero for both signs,
/// which is exactly the contract, and multiplying the quotient back by the same
/// unit cannot overflow because the magnitude only ever shrinks.
fn builtinTrunc(args: []Value) !Value {
    const x = try args[0].toNumber();
    const n: i32 = if (args.len >= 2) blk: {
        // Defence-in-depth: `validateArgs` has already clamped a numeric n to
        // the integer_in_range domain, mirroring ROUND's own local re-clamp.
        const t = (try args[1].toNumber()).trunc();
        break :blk @intCast(@max(@min(t, @as(i128, ROUND_MAX_PRECISION)), -@as(i128, ROUND_MAX_PRECISION)));
    } else 0;

    const drop: i32 = @as(i32, @intCast(Decimal.scale)) - n;
    if (drop <= 0) return Value{ .decimal = x }; // finer than the scale: nothing to cut
    if (drop > TRUNC_MAX_UNIT_POW10) return Value{ .decimal = Decimal.zero };
    const unit = std.math.powi(i128, 10, @intCast(drop)) catch return Value{ .decimal = Decimal.zero };
    return Value{ .decimal = .{ .raw = @divTrunc(x.raw, unit) * unit } };
}
fn adaptTrunc(p: *Parser, args: []Value) anyerror!Value {
    return builtinTrunc(args) catch |err| {
        if (args.len >= 1) switch (args[0]) { .string => |s| p.setNotANumber(s), else => {} };
        return err;
    };
}

// ── POWER ───────────────────────────────────────────────────────────────
/// Largest exponent POWER will attempt. The exact result of `b^n` carries
/// `precision(b) × n` digits, so the exponent — not the base — is what decides
/// how much work a single cell costs. Any base of magnitude ≥ 2 leaves the
/// fixed-point range by n ≈ 88, so this bound only ever truncates work that was
/// going to overflow anyway; it exists to keep a typo'd `POWER([x], 1e9)` from
/// materialising a billion-digit intermediate before finding that out.
const POWER_MAX_EXPONENT: i128 = 1024;
const power_doc: FnDoc = .{
    .name = "POWER",
    .category = .number,
    .row_varying = false,
    .signature = "POWER(b, n)",
    .example = "POWER(1.05, 10)",
    .description = "`b` raised to the whole-number power `n`, computed exactly (`POWER(1.1, 2)` is `1.21`, not `1.2100000001`) and then rounded into the 12-digit fixed-point scale. `n` must be a whole number ≥ 0 and ≤ 1024 — a fractional or negative `n` returns \"\" rather than an approximation, because neither is exact on the decimal core (for a square root use SQRT; for a negative power divide: `1 / POWER(b, n)`). A result too large for the numeric range is a loud `NumberOverflow` that IFERROR can catch.",
    .args = &.{
        .{ .name = "b", .kind = .number },
        .{ .name = "n", .kind = .number },
    },
    .min_args = 2,
    .max_args = 2,
};
fn builtinPower(p: *Parser, args: []Value) !Value {
    const base = try args[0].toNumber();
    const exp = try args[1].toNumber();
    // Whole-number exponents only: compare the value against its own truncation
    // rather than inspecting digits, so `2.0` counts as whole and `2.5` does not.
    const n = exp.trunc();
    if ((try fromIntChecked(n)).raw != exp.raw) return Value{ .string = "" };
    if (n < 0 or n > POWER_MAX_EXPONENT) return Value{ .string = "" };

    const alloc = p.ctx.alloc;
    var b = try base.toBigDecimal(alloc);
    defer b.deinit();
    var r = BigDecimal.pow(alloc, b, @intCast(n)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // NegativeExponent is unreachable (guarded above); ResultTooLarge means
        // the exact answer does not fit the numeric range, which is the same
        // thing `*` reports when it overflows.
        else => return error.NumberOverflow,
    };
    defer r.deinit();
    return Value{ .decimal = Decimal.fromBigDecimal(alloc, r, .half_up) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NumberOverflow,
    } };
}
fn adaptPower(p: *Parser, args: []Value) anyerror!Value {
    return builtinPower(p, args) catch |err| {
        if (args.len >= 1) switch (args[0]) { .string => |s| p.setNotANumber(s), else => {} };
        return err;
    };
}

// ── SQRT ────────────────────────────────────────────────────────────────
/// Significant digits computed for a square root before it is rounded into the
/// fixed-point scale. The largest representable value is ~1.7e26, whose root
/// needs 14 integer digits; 12 fractional digits on top of that make 26 the
/// most any answer can use. The margin to 34 is what keeps the two roundings
/// (to `SQRT_PRECISION`, then to scale 12) from disagreeing: an inexact root
/// would have to sit within 1e-22 of a scale-12 tie to notice, and an exact
/// root is returned exactly by the module rather than rounded at all.
const SQRT_PRECISION: u32 = 34;
const sqrt_doc: FnDoc = .{
    .name = "SQRT",
    .category = .number,
    .row_varying = false,
    .signature = "SQRT(x)",
    .example = "SQRT(2)",
    .description = "Square root of `x`, correctly rounded to the 12-digit fixed-point scale (`SQRT(2)` = `1.414213562373`). Exact when the root is exact (`SQRT(6.25)` = `2.5`). A negative `x` returns \"\" — the root is undefined over the reals, and bxp has no imaginary type — so guard with `IF([x] < 0, …)` if a negative input is meaningful in your data.",
    .args = &.{.{ .name = "x", .kind = .number }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinSqrt(p: *Parser, args: []Value) !Value {
    const x = try args[0].toNumber();
    if (x.raw < 0) return Value{ .string = "" };
    if (x.isZero()) return Value{ .decimal = Decimal.zero };

    const alloc = p.ctx.alloc;
    var b = try x.toBigDecimal(alloc);
    defer b.deinit();
    var r = BigDecimal.sqrt(alloc, b, SQRT_PRECISION, .half_even) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // NegativeOperand / PrecisionTooLarge are both guarded above
        // (sign check, comptime precision), so this arm is defence in depth.
        else => return error.NumberOverflow,
    };
    defer r.deinit();
    return Value{ .decimal = Decimal.fromBigDecimal(alloc, r, .half_up) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NumberOverflow,
    } };
}
fn adaptSqrt(p: *Parser, args: []Value) anyerror!Value {
    return builtinSqrt(p, args) catch |err| {
        if (args.len >= 1) switch (args[0]) { .string => |s| p.setNotANumber(s), else => {} };
        return err;
    };
}

// ── RAND ────────────────────────────────────────────────────────────────
/// Upper bound on RAND(n) digit count. Matches MySQL's `DECIMAL(M,…)` max
/// precision (M ≤ 65) — the most widely-recognised "max digits" limit across
/// SQL engines. `n` is clamped to `[1, 65]` by the integer_in_range guard.
const RAND_MAX_DIGITS: i64 = 65;
const rand_doc: FnDoc = .{
    .name = "RAND",
    .category = .number,
    .row_varying = true,
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
    // 0.16 removed std.crypto.random; entropy now flows through the io
    // interface. Seed a CSPRNG from io.randomSecure so the per-digit draw
    // stays unbiased (intRangeLessThan), matching the previous behaviour.
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    try p.ctx.io.randomSecure(&seed);
    var csprng: std.Random.DefaultCsprng = .init(seed);
    const rng = csprng.random();
    buf[0] = '1' + rng.intRangeLessThan(u8, 0, 9); // 1..9
    for (buf[1..]) |*c| c.* = '0' + rng.intRangeLessThan(u8, 0, 10); // 0..9
    return Value{ .string = buf };
}

// ── COALESCE ────────────────────────────────────────────────────────────
const coalesce_doc: FnDoc = .{
    .name = "COALESCE",
    .category = .logic,
    .row_varying = false,
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
    .category = .date,
    .row_varying = false,
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
/// See the `datefmt` module for the full token list.
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
    .category = .text,
    .row_varying = false,
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
    .category = .text,
    .row_varying = false,
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
    .category = .text,
    .row_varying = false,
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
    .category = .text,
    .row_varying = false,
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
    .category = .text,
    .row_varying = false,
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
    .category = .text,
    .row_varying = false,
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
    .category = .text,
    .row_varying = false,
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
    .category = .text,
    .row_varying = false,
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
    .category = .logic,
    .row_varying = false,
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
    .category = .logic,
    .row_varying = false,
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
// The civil-date primitives live in the `datefmt` module (the single date
// core, consumed from zig-libs). Aliased here so the builtins below read
// unchanged; `datefmt` implements Howard Hinnant's `days_from_civil` /
// `civil_from_days` — branch-free O(1), exact across the i32 year range,
// negative (pre-1970) dates included.
// ---------------------------------------------------------------------------

const DateParts = datefmt.DateParts;
const ymdToEpochDay = datefmt.ymdToEpochDay;
const epochDayToYmd = datefmt.epochDayToYmd;
const isoWeekday = datefmt.isoWeekday;
const formatYmd = datefmt.formatIsoDate;

/// Parse arg[0] as a date or datetime and return its parts. On failure writes a
/// descriptive diagnostic via `setDetail` and returns InvalidDate so callers see
/// a clickable error in the validator / GUI. Empty input must be pre-handled by
/// the caller (return "" silently) — see DATE_CONVERT's rationale at
/// builtinDateConvert.
///
/// Every calendar builtin reads through here, which is what keeps the family
/// answering for one column: a timestamp column works with MONTH() exactly as it
/// works with HOUR(), and the date builtins simply ignore the time half. The
/// accepted shapes are `parseTzDatetime`'s — the same set the zone builtins take
/// and TO_UTC emits.
fn parseDatePartsArg(p: *Parser, s: []const u8) !DateParts {
    return parseTzDatetime(s) orelse {
        p.setDetail("invalid date '{s}': expected YYYY-MM-DD or YYYY-MM-DD hh:mm:ss", .{s});
        return error.InvalidDate;
    };
}

/// `parseDatePartsArg` reduced to an epoch day, for the builtins that do
/// calendar arithmetic rather than read a component.
fn parseDateArg(p: *Parser, s: []const u8) !i64 {
    const parts = try parseDatePartsArg(p, s);
    return ymdToEpochDay(parts.year, parts.month, parts.day);
}

// ── DATEADD ─────────────────────────────────────────────────────────────
const dateadd_doc: FnDoc = .{
    .name = "DATEADD",
    .category = .date,
    .row_varying = false,
    .signature = "DATEADD(d, n)",
    .example = "DATEADD('2024-01-31', 7)",
    .description = "Add `n` calendar days to date `d`. Negative `n` subtracts. Returns YYYY-MM-DD. For business-day arithmetic (skipping weekends) use WORKDAY().",
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
    .category = .date,
    .row_varying = false,
    .signature = "DATEDIFF(d1, d2)",
    .example = "DATEDIFF('2024-01-01', '2024-12-31')",
    .description = "Calendar days from `d2` to `d1`: positive when `d1` is later. A timestamp argument is read for its date; the time half is ignored.",
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
    return Value{ .decimal = try fromIntChecked(d1 - d2) };
}
fn adaptDateDiff(p: *Parser, args: []Value) anyerror!Value {
    return builtinDateDiff(p, args);
}

// ── WORKDAY ─────────────────────────────────────────────────────────────
const workday_doc: FnDoc = .{
    .name = "WORKDAY",
    .category = .date,
    .row_varying = false,
    .signature = "WORKDAY(d, n)",
    .example = "WORKDAY('2024-01-01', 10)",
    .description = "Add `n` business days to date `d`, skipping Saturdays and Sundays. Negative `n` subtracts, and `n = 0` returns `d` unchanged. Correct for T+2 settlement math; does NOT account for exchange holidays.",
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
    .category = .date,
    .row_varying = false,
    .signature = "YEAR(d)",
    .example = "YEAR('2024-03-15')",
    .description = "Year component of date `d` as a number.",
    .args = &.{.{ .name = "d", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinYear(p: *Parser, args: []Value) !Value {
    const s = switch (args[0]) { .string => |v| v, else => return error.StringExpected };
    if (s.len == 0) return Value{ .string = "" };
    const parts = try parseDatePartsArg(p, s);
    return Value{ .decimal = try fromIntChecked(parts.year) };
}
fn adaptYear(p: *Parser, args: []Value) anyerror!Value {
    return builtinYear(p, args);
}

// ── MONTH ───────────────────────────────────────────────────────────────
const month_doc: FnDoc = .{
    .name = "MONTH",
    .category = .date,
    .row_varying = false,
    .signature = "MONTH(d)",
    .example = "MONTH('2024-03-15')",
    .description = "Month component of date `d` as a number, 1-12.",
    .args = &.{.{ .name = "d", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinMonth(p: *Parser, args: []Value) !Value {
    const s = switch (args[0]) { .string => |v| v, else => return error.StringExpected };
    if (s.len == 0) return Value{ .string = "" };
    const parts = try parseDatePartsArg(p, s);
    return Value{ .decimal = try fromIntChecked(parts.month) };
}
fn adaptMonth(p: *Parser, args: []Value) anyerror!Value {
    return builtinMonth(p, args);
}

// ── DAY ─────────────────────────────────────────────────────────────────
const day_doc: FnDoc = .{
    .name = "DAY",
    .category = .date,
    .row_varying = false,
    .signature = "DAY(d)",
    .example = "DAY('2024-03-15')",
    .description = "Day-of-month component of date `d` as a number, 1-31.",
    .args = &.{.{ .name = "d", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinDay(p: *Parser, args: []Value) !Value {
    const s = switch (args[0]) { .string => |v| v, else => return error.StringExpected };
    if (s.len == 0) return Value{ .string = "" };
    const parts = try parseDatePartsArg(p, s);
    return Value{ .decimal = try fromIntChecked(parts.day) };
}
fn adaptDay(p: *Parser, args: []Value) anyerror!Value {
    return builtinDay(p, args);
}

// ── WEEKDAY ─────────────────────────────────────────────────────────────
const weekday_doc: FnDoc = .{
    .name = "WEEKDAY",
    .category = .date,
    .row_varying = false,
    .signature = "WEEKDAY(d)",
    .example = "WEEKDAY('2024-03-15')",
    .description = "ISO day-of-week for date `d`: Monday=1 … Sunday=7. Useful for weekend-trade detection: `WEEKDAY([Date]) > 5`.",
    .args = &.{.{ .name = "d", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinWeekday(p: *Parser, args: []Value) !Value {
    const s = switch (args[0]) { .string => |v| v, else => return error.StringExpected };
    if (s.len == 0) return Value{ .string = "" };
    const ep = try parseDateArg(p, s);
    return Value{ .decimal = try fromIntChecked(isoWeekday(ep)) };
}
fn adaptWeekday(p: *Parser, args: []Value) anyerror!Value {
    return builtinWeekday(p, args);
}

// ── QUARTER ─────────────────────────────────────────────────────────────
const quarter_doc: FnDoc = .{
    .name = "QUARTER",
    .category = .date,
    .row_varying = false,
    .signature = "QUARTER(d)",
    .example = "QUARTER('2024-08-15')",
    .description = "Calendar quarter of date `d` as a number, 1-4 (Jan-Mar = 1). Quarters are calendar-aligned; a fiscal year starting in another month needs its own arithmetic, e.g. an April start is `QUARTER(DATEADD([Date], -90))`.",
    .args = &.{.{ .name = "d", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinQuarter(p: *Parser, args: []Value) !Value {
    const s = switch (args[0]) { .string => |v| v, else => return error.StringExpected };
    if (s.len == 0) return Value{ .string = "" };
    const parts = try parseDatePartsArg(p, s);
    return Value{ .decimal = try fromIntChecked((parts.month + 2) / 3) };
}
fn adaptQuarter(p: *Parser, args: []Value) anyerror!Value {
    return builtinQuarter(p, args);
}

// ── WEEKNUM ─────────────────────────────────────────────────────────────
/// ISO 8601 week number for an epoch day, 1-53.
///
/// The rule is stated in terms of Thursdays, not Mondays: a week belongs to
/// whichever year contains its Thursday. Stepping to this week's Thursday first
/// therefore answers "which year's numbering am I in" and "how far into it" in
/// one move, and needs no special case for the turn of the year — which is why
/// the last days of December can legitimately come back as week 1, and the
/// first days of January as week 52 or 53.
///
/// Local rather than upstream in `datefmt`: the module offers `isoWeekday` but
/// no week number, and a week number without its ISO week-*year* is a bxp-level
/// convenience (the pairing that makes it sortable) rather than a date
/// primitive worth pushing upstream.
fn isoWeekNumber(ep: i64) u32 {
    const dow: i64 = @intCast(isoWeekday(ep));
    const thursday = ep + (4 - dow);
    const jan1 = ymdToEpochDay(epochDayToYmd(thursday).year, 1, 1);
    return @intCast(@divFloor(thursday - jan1, 7) + 1);
}
const weeknum_doc: FnDoc = .{
    .name = "WEEKNUM",
    .category = .date,
    .row_varying = false,
    .signature = "WEEKNUM(d)",
    .example = "WEEKNUM('2024-03-15')",
    .description = "ISO 8601 week number of date `d`, 1-53. Weeks start on Monday and week 1 is the one containing the first Thursday of the year, so the turn of the year crosses over: 2021-01-01 is week 53 (of 2020) and 2024-12-30 is week 1 (of 2025). The number alone is therefore not sortable across years — pair it with the week's own year, `YEAR(DATEADD([Date], 4 - WEEKDAY([Date])))`.",
    .args = &.{.{ .name = "d", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinWeeknum(p: *Parser, args: []Value) !Value {
    const s = switch (args[0]) { .string => |v| v, else => return error.StringExpected };
    if (s.len == 0) return Value{ .string = "" };
    const ep = try parseDateArg(p, s);
    return Value{ .decimal = try fromIntChecked(isoWeekNumber(ep)) };
}
fn adaptWeeknum(p: *Parser, args: []Value) anyerror!Value {
    return builtinWeeknum(p, args);
}

// ── HOUR / MINUTE / SECOND ──────────────────────────────────────────────
const hour_doc: FnDoc = .{
    .name = "HOUR",
    .category = .date,
    .row_varying = false,
    .signature = "HOUR(t)",
    .example = "HOUR('2024-03-15 14:23:01')",
    .description = "Hour of datetime `t` as a number, 0-23 on a 24-hour clock. A bare date reads as midnight, so a date-only column answers 0; any other layout has to go through DATE_CONVERT first.",
    .args = &.{.{ .name = "t", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinHour(p: *Parser, args: []Value) !Value {
    const s = switch (args[0]) { .string => |v| v, else => return error.StringExpected };
    if (s.len == 0) return Value{ .string = "" };
    return Value{ .decimal = try fromIntChecked((try parseDatePartsArg(p, s)).hour) };
}
fn adaptHour(p: *Parser, args: []Value) anyerror!Value {
    return builtinHour(p, args);
}

const minute_doc: FnDoc = .{
    .name = "MINUTE",
    .category = .date,
    .row_varying = false,
    .signature = "MINUTE(t)",
    .example = "MINUTE('2024-03-15 14:23:01')",
    .description = "Minute of datetime `t` as a number, 0-59.",
    .args = &.{.{ .name = "t", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinMinute(p: *Parser, args: []Value) !Value {
    const s = switch (args[0]) { .string => |v| v, else => return error.StringExpected };
    if (s.len == 0) return Value{ .string = "" };
    return Value{ .decimal = try fromIntChecked((try parseDatePartsArg(p, s)).minute) };
}
fn adaptMinute(p: *Parser, args: []Value) anyerror!Value {
    return builtinMinute(p, args);
}

const second_doc: FnDoc = .{
    .name = "SECOND",
    .category = .date,
    .row_varying = false,
    .signature = "SECOND(t)",
    .example = "SECOND('2024-03-15 14:23:01')",
    .description = "Second of datetime `t` as a number, 0-59.",
    .args = &.{.{ .name = "t", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinSecond(p: *Parser, args: []Value) !Value {
    const s = switch (args[0]) { .string => |v| v, else => return error.StringExpected };
    if (s.len == 0) return Value{ .string = "" };
    return Value{ .decimal = try fromIntChecked((try parseDatePartsArg(p, s)).second) };
}
fn adaptSecond(p: *Parser, args: []Value) anyerror!Value {
    return builtinSecond(p, args);
}

// ── EOMONTH ─────────────────────────────────────────────────────────────
const eomonth_doc: FnDoc = .{
    .name = "EOMONTH",
    .category = .date,
    .row_varying = false,
    .signature = "EOMONTH(d)",
    .example = "EOMONTH('2024-02-10')",
    .description = "Last calendar day of the month containing date `d`, as `YYYY-MM-DD`. Useful for snapping coupon/dividend dates and month-end reporting.",
    .args = &.{.{ .name = "d", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinEomonth(p: *Parser, args: []Value) !Value {
    const s = switch (args[0]) { .string => |v| v, else => return error.StringExpected };
    if (s.len == 0) return Value{ .string = "" };
    const parts = try parseDatePartsArg(p, s);
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
    .category = .date,
    .row_varying = false,
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

// ── IS_DATE ─────────────────────────────────────────────────────────────
const is_date_doc: FnDoc = .{
    .name = "IS_DATE",
    .category = .date,
    .row_varying = false,
    .signature = "IS_DATE(d [, format])",
    .example = "IS_DATE('31.12.2024', 'DD.MM.YYYY')",
    .description = "Whether `d` is a readable date: \"true\" or \"false\", never an error. With one argument it tests the shapes every date and time function reads, so it answers \"will they work on this row\". With a `format` it answers the same question for DATE_CONVERT, using the same tokens and the same tolerance for 4-letter month abbreviations. An empty value is \"false\", not an error, so a blank cell reads as \"no date\" rather than a bad one.",
    .args = &.{
        .{ .name = "d", .kind = .string },
        .{ .name = "format", .kind = .date_format },
    },
    .min_args = 1,
    .max_args = 2,
};
fn builtinIsDate(p: *Parser, args: []Value) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        // A number or boolean is not a date string; say so instead of erroring.
        else => return Value{ .boolean = false },
    };
    if (s.len == 0) return Value{ .boolean = false };
    if (args.len < 2) {
        return Value{ .boolean = parseTzDatetime(s) != null };
    }
    const fmt = switch (args[1]) { .string => |v| v, else => return error.StringExpected };
    // Mirror DATE_CONVERT's MMM pre-processing exactly: without it IS_DATE would
    // answer "false" for the 4-letter abbreviations ("Sept") that DATE_CONVERT
    // goes on to parse successfully, and the guard would reject its own input.
    const normalized = if (containsMMM(fmt)) try normalizeMonthAbbrev(s, p.ctx.alloc) else s;
    _ = datefmt.parse(normalized, fmt) catch return Value{ .boolean = false };
    return Value{ .boolean = true };
}
fn adaptIsDate(p: *Parser, args: []Value) anyerror!Value {
    return builtinIsDate(p, args);
}

// ── LEN ─────────────────────────────────────────────────────────────────
const len_doc: FnDoc = .{
    .name = "LEN",
    .category = .text,
    .row_varying = false,
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
    return Value{ .decimal = try fromIntChecked(@intCast(s.len)) };
}
fn adaptLen(_: *Parser, args: []Value) anyerror!Value {
    return builtinLen(args);
}

// ── GREATEST ────────────────────────────────────────────────────────────
const greatest_doc: FnDoc = .{
    .name = "GREATEST",
    .category = .number,
    .row_varying = false,
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
    .category = .number,
    .row_varying = false,
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
    if (Decimal.parse(s)) |_| return true else |_| {}
    return parseGroupedNumber(s, ',', '.') != null;
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
    const d = Decimal.parse(s) catch return s;
    // Scientific notation is the only form needing numeric expansion.
    if (std.mem.indexOfAny(u8, s, "eE")) |_| {
        var num_buf: [Decimal.str_buf_len]u8 = undefined;
        return alloc.dupe(u8, d.toString(&num_buf));
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

// DATE_CONVERT format-token catalog — re-exported live from `datefmt`, where
// it sits next to the parse/format vocabulary it documents (same pattern as the
// FnDoc/OperatorDoc catalogs). `docs.zig` flattens it into the docs JSON.
pub const DateTokenDoc = datefmt.DateTokenDoc;
pub const date_tokens = datefmt.date_tokens;

/// One operator-precedence level. Co-located with the parser's recursive-descent
/// chain (parseOr → parseAnd → parseNot → parseCompare → parseAdd → parseConcat
/// → parseMul → parseUnary); it documents that ordering for the docs JSON. The
/// canonical source is the module-header precedence table at the top of this
/// file — keep both in lockstep with the parser. `level` 1 = highest (binds
/// tightest), ascending = looser.
pub const PrecedenceDoc = struct {
    level: u8,
    operators: []const u8,
    description: []const u8,
};

pub const precedence = [_]PrecedenceDoc{
    .{ .level = 1, .operators = "unary -", .description = "Numeric negation (binds tightest)." },
    .{ .level = 2, .operators = "* /", .description = "Numeric multiply / divide." },
    .{ .level = 3, .operators = "&", .description = "String concatenation." },
    .{ .level = 4, .operators = "+ -", .description = "Numeric add / subtract." },
    .{ .level = 5, .operators = "= != < > <= >=", .description = "Comparison (string equality only for = and !=)." },
    .{ .level = 6, .operators = "NOT", .description = "Boolean negation (looser than comparison, tighter than AND)." },
    .{ .level = 7, .operators = "AND", .description = "Boolean conjunction." },
    .{ .level = 8, .operators = "OR", .description = "Boolean disjunction (binds loosest)." },
};

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
// ── FILENAME ────────────────────────────────────────────────────────────
const filename_doc: FnDoc = .{
    .name = "FILENAME",
    .category = .source,
    .row_varying = true,
    .needs = .source,
    .signature = "FILENAME()",
    .example = "FILENAME()",
    .description = "Input file stem — the file name with its directory and the matched `file_pattern_in` suffix removed (the same stem used for output naming). Exports often encode account, source or period in the name, so e.g. `SPLIT_PART(FILENAME(), '_', 3)` extracts a field from it. Empty during stateless evaluation (no source file).",
    .min_args = 0,
    .max_args = 0,
};
fn adaptFilename(p: *Parser, args: []Value) anyerror!Value {
    if (args.len != 0) return error.WrongArgCount;
    return Value{ .string = p.ctx.filename };
}

// ── RECORD_NUM ──────────────────────────────────────────────────────────
const record_num_doc: FnDoc = .{
    .name = "RECORD_NUM",
    .category = .source,
    .row_varying = true,
    .needs = .source,
    .signature = "RECORD_NUM()",
    .example = "RECORD_NUM()",
    .description = "1-based input record number of the current row within the file (the first data row is 1). Use it for synthetic IDs, dedup keys, or skip-first-N logic. 0 during stateless evaluation and inside the pre_pass scan.",
    .min_args = 0,
    .max_args = 0,
};
fn adaptRecordNum(p: *Parser, args: []Value) anyerror!Value {
    if (args.len != 0) return error.WrongArgCount;
    return Value{ .decimal = try fromIntChecked(@intCast(p.ctx.record_num)) };
}

// ── SHEET_NAME ──────────────────────────────────────────────────────────
const sheet_name_doc: FnDoc = .{
    .name = "SHEET_NAME",
    .category = .source,
    .row_varying = true,
    .needs = .source,
    .signature = "SHEET_NAME()",
    .example = "SHEET_NAME()",
    .description = "For xlsx-derived input, the configured `xlsx_sheet.name` the row came from; \"\" for native CSV/JSON input and during stateless evaluation.",
    .min_args = 0,
    .max_args = 0,
};
fn adaptSheetName(p: *Parser, args: []Value) anyerror!Value {
    if (args.len != 0) return error.WrongArgCount;
    return Value{ .string = p.ctx.sheet_name };
}

// ── LPAD ────────────────────────────────────────────────────────────────
/// Defensive cap on LPAD/RPAD target width — the width is normally an
/// author-written literal, but bound the allocation so a stray huge value
/// can't blow up memory. 64 KiB is far beyond any real fixed-width field.
const PAD_MAX_LEN: usize = 65535;
const lpad_doc: FnDoc = .{
    .name = "LPAD",
    .category = .text,
    .row_varying = false,
    .signature = "LPAD(s, len, pad)",
    .example = "LPAD('42', 5, '0')",
    .description = "Left-pad `s` with the `pad` string (repeated, then clipped) until it is `len` bytes long. If `s` is already `len` or longer it is truncated to the first `len` bytes; an empty `pad` returns `s` unchanged. `len` is clamped to [0, 65535]. Byte-based (UTF-8 byte count).",
    .args = &.{
        .{ .name = "s", .kind = .string },
        .{ .name = "len", .kind = .number },
        .{ .name = "pad", .kind = .string },
    },
    .min_args = 3,
    .max_args = 3,
};
fn builtinPad(args: []Value, alloc: std.mem.Allocator, comptime left: bool) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const pad = switch (args[2]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const len_t = (try args[1].toNumber()).trunc();
    const target: usize = if (len_t <= 0) 0 else if (len_t > PAD_MAX_LEN) PAD_MAX_LEN else @intCast(len_t);
    if (s.len >= target) return Value{ .string = s[0..target] };
    if (pad.len == 0) return Value{ .string = s }; // nothing to pad with
    const fill = target - s.len;
    const buf = try alloc.alloc(u8, target);
    // Fill region: repeat `pad` cyclically to cover `fill` bytes.
    const fill_start: usize = if (left) 0 else s.len;
    const body_start: usize = if (left) fill else 0;
    @memcpy(buf[body_start .. body_start + s.len], s);
    var i: usize = 0;
    while (i < fill) : (i += 1) buf[fill_start + i] = pad[i % pad.len];
    return Value{ .string = buf };
}
fn adaptLpad(p: *Parser, args: []Value) anyerror!Value {
    return builtinPad(args, p.ctx.alloc, true);
}

// ── RPAD ────────────────────────────────────────────────────────────────
const rpad_doc: FnDoc = .{
    .name = "RPAD",
    .category = .text,
    .row_varying = false,
    .signature = "RPAD(s, len, pad)",
    .example = "RPAD('42', 5, ' ')",
    .description = "Right-pad `s` with the `pad` string (repeated, then clipped) until it is `len` bytes long. If `s` is already `len` or longer it is truncated to the first `len` bytes; an empty `pad` returns `s` unchanged. `len` is clamped to [0, 65535]. Byte-based (UTF-8 byte count).",
    .args = &.{
        .{ .name = "s", .kind = .string },
        .{ .name = "len", .kind = .number },
        .{ .name = "pad", .kind = .string },
    },
    .min_args = 3,
    .max_args = 3,
};
fn adaptRpad(p: *Parser, args: []Value) anyerror!Value {
    return builtinPad(args, p.ctx.alloc, false);
}

// ── POSITION ────────────────────────────────────────────────────────────
const position_doc: FnDoc = .{
    .name = "POSITION",
    .category = .text,
    .row_varying = false,
    .signature = "POSITION(needle, haystack)",
    .example = "POSITION('Inc', 'Apple Inc')",
    .description = "1-based byte position of the first occurrence of `needle` inside `haystack`, or 0 when not found. An empty `needle` returns 1. Byte-based (UTF-8 byte offset), case-sensitive.",
    .args = &.{
        .{ .name = "needle", .kind = .string },
        .{ .name = "haystack", .kind = .string },
    },
    .min_args = 2,
    .max_args = 2,
};
fn builtinPosition(args: []Value) !Value {
    const needle = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const haystack = switch (args[1]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const idx = std.mem.indexOf(u8, haystack, needle) orelse return Value{ .decimal = Decimal.zero };
    return Value{ .decimal = try fromIntChecked(@intCast(idx + 1)) };
}
fn adaptPosition(_: *Parser, args: []Value) anyerror!Value {
    return builtinPosition(args);
}

// ── PROPER ──────────────────────────────────────────────────────────────
const proper_doc: FnDoc = .{
    .name = "PROPER",
    .category = .text,
    .row_varying = false,
    .signature = "PROPER(s)",
    .example = "PROPER('apple inc')",
    .description = "Title-case `s`: upper-case the first letter of every word and lower-case the rest (`apple inc` → `Apple Inc`, `o'brien` → `O'Brien`). Words break on any non-letter (spaces, digits, punctuation), like Excel PROPER. Full-Unicode via the same case tables as UPPER/LOWER; invalid UTF-8 passes through.",
    .args = &.{.{ .name = "s", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinProper(args: []Value, alloc: std.mem.Allocator) !Value {
    const s0 = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    // Lower-case the whole string first, then re-upper the first letter of
    // each word. Casing a single leading codepoint via toUpperStr handles
    // multi-byte expansion (e.g. ß → SS) and non-ASCII letters (über → Über).
    const lower = try unicode.toLowerStr(alloc, s0);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var at_word_start = true;
    var i: usize = 0;
    while (i < lower.len) {
        const b = lower[i];
        const cp_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
        const end = @min(i + cp_len, lower.len);
        const cp_bytes = lower[i..end];
        // Any non-ASCII byte is treated as a word letter; ASCII letters are
        // letters, ASCII digits / punctuation / spaces are word breaks.
        const is_letter = (b >= 0x80) or std.ascii.isAlphabetic(b);
        if (is_letter and at_word_start) {
            try out.appendSlice(alloc, try unicode.toUpperStr(alloc, cp_bytes));
        } else {
            try out.appendSlice(alloc, cp_bytes);
        }
        at_word_start = !is_letter;
        i = end;
    }
    return Value{ .string = try out.toOwnedSlice(alloc) };
}
fn adaptProper(p: *Parser, args: []Value) anyerror!Value {
    return builtinProper(args, p.ctx.alloc);
}

// ── MOD ─────────────────────────────────────────────────────────────────
const mod_doc: FnDoc = .{
    .name = "MOD",
    .category = .number,
    .row_varying = false,
    .signature = "MOD(a, b)",
    .example = "MOD(7, 3)",
    .description = "Remainder of `a` divided by `b`, with the sign of the dividend `a` (truncated division, like SQL/C `%`: `MOD(-7, 3) = -1`). `MOD(a, 0)` returns \"\" (mirrors the `/` operator's silent divide-by-zero). Exact over the fixed-point decimal core.",
    .args = &.{
        .{ .name = "a", .kind = .number },
        .{ .name = "b", .kind = .number },
    },
    .min_args = 2,
    .max_args = 2,
};
fn builtinMod(args: []Value) !Value {
    const a = try args[0].toNumber();
    const b = try args[1].toNumber();
    if (b.isZero()) return Value{ .string = "" };
    // Truncated remainder on the raw fixed-point integers: the SCALE factors
    // cancel in the quotient, so @divTrunc(a.raw, b.raw) is trunc(a/b), and
    // rem = a - b*trunc(a/b). Compute the product in i256 to avoid overflow;
    // |rem| < |b| so it always fits back into i128.
    const ar: i256 = a.raw;
    const br: i256 = b.raw;
    const k = @divTrunc(ar, br);
    const rem: i128 = @intCast(ar - br * k);
    return Value{ .decimal = .{ .raw = rem } };
}
fn adaptMod(p: *Parser, args: []Value) anyerror!Value {
    return builtinMod(args) catch |err| {
        if (args.len >= 1) switch (args[0]) { .string => |s| p.setNotANumber(s), else => {} };
        return err;
    };
}

// ── ISEMPTY ─────────────────────────────────────────────────────────────
const isempty_doc: FnDoc = .{
    .name = "ISEMPTY",
    .category = .logic,
    .row_varying = false,
    .signature = "ISEMPTY(x)",
    .example = "ISEMPTY('  ')",
    .description = "Return \"true\" when `x` is empty or whitespace-only, else \"false\". The safe emptiness test: a bare `x = ''` wrongly matches `'0'` (which coerces to empty in numeric context), whereas ISEMPTY checks the trimmed string length.",
    .args = &.{.{ .name = "x", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinIsEmpty(args: []Value) !Value {
    const s = switch (args[0]) {
        .string => |v| v,
        // Numbers and booleans are never empty (even 0 / false).
        else => return Value{ .boolean = false },
    };
    return Value{ .boolean = std.mem.trim(u8, s, " \t\r\n").len == 0 };
}
fn adaptIsEmpty(_: *Parser, args: []Value) anyerror!Value {
    return builtinIsEmpty(args);
}

// ── IS_NUMERIC ──────────────────────────────────────────────────────────
const is_numeric_doc: FnDoc = .{
    .name = "IS_NUMERIC",
    .category = .logic,
    .row_varying = false,
    .signature = "IS_NUMERIC(x)",
    .description = "Whether `x` holds a number: \"true\" or \"false\", never an error. Deliberately stricter than arithmetic, which treats an empty cell and the junk tokens `nan` / `inf` as zero so one bad export row cannot break a whole column — IS_NUMERIC calls all three \"false\", which is how you find those rows instead of silently summing them as 0. Thousands grouping is accepted (`1,234.56`), and a field read through `[Column]` has already had `csv_decimal_separator_in` applied, so European input is judged after normalisation, not before.",
    .example = "IS_NUMERIC('1,234.56')",
    .args = &.{.{ .name = "x", .kind = .string }},
    .min_args = 1,
    .max_args = 1,
};
fn builtinIsNumeric(args: []Value) !Value {
    const s = switch (args[0]) {
        .decimal => return Value{ .boolean = true },
        // A boolean coerces to 1/0 in arithmetic but is not itself a number,
        // and reporting it as one would make IS_NUMERIC(ISEMPTY(x)) nonsense.
        .boolean => return Value{ .boolean = false },
        .string => |v| v,
    };
    if (s.len == 0 or isNonFiniteToken(s)) return Value{ .boolean = false };
    if (Decimal.parse(s)) |_| return Value{ .boolean = true } else |_| {}
    return Value{ .boolean = parseGroupedNumber(s, ',', '.') != null };
}
fn adaptIsNumeric(_: *Parser, args: []Value) anyerror!Value {
    return builtinIsNumeric(args);
}

// ── TO_UTC / TZ_OFFSET / TZ_CONVERT / IS_DST ────────────────────────────
// Timezone builtins over the zig-libs `tz` module's IANA offset tables
// (pinned fetch dep — see build.zig.zon; the tables compile in, no runtime dep).
// Canonical output shape for the converting builtins.
const TZ_CANON_DT = "YYYY-MM-DD hh:mm:ss";

/// The one date/datetime reader every calendar and zone builtin shares:
/// canonical `YYYY-MM-DD hh:mm:ss`, the `T`-separated ISO variant, or a bare
/// `YYYY-MM-DD` (midnight). An ISO tail — fractional seconds, `Z`, `±HH:MM` —
/// is accepted and ignored, because the timestamps real exports carry it and
/// every consumer here reads wall-clock time. Null on failure.
///
/// **It matches the whole string.** `datefmt.parse` stops when its format runs
/// out and ignores whatever follows, which used to make `2024-03-15 nonsense`
/// read as midnight — a junk cell answering like a real one, the failure mode
/// the engine works hardest to avoid elsewhere. The tail is therefore checked
/// explicitly rather than left to the format's appetite.
///
/// The accepted tails are not arbitrary: `NOW()` emits `…THH:MM:SSZ`, so a
/// reader that took only the bare 19-character forms would refuse bxp's own
/// clock — `HOUR(NOW())` is a test.
fn parseTzDatetime(input: []const u8) ?datefmt.DateParts {
    // Bare date: the strict canonical reader, which range-checks month and day.
    if (input.len == 10) return datefmt.parseIsoDate(input) catch null;
    if (input.len < 19) return null;
    const sep = input[10];
    if (sep != ' ' and sep != 'T') return null;
    const fmt = if (sep == 'T') "YYYY-MM-DDThh:mm:ss" else "YYYY-MM-DD hh:mm:ss";
    const parts = datefmt.parse(input[0..19], fmt) catch return null;
    if (!datefmt.validate(parts)) return null;
    if (!isIsoDatetimeTail(input[19..])) return null;
    return parts;
}

/// Whether what follows `YYYY-MM-DDThh:mm:ss` is a recognised ISO tail rather
/// than leftover junk: nothing, fractional seconds, a zone designator
/// (`Z` / `±HH:MM`), or fractional seconds followed by one.
///
/// The offset is validated but discarded. Every builtin reading through here
/// treats its input as wall-clock time in a zone named by another argument;
/// honouring an embedded offset as well would silently double-apply it. The
/// builtin that does read an offset is `TO_UTC`, which takes an explicit format
/// with the `ZZ` token and never comes through this path.
fn isIsoDatetimeTail(tail: []const u8) bool {
    var rest = tail;
    if (rest.len > 0 and rest[0] == '.') {
        var i: usize = 1;
        while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
        if (i == 1) return false; // a decimal point with no digits behind it
        rest = rest[i..];
    }
    if (rest.len == 0) return true;
    if (rest.len == 1 and (rest[0] == 'Z' or rest[0] == 'z')) return true;
    if (rest.len == 6 and (rest[0] == '+' or rest[0] == '-') and rest[3] == ':') {
        return std.ascii.isDigit(rest[1]) and std.ascii.isDigit(rest[2]) and
            std.ascii.isDigit(rest[4]) and std.ascii.isDigit(rest[5]);
    }
    return false;
}

/// Resolve a zone arg — an IANA id or a fixed `±HH:MM` / `Z` / `UTC` offset —
/// to its UTC offset in seconds at `unix`. Null when unrecognised.
fn tzZoneOffsetSec(zone: []const u8, unix: i64) ?i32 {
    if (tz.find(zone)) |z| return tz.offsetAt(z, unix).off;
    const p = datefmt.parse(zone, "ZZ") catch return null; // fixed offset literal
    return (p.off_min orelse 0) * 60;
}

fn formatOffsetHHMM(alloc: std.mem.Allocator, off_sec: i32) ![]u8 {
    const sign: u8 = if (off_sec < 0) '-' else '+';
    const mag: u32 = @intCast(if (off_sec < 0) -off_sec else off_sec);
    const total_min = mag / 60;
    return std.fmt.allocPrint(alloc, "{c}{d:0>2}:{d:0>2}", .{ sign, total_min / 60, total_min % 60 });
}

const to_utc_doc: FnDoc = .{
    .name = "TO_UTC",
    .category = .date,
    .row_varying = false,
    .signature = "TO_UTC(ts, from)",
    .example = "TO_UTC('2024-03-15T14:23:01+02:00', 'YYYY-MM-DD[T]hh:mm:ssZZ')",
    .description = "Normalise an offset-bearing timestamp to UTC. `from` is a datefmt format including the `ZZ` offset token (`+HH:MM`/`-HH:MM`) or a literal `Z`; the parsed offset is subtracted, yielding `YYYY-MM-DD hh:mm:ss` in UTC. Needs no timezone database — the offset is read from the string itself.",
    .args = &.{
        .{ .name = "ts", .kind = .string },
        .{ .name = "from", .kind = .date_format },
    },
    .min_args = 2,
    .max_args = 2,
};
fn builtinToUtc(args: []Value, alloc: std.mem.Allocator) !Value {
    const input = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const from = switch (args[1]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    if (input.len == 0) return Value{ .string = "" };
    const parts = datefmt.parse(input, from) catch return Value{ .string = "" };
    const off_sec: i64 = @as(i64, parts.off_min orelse 0) * 60;
    const utc = datefmt.unixToParts(datefmt.partsToUnix(parts) - off_sec);
    return Value{ .string = try datefmt.format(alloc, utc, TZ_CANON_DT) };
}
fn adaptToUtc(p: *Parser, args: []Value) anyerror!Value {
    return builtinToUtc(args, p.ctx.alloc);
}

const tz_offset_doc: FnDoc = .{
    .name = "TZ_OFFSET",
    .category = .date,
    .row_varying = false,
    .signature = "TZ_OFFSET(datetime, zone)",
    .example = "TZ_OFFSET('2024-07-15 12:00:00', 'Europe/Prague')",
    .description = "UTC offset (`+HH:MM`/`-HH:MM`) of IANA `zone` at local wall-clock `datetime` (`YYYY-MM-DD[ hh:mm:ss]`), DST-aware. Append it to a naive local timestamp to make it ISO-8601 tz-aware. Unknown zone → \"\". Within the one-hour DST-transition window the input is read as local time, so the result can be off by the offset.",
    .args = &.{
        .{ .name = "datetime", .kind = .string },
        .{ .name = "zone", .kind = .string },
    },
    .min_args = 2,
    .max_args = 2,
};
fn builtinTzOffset(args: []Value, alloc: std.mem.Allocator) !Value {
    const dt = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const zone = switch (args[1]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const parts = parseTzDatetime(dt) orelse return Value{ .string = "" };
    const z = tz.find(zone) orelse return Value{ .string = "" };
    const off = tz.offsetAt(z, datefmt.partsToUnix(parts)).off;
    return Value{ .string = try formatOffsetHHMM(alloc, off) };
}
fn adaptTzOffset(p: *Parser, args: []Value) anyerror!Value {
    return builtinTzOffset(args, p.ctx.alloc);
}

const tz_convert_doc: FnDoc = .{
    .name = "TZ_CONVERT",
    .category = .date,
    .row_varying = false,
    .signature = "TZ_CONVERT(ts, from_zone, to_zone)",
    .example = "TZ_CONVERT('2024-07-15 12:00:00', 'America/New_York', 'Europe/Prague')",
    .description = "Convert wall-clock `ts` (`YYYY-MM-DD[ hh:mm:ss]`) from `from_zone` to `to_zone`, returning `YYYY-MM-DD hh:mm:ss`. Each zone is an IANA id (`Europe/Prague`), a fixed offset (`+02:00`), or `UTC`. Full DST-aware IANA conversion via the bundled tzdata. Unknown zone → \"\".",
    .args = &.{
        .{ .name = "ts", .kind = .string },
        .{ .name = "from_zone", .kind = .string },
        .{ .name = "to_zone", .kind = .string },
    },
    .min_args = 3,
    .max_args = 3,
};
fn builtinTzConvert(args: []Value, alloc: std.mem.Allocator) !Value {
    const dt = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const from_zone = switch (args[1]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const to_zone = switch (args[2]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const parts = parseTzDatetime(dt) orelse return Value{ .string = "" };
    const local_pseudo = datefmt.partsToUnix(parts);
    const from_off = tzZoneOffsetSec(from_zone, local_pseudo) orelse return Value{ .string = "" };
    const true_unix = local_pseudo - @as(i64, from_off);
    const to_off = tzZoneOffsetSec(to_zone, true_unix) orelse return Value{ .string = "" };
    const target = datefmt.unixToParts(true_unix + @as(i64, to_off));
    return Value{ .string = try datefmt.format(alloc, target, TZ_CANON_DT) };
}
fn adaptTzConvert(p: *Parser, args: []Value) anyerror!Value {
    return builtinTzConvert(args, p.ctx.alloc);
}

const is_dst_doc: FnDoc = .{
    .name = "IS_DST",
    .category = .date,
    .row_varying = false,
    .signature = "IS_DST(datetime, zone)",
    .example = "IS_DST('2024-07-15 12:00:00', 'Europe/Prague')",
    .description = "\"true\" when daylight-saving time is in effect in IANA `zone` at local wall-clock `datetime` (`YYYY-MM-DD[ hh:mm:ss]`), else \"false\". An unknown or fixed-offset zone → \"false\".",
    .args = &.{
        .{ .name = "datetime", .kind = .string },
        .{ .name = "zone", .kind = .string },
    },
    .min_args = 2,
    .max_args = 2,
};
fn builtinIsDst(args: []Value) !Value {
    const dt = switch (args[0]) {
        .string => |v| v,
        else => return Value{ .boolean = false },
    };
    const zone = switch (args[1]) {
        .string => |v| v,
        else => return Value{ .boolean = false },
    };
    const parts = parseTzDatetime(dt) orelse return Value{ .boolean = false };
    const z = tz.find(zone) orelse return Value{ .boolean = false };
    return Value{ .boolean = tz.offsetAt(z, datefmt.partsToUnix(parts)).dst };
}
fn adaptIsDst(_: *Parser, args: []Value) anyerror!Value {
    return builtinIsDst(args);
}

pub const builtins = [_]FnEntry{
    .{ .name = "IF",             .lazy = true, .doc = if_doc },
    .{ .name = "CASE",           .lazy = true, .doc = case_doc },
    .{ .name = "IFERROR",        .lazy = true, .doc = iferror_doc },
    .{ .name = "ABS",            .doc = abs_doc,            .impl = adaptAbs },
    .{ .name = "NOW",            .doc = now_doc,            .impl = adaptNow },
    .{ .name = "TRIM",           .doc = trim_doc,           .impl = adaptTrim },
    .{ .name = "ROUND",          .doc = round_doc,          .impl = adaptRound },
    .{ .name = "FLOOR",          .doc = floor_doc,          .impl = adaptFloor },
    .{ .name = "CEILING",        .doc = ceiling_doc,        .impl = adaptCeiling },
    .{ .name = "TRUNC",          .doc = trunc_doc,          .impl = adaptTrunc },
    .{ .name = "POWER",          .doc = power_doc,          .impl = adaptPower },
    .{ .name = "SQRT",           .doc = sqrt_doc,           .impl = adaptSqrt },
    .{ .name = "RAND",           .doc = rand_doc,           .impl = adaptRand },
    .{ .name = "COALESCE",       .doc = coalesce_doc,       .impl = adaptCoalesce },
    .{ .name = "DATE_CONVERT",   .doc = date_convert_doc,   .impl = adaptDateConvert },
    .{ .name = "TO_UTC",         .doc = to_utc_doc,         .impl = adaptToUtc },
    .{ .name = "TZ_OFFSET",      .doc = tz_offset_doc,      .impl = adaptTzOffset },
    .{ .name = "TZ_CONVERT",     .doc = tz_convert_doc,     .impl = adaptTzConvert },
    .{ .name = "IS_DST",         .doc = is_dst_doc,         .impl = adaptIsDst },
    .{ .name = "PRICE_VALUE",    .doc = price_value_doc,    .impl = adaptPriceValue },
    .{ .name = "PRICE_CURRENCY", .doc = price_currency_doc, .impl = adaptPriceCurrency },
    .{ .name = "REMAP",          .doc = remap_doc,          .impl = adaptRemap },
    .{ .name = "LOOKUP",         .doc = lookup_doc,         .impl = adaptLookup },
    .{ .name = "SPLIT_PART",     .doc = split_part_doc,     .impl = adaptSplitPart },
    .{ .name = "CONTAINS",       .doc = contains_doc,       .impl = adaptContains },
    .{ .name = "REGEX_MATCH",    .doc = regex_match_doc,    .impl = builtinRegexMatch },
    .{ .name = "REGEX_EXTRACT",  .doc = regex_extract_doc,  .impl = builtinRegexExtract },
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
    .{ .name = "QUARTER",        .doc = quarter_doc,        .impl = adaptQuarter },
    .{ .name = "WEEKNUM",        .doc = weeknum_doc,        .impl = adaptWeeknum },
    .{ .name = "HOUR",           .doc = hour_doc,           .impl = adaptHour },
    .{ .name = "MINUTE",         .doc = minute_doc,         .impl = adaptMinute },
    .{ .name = "SECOND",         .doc = second_doc,         .impl = adaptSecond },
    .{ .name = "EOMONTH",        .doc = eomonth_doc,        .impl = adaptEomonth },
    .{ .name = "NTH_DOW",        .doc = nth_dow_doc,        .impl = adaptNthDow },
    .{ .name = "IS_DATE",        .doc = is_date_doc,        .impl = adaptIsDate },
    .{ .name = "FILENAME",       .doc = filename_doc,       .impl = adaptFilename },
    .{ .name = "RECORD_NUM",     .doc = record_num_doc,     .impl = adaptRecordNum },
    .{ .name = "SHEET_NAME",     .doc = sheet_name_doc,     .impl = adaptSheetName },
    .{ .name = "LPAD",           .doc = lpad_doc,           .impl = adaptLpad },
    .{ .name = "RPAD",           .doc = rpad_doc,           .impl = adaptRpad },
    .{ .name = "POSITION",       .doc = position_doc,       .impl = adaptPosition },
    .{ .name = "PROPER",         .doc = proper_doc,         .impl = adaptProper },
    .{ .name = "MOD",            .doc = mod_doc,            .impl = adaptMod },
    .{ .name = "ISEMPTY",        .doc = isempty_doc,        .impl = adaptIsEmpty },
    .{ .name = "IS_NUMERIC",     .doc = is_numeric_doc,     .impl = adaptIsNumeric },
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

/// Minimal test fixture: col_index + `maps` registry kept alive for the test.
/// Use ctx() to build a Context pointing into this helper.
const TestHelper = struct {
    col_index: std.StringHashMap(usize),
    maps: MapRegistry,

    fn init(alloc: std.mem.Allocator) TestHelper {
        return .{
            .col_index = std.StringHashMap(usize).init(alloc),
            .maps = MapRegistry.init(alloc),
        };
    }

    fn ctx(self: *const TestHelper, fields: []const []const u8, alloc: std.mem.Allocator) Context {
        return .{
            .fields = fields,
            .col_index = &self.col_index,
            .maps = &self.maps,
            .lookup_table = null,
            .alloc = alloc,
            .io = testing.io,
        };
    }
};

// ------------------------------------------------------------
// Value methods
// ------------------------------------------------------------

/// Test helper: build a Value.decimal from a literal numeric string.
fn dec(s: []const u8) Value {
    return Value{ .decimal = Decimal.parse(s) catch unreachable };
}
/// Test helper: assert a toNumber() result equals the given literal.
fn expectNum(want: []const u8, v: Value) !void {
    try testing.expectEqual((try Decimal.parse(want)).raw, (try v.toNumber()).raw);
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

test "eval: TZ builtins (TO_UTC / TZ_OFFSET / TZ_CONVERT / IS_DST)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);

    // TO_UTC subtracts the parsed offset; a literal Z is a no-op.
    try testing.expectEqualStrings("2024-03-15 12:23:01", try evalString("TO_UTC('2024-03-15T14:23:01+02:00', 'YYYY-MM-DD[T]hh:mm:ssZZ')", &ctx));
    try testing.expectEqualStrings("2024-03-15 14:23:01", try evalString("TO_UTC('2024-03-15T14:23:01Z', 'YYYY-MM-DD[T]hh:mm:ssZZ')", &ctx));

    // TZ_OFFSET is DST-aware and handles half-hour zones.
    try testing.expectEqualStrings("+02:00", try evalString("TZ_OFFSET('2024-07-15 12:00:00', 'Europe/Prague')", &ctx));
    try testing.expectEqualStrings("+01:00", try evalString("TZ_OFFSET('2024-01-15 12:00:00', 'Europe/Prague')", &ctx));
    try testing.expectEqualStrings("+05:30", try evalString("TZ_OFFSET('2024-07-15 12:00:00', 'Asia/Kolkata')", &ctx));

    // TZ_CONVERT: NY 12:00 EDT → Prague 18:00 CEST; UTC → fixed offset.
    try testing.expectEqualStrings("2024-07-15 18:00:00", try evalString("TZ_CONVERT('2024-07-15 12:00:00', 'America/New_York', 'Europe/Prague')", &ctx));
    try testing.expectEqualStrings("2024-07-15 14:00:00", try evalString("TZ_CONVERT('2024-07-15 12:00:00', 'UTC', '+02:00')", &ctx));

    // IS_DST + unknown-zone leniency.
    try testing.expectEqualStrings("true", try evalString("IS_DST('2024-07-15 12:00:00', 'Europe/Prague')", &ctx));
    try testing.expectEqualStrings("false", try evalString("IS_DST('2024-01-15 12:00:00', 'Europe/Prague')", &ctx));
    try testing.expectEqualStrings("", try evalString("TZ_OFFSET('2024-07-15 12:00:00', 'Bogus/Zone')", &ctx));
}

test "eval: deeply nested expression errors instead of overflowing the stack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    var detail: []const u8 = "";
    var ctx = h.ctx(&.{}, a);
    ctx.error_detail = &detail;

    // 300 > MAX_PARSE_DEPTH (256): "((( … 1 … )))" must be rejected with a clean
    // error, never an uncatchable stack-overflow SIGSEGV. Regression guard for
    // the unbounded parser-recursion finding (audit 2026-06-14).
    const depth = 300;
    const src = try a.alloc(u8, depth * 2 + 1);
    @memset(src[0..depth], '(');
    src[depth] = '1';
    @memset(src[depth + 1 ..], ')');
    try testing.expectError(error.ExpressionTooDeep, eval(src, &ctx));

    // Nesting comfortably under the cap still evaluates normally.
    try testing.expectEqualStrings("1", try evalString("(((1)))", &ctx));
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
// REGEX_MATCH / REGEX_EXTRACT
// ------------------------------------------------------------

test "eval: REGEX_MATCH" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    // Basic ASCII match anywhere / no match.
    try testing.expectEqualStrings("true",  try evalString("REGEX_MATCH('AAPL US Equity', '[A-Z]+')", &ctx));
    try testing.expectEqualStrings("false", try evalString("REGEX_MATCH('lower case', '[0-9]')", &ctx));
    // Anchored full-string pattern (ISIN-ish shape).
    try testing.expectEqualStrings("true",  try evalString("REGEX_MATCH('US0378331005', '^[A-Z]{2}[A-Z0-9]{9}[0-9]$')", &ctx));
    try testing.expectEqualStrings("false", try evalString("REGEX_MATCH('US037833100', '^[A-Z]{2}[A-Z0-9]{9}[0-9]$')", &ctx));
}

test "eval: REGEX_EXTRACT whole match and capture group" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    // No capture group → whole match is returned (the first 2+ uppercase run).
    try testing.expectEqualStrings("AAPL", try evalString("REGEX_EXTRACT('Qualified Dividend AAPL 100', '[A-Z]{2,}')", &ctx));
    // Capture group present → the first group's text is returned, not the whole match.
    try testing.expectEqualStrings("42", try evalString("REGEX_EXTRACT('order id=42 qty=3', 'id=([0-9]+)')", &ctx));
    // No match → "" (the lenient data case).
    try testing.expectEqualStrings("", try evalString("REGEX_EXTRACT('no digits here', '[0-9]+')", &ctx));
}

test "eval: REGEX extracts Czech diacritics via explicit scalar class" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    // \w stays ASCII, but a Unicode-scalar class range covers Czech caps:
    // Č(U+010C) ∈ [Á(U+00C1)..Ž(U+017D)]. Empirically confirmed in the bake-off.
    try testing.expectEqualStrings("ČEZ", try evalString("REGEX_EXTRACT('Akcie ČEZ a.s. 100', '[A-ZÁ-Ž]{2,}')", &ctx));
    try testing.expectEqualStrings("true", try evalString("REGEX_MATCH('Škoda', '[A-ZÁ-Ž]')", &ctx));
}

test "eval: REGEX bad pattern is a loud template error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    // An unbalanced class is a template bug, not silent "" — it must propagate.
    try testing.expectError(error.BadRegexPattern, evalString("REGEX_EXTRACT('x', '[')", &ctx));
    try testing.expectError(error.BadRegexPattern, evalString("REGEX_MATCH('x', '(')", &ctx));
}

test "eval: REGEX is ReDoS-safe (linear-time engine, no catastrophic backtracking)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    // A classic catastrophic pattern on a long non-matching run: a backtracking
    // engine would blow up here. The Pike VM completes in linear time and simply
    // reports no match. The test passing at all (no hang) is the assertion.
    const n = 20_000;
    const buf = try a.alloc(u8, n);
    @memset(buf, 'a');
    buf[n - 1] = '!'; // breaks the trailing $ so the pattern cannot match
    const ctx = h.ctx(&.{buf}, a);
    try testing.expectEqualStrings("false", try evalString("REGEX_MATCH(FIELDS(1), '(a+)+$')", &ctx));
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

test "isRowInvariant: every row_varying builtin blocks folding (catalog-driven)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The reject set is the FnDoc catalog's `row_varying` flag. Assert that
    // every flagged builtin actually blocks folding — locks the catalog→scan
    // linkage so the old hand-list can't quietly creep back, and so a newly
    // flagged impure builtin is covered automatically. (The reverse direction —
    // unflagged builtins fold — is not asserted here because LOOKUP is a
    // deliberate exception: unflagged, yet blocked structurally via its table
    // reference, not this token scan.)
    inline for (builtins) |b| {
        if (!b.doc.row_varying) continue;
        const call = b.name ++ "()"; // bare ident is enough for the token scan
        try testing.expect(!isRowInvariant(call, a));
    }
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

// The `parseGroupedNumber` unit tests moved upstream with the function: the
// zig-libs `numparse` module carries both of them verbatim plus two more
// reject cases (>3 leading digits, trailing decimal separator with no digits).
// What stays bxp's job is the expr-level behaviour built on it — the numeric
// coercion fallback, GREATEST/LEAST attribution and `decimal_sep_in`
// normalisation — covered by the tests around this one and by the
// cross-runner corpus (scripts/test-06-expr-corpus.sh).

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
    // The precision clamp (ROUND_MAX_PRECISION) bounds the work regardless of
    // the requested precision; without it these calls would spin for tens of
    // seconds and this test would hang. 0.16 removed std.time.milliTimestamp
    // (timing is io-based now), so assert completion rather than wall time.
    _ = try eval("ROUND(1.0, 1000000000)", &ctx);
    _ = try eval("ROUND(1.0, -1000000000)", &ctx);
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

test "eval: REPLACE single pair (substring, all occurrences)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("A-B-C", try evalString("REPLACE('A.B.C', '.', '-')", &ctx));
    // Multi-byte UTF-8 needle replaced as a whole sequence, not char-by-char.
    try testing.expectEqualStrings("cafe", try evalString("REPLACE('café', 'é', 'e')", &ctx));
    // Empty `from` returns the string unchanged.
    try testing.expectEqualStrings("abc", try evalString("REPLACE('abc', '', 'X')", &ctx));
}

test "eval: REPLACE variadic pairs (one left-to-right pass)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    // Thousands-separator idiom: strip spaces, comma → dot.
    try testing.expectEqualStrings("1234.56", try evalString("REPLACE('1 234,56', ' ', '', ',', '.')", &ctx));
    // First matching pair in declared order wins; its output is not re-scanned
    // (a→b, then b→2 leaves the produced 'b' alone: 'aXb' → 'bX2').
    try testing.expectEqualStrings("bX2", try evalString("REPLACE('aXb', 'a', 'b', 'b', '2')", &ctx));
    // An empty `from` pair is a no-op and never stalls the scan.
    try testing.expectEqualStrings("xy", try evalString("REPLACE('xy', '', 'Z', 'q', 'Q')", &ctx));
    // Even arg count (incomplete pair) is a wrong-arity error.
    try testing.expectError(error.WrongArgCount, evalString("REPLACE('x', 'a', 'b', 'c')", &ctx));
}

test "eval: REMAP named + inline whole-value lookup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    var syms: NamedMap = .empty;
    try syms.put(a, "VOW.DE", "VOW.DE.XETRA");
    try syms.put(a, "BTC", "BTC-USD");
    try h.maps.put("syms", syms);
    const ctx = h.ctx(&.{}, a);
    // Named: exact whole-value hit.
    try testing.expectEqualStrings("VOW.DE.XETRA", try evalString("REMAP('VOW.DE', 'syms')", &ctx));
    // Named: miss → passthrough unchanged.
    try testing.expectEqualStrings("AAPL", try evalString("REMAP('AAPL', 'syms')", &ctx));
    // Named: unknown map name at runtime (map_names null) → passthrough, no error.
    try testing.expectEqualStrings("VOW.DE", try evalString("REMAP('VOW.DE', 'nope')", &ctx));
    // Inline pairs: first exact key wins.
    try testing.expectEqualStrings("X", try evalString("REMAP('a', 'a', 'X', 'b', 'Y')", &ctx));
    // Whole-value, not substring: 'ab' does not match key 'a'.
    try testing.expectEqualStrings("ab", try evalString("REMAP('ab', 'a', 'X')", &ctx));
    // Even arg count (incomplete pair) errors.
    try testing.expectError(error.WrongArgCount, evalString("REMAP('a', 'a', 'X', 'b')", &ctx));
}

test "eval: REPLACE named map applies ordered substring pairs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    var num: NamedMap = .empty;
    try num.put(a, " ", ""); // ordered: strip spaces first,
    try num.put(a, ",", "."); // then comma → dot
    try h.maps.put("num", num);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("1234.56", try evalString("REPLACE('1 234,56', 'num')", &ctx));
    // Unknown name at runtime → passthrough.
    try testing.expectEqualStrings("1 234,56", try evalString("REPLACE('1 234,56', 'nope')", &ctx));
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

test "eval: QUARTER buckets months, WEEKNUM follows the ISO Thursday rule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("1", try evalString("QUARTER('2024-01-01')", &ctx));
    try testing.expectEqualStrings("1", try evalString("QUARTER('2024-03-31')", &ctx));
    try testing.expectEqualStrings("2", try evalString("QUARTER('2024-04-01')", &ctx));
    try testing.expectEqualStrings("4", try evalString("QUARTER('2024-12-31')", &ctx));

    // 2024-01-01 was a Monday, so it opens week 1 of its own year.
    try testing.expectEqualStrings("1", try evalString("WEEKNUM('2024-01-01')", &ctx));
    try testing.expectEqualStrings("11", try evalString("WEEKNUM('2024-03-15')", &ctx));
    // The year boundary is where the Thursday rule earns its keep — these three
    // are exactly the cases a naive "days since Jan 1 / 7" would get wrong.
    // 2021-01-01 (Friday) belongs to the last week of 2020, which had 53.
    try testing.expectEqualStrings("53", try evalString("WEEKNUM('2021-01-01')", &ctx));
    // 2023-01-01 (Sunday) closes 2022's week 52.
    try testing.expectEqualStrings("52", try evalString("WEEKNUM('2023-01-01')", &ctx));
    // …and 2024-12-30 (Monday) already opens 2025's week 1.
    try testing.expectEqualStrings("1", try evalString("WEEKNUM('2024-12-30')", &ctx));
}

test "eval: one reader for the whole family — a timestamp column answers everywhere" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    // The asymmetry this closed: the time functions took a timestamp and the
    // date functions did not, so one column could not be read by both.
    try testing.expectEqualStrings("14", try evalString("HOUR('2024-03-15 14:23:01')", &ctx));
    try testing.expectEqualStrings("3",  try evalString("MONTH('2024-03-15 14:23:01')", &ctx));
    try testing.expectEqualStrings("2024", try evalString("YEAR('2024-03-15T14:23:01')", &ctx));
    try testing.expectEqualStrings("1",  try evalString("QUARTER('2024-03-15 14:23:01')", &ctx));
    try testing.expectEqualStrings("5",  try evalString("WEEKDAY('2024-03-15 14:23:01')", &ctx));
    try testing.expectEqualStrings("11", try evalString("WEEKNUM('2024-03-15 14:23:01')", &ctx));
    // Calendar arithmetic reads the date half and returns a date.
    try testing.expectEqualStrings("2024-03-22", try evalString("DATEADD('2024-03-15 14:23:01', 7)", &ctx));
    try testing.expectEqualStrings("2024-03-31", try evalString("EOMONTH('2024-03-15T14:23:01')", &ctx));
    try testing.expectEqualStrings("1", try evalString("DATEDIFF('2024-03-15 23:00:00', '2024-03-14 01:00:00')", &ctx));
    // …and IS_DATE answers for that same set, or it would be lying about it.
    try testing.expectEqualStrings("true", try evalString("IS_DATE('2024-03-15 14:23:01')", &ctx));

    // NOW() emits a trailing Z, so bxp's own clock has to be readable — this is
    // the case that rules out a plain "ten or nineteen characters" test.
    try testing.expectEqualStrings("2026", try evalString("LEFT(NOW(), 4)", &ctx));
    _ = try evalString("HOUR(NOW())", &ctx);
    _ = try evalString("YEAR(NOW())", &ctx);
    // The rest of the ISO tail: fractional seconds, a zone designator, both.
    try testing.expectEqualStrings("14", try evalString("HOUR('2024-03-15T14:23:01Z')", &ctx));
    try testing.expectEqualStrings("14", try evalString("HOUR('2024-03-15T14:23:01.123')", &ctx));
    try testing.expectEqualStrings("14", try evalString("HOUR('2024-03-15T14:23:01.123456Z')", &ctx));
    try testing.expectEqualStrings("14", try evalString("HOUR('2024-03-15T14:23:01+02:00')", &ctx));
    try testing.expectEqualStrings("3",  try evalString("MONTH('2024-03-15 14:23:01.5-05:00')", &ctx));
}

test "eval: the date reader matches the whole string, so junk cannot read as midnight" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    // Before this, `datefmt.parse` stopped when its format ran out and ignored
    // the rest, so all of these answered as if they were midnight on a real day.
    try testing.expectError(error.InvalidDate, eval("HOUR('2024-03-15 nonsense')", &ctx));
    try testing.expectError(error.InvalidDate, eval("MONTH('2024-03-15 nonsense')", &ctx));
    try testing.expectError(error.InvalidDate, eval("HOUR('2024-03-15T14:23:01 and more')", &ctx));
    try testing.expectError(error.InvalidDate, eval("HOUR('2024-03-15T14:23:01.')", &ctx));
    try testing.expectError(error.InvalidDate, eval("HOUR('2024-03-15T14:23:01+2:00')", &ctx));
    try testing.expectError(error.InvalidDate, eval("HOUR('2024-03-15X14:23:01')", &ctx));
    // Field ranges are checked on the time half too, not only the date.
    try testing.expectError(error.InvalidDate, eval("HOUR('2024-03-15 25:00:00')", &ctx));
    try testing.expectError(error.InvalidDate, eval("MONTH('2024-13-15 10:00:00')", &ctx));
    // IS_DATE reports the same verdict without raising.
    try testing.expectEqualStrings("false", try evalString("IS_DATE('2024-03-15 nonsense')", &ctx));
    // The zone builtins share the reader; their contract is "" rather than loud.
    try testing.expectEqualStrings("", try evalString("TZ_OFFSET('2024-03-15 nonsense', 'Europe/Prague')", &ctx));
    try testing.expectEqualStrings("+01:00", try evalString("TZ_OFFSET('2024-03-15 10:00:00', 'Europe/Prague')", &ctx));
}

test "eval: HOUR / MINUTE / SECOND read the time half of a datetime" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("14", try evalString("HOUR('2024-03-15 14:23:01')", &ctx));
    try testing.expectEqualStrings("23", try evalString("MINUTE('2024-03-15 14:23:01')", &ctx));
    try testing.expectEqualStrings("1",  try evalString("SECOND('2024-03-15 14:23:01')", &ctx));
    // The `T` separator is the same canonical set the TZ builtins accept.
    try testing.expectEqualStrings("14", try evalString("HOUR('2024-03-15T14:23:01')", &ctx));
    // A date-only column reads as midnight rather than erroring.
    try testing.expectEqualStrings("0", try evalString("HOUR('2024-03-15')", &ctx));
    // Empty stays empty (the blank-field contract), malformed is loud.
    try testing.expectEqualStrings("", try evalString("HOUR('')", &ctx));
    try testing.expectError(error.InvalidDate, eval("HOUR('15.03.2024 14:23')", &ctx));
    // …and what TO_UTC emits is what these consume — the round trip closes.
    try testing.expectEqualStrings("12", try evalString(
        "HOUR(TO_UTC('2024-03-15T14:23:01+02:00', 'YYYY-MM-DD[T]hh:mm:ssZZ'))", &ctx));
}

test "eval: IS_NUMERIC is stricter than arithmetic coercion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("true",  try evalString("IS_NUMERIC('1234')", &ctx));
    try testing.expectEqualStrings("true",  try evalString("IS_NUMERIC('-3.5')", &ctx));
    try testing.expectEqualStrings("true",  try evalString("IS_NUMERIC('1,234.56')", &ctx));
    try testing.expectEqualStrings("true",  try evalString("IS_NUMERIC(1 + 1)", &ctx));
    try testing.expectEqualStrings("false", try evalString("IS_NUMERIC('abc')", &ctx));
    // The whole point: arithmetic reads these three as 0 so one bad row cannot
    // break a column, which is exactly why you need a way to find them.
    try testing.expectEqualStrings("0", try evalString("'' + 0", &ctx));
    try testing.expectEqualStrings("0", try evalString("'nan' + 0", &ctx));
    try testing.expectEqualStrings("false", try evalString("IS_NUMERIC('')", &ctx));
    try testing.expectEqualStrings("false", try evalString("IS_NUMERIC('nan')", &ctx));
    try testing.expectEqualStrings("false", try evalString("IS_NUMERIC('-inf')", &ctx));
    // A boolean is not a number, even though it coerces to 1/0 in arithmetic.
    try testing.expectEqualStrings("false", try evalString("IS_NUMERIC(ISEMPTY('x'))", &ctx));
}

test "eval: IS_DATE answers for the canonical form and for a given format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("true",  try evalString("IS_DATE('2024-03-15')", &ctx));
    try testing.expectEqualStrings("false", try evalString("IS_DATE('2024-13-15')", &ctx));
    try testing.expectEqualStrings("false", try evalString("IS_DATE('15.03.2024')", &ctx));
    try testing.expectEqualStrings("true",  try evalString("IS_DATE('15.03.2024', 'DD.MM.YYYY')", &ctx));
    try testing.expectEqualStrings("false", try evalString("IS_DATE('not a date', 'DD.MM.YYYY')", &ctx));
    // Blank is "no date", not a bad one, and never an error.
    try testing.expectEqualStrings("false", try evalString("IS_DATE('')", &ctx));
    // It must agree with DATE_CONVERT, including the 4-letter month abbreviation
    // DATE_CONVERT normalises before parsing.
    try testing.expectEqualStrings("true",  try evalString("IS_DATE('Sept-03-2024', 'MMM-DD-YYYY')", &ctx));
    try testing.expectEqualStrings("2024-09-03", try evalString(
        "DATE_CONVERT('Sept-03-2024', 'MMM-DD-YYYY', 'YYYY-MM-DD')", &ctx));
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

    defer helper.maps.deinit();



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

// ── Tests: context builtins (FILENAME / RECORD_NUM / SHEET_NAME) ─────────

test "FILENAME / RECORD_NUM / SHEET_NAME: read per-file/row context" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    var ctx = h.ctx(&.{}, a);
    ctx.filename = "XTB_12345_2024-01_2024-12";
    ctx.record_num = 7;
    ctx.sheet_name = "CASH OPERATION";
    try testing.expectEqualStrings("XTB_12345_2024-01_2024-12", try evalString("FILENAME()", &ctx));
    try testing.expectEqualStrings("7", try evalString("RECORD_NUM()", &ctx));
    try testing.expectEqualStrings("CASH OPERATION", try evalString("SHEET_NAME()", &ctx));
    // Composes with string/date builtins, the headline FILENAME() use-case.
    try testing.expectEqualStrings("2024-01", try evalString("SPLIT_PART(FILENAME(), '_', 3)", &ctx));
    // Defaults (stateless eval) — empty stem / sheet, record 0.
    const ctx0 = h.ctx(&.{}, a);
    try testing.expectEqualStrings("", try evalString("FILENAME()", &ctx0));
    try testing.expectEqualStrings("0", try evalString("RECORD_NUM()", &ctx0));
    try testing.expectEqualStrings("", try evalString("SHEET_NAME()", &ctx0));
    // Arity: extra args are a loud error (0-arg context family).
    try testing.expectError(error.WrongArgCount, eval("FILENAME('x')", &ctx));
}

// ── Tests: CASE ──────────────────────────────────────────────────────────

test "CASE: matches a pair, falls back to default, lazy-skips others" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    // First matching pair wins.
    try testing.expectEqualStrings("BUY", try evalString("CASE('B', 'B', 'BUY', 'S', 'SELL', '?')", &ctx));
    try testing.expectEqualStrings("SELL", try evalString("CASE('S', 'B', 'BUY', 'S', 'SELL', '?')", &ctx));
    // No match → trailing default.
    try testing.expectEqualStrings("?", try evalString("CASE('X', 'B', 'BUY', 'S', 'SELL', '?')", &ctx));
    // No match, no default → "".
    try testing.expectEqualStrings("", try evalString("CASE('X', 'B', 'BUY')", &ctx));
    // Numeric equality (subject/ matches coerce like the `=` operator).
    try testing.expectEqualStrings("one", try evalString("CASE(1, 1, 'one', 2, 'two', 'other')", &ctx));
    // Laziness: a non-selected arm that would error is never evaluated.
    try testing.expectEqualStrings("ok", try evalString("CASE('a', 'a', 'ok', 'b', YEAR('bad'), 'def')", &ctx));
    // Arity: a subject + single arg (no pair) is a loud error, not silent passthrough.
    try testing.expectError(error.WrongArgCount, eval("CASE('x', 'y')", &ctx));
}

// ── Tests: IFERROR ───────────────────────────────────────────────────────

test "IFERROR: catches data errors, passes through template errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    try h.col_index.put("n", 0);
    const ctx = h.ctx(&.{"abc"}, a);
    // Data error (bad date) → fallback; fallback evaluated only on error.
    try testing.expectEqualStrings("", try evalString("IFERROR(YEAR('not-a-date'), '')", &ctx));
    // Bad number in arithmetic → fallback.
    try testing.expectEqualStrings("0", try evalString("IFERROR([n] * 2, '0')", &ctx));
    // No error → the guarded value, fallback ignored.
    try testing.expectEqualStrings("3", try evalString("IFERROR(1 + 2, '0')", &ctx));
    // Template error (unknown function) stays loud — NOT swallowed.
    try testing.expectError(error.UnknownFunction, eval("IFERROR(NOSUCHFN(1), '0')", &ctx));
}

// ── Tests: LPAD / RPAD ───────────────────────────────────────────────────

test "LPAD / RPAD: pad, truncate, empty-pad, clamp" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("00042", try evalString("LPAD('42', 5, '0')", &ctx));
    try testing.expectEqualStrings("42   ", try evalString("RPAD('42', 5, ' ')", &ctx));
    // Cyclic multi-char pad.
    try testing.expectEqualStrings("abab1", try evalString("LPAD('1', 5, 'ab')", &ctx));
    // Already long enough → truncated to len.
    try testing.expectEqualStrings("ab", try evalString("LPAD('abcdef', 2, '0')", &ctx));
    // Empty pad → unchanged.
    try testing.expectEqualStrings("42", try evalString("LPAD('42', 5, '')", &ctx));
    // Non-positive len → "".
    try testing.expectEqualStrings("", try evalString("RPAD('42', 0, '0')", &ctx));
}

// ── Tests: POSITION ──────────────────────────────────────────────────────

test "POSITION: 1-based index, 0 when missing, empty needle = 1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("7", try evalString("POSITION('Inc', 'Apple Inc')", &ctx));
    try testing.expectEqualStrings("1", try evalString("POSITION('Ap', 'Apple')", &ctx));
    try testing.expectEqualStrings("0", try evalString("POSITION('zz', 'Apple')", &ctx));
    try testing.expectEqualStrings("1", try evalString("POSITION('', 'Apple')", &ctx));
}

// ── Tests: PROPER ────────────────────────────────────────────────────────

test "PROPER: title-case across word breaks and Unicode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("Apple Inc", try evalString("PROPER('apple inc')", &ctx));
    try testing.expectEqualStrings("Apple Inc", try evalString("PROPER('APPLE INC')", &ctx));
    // Words break on any non-letter (hyphen here; spaces/digits below).
    try testing.expectEqualStrings("Mary-Jane", try evalString("PROPER('mary-jane')", &ctx));
    // Digits break words (Excel-style).
    try testing.expectEqualStrings("Abc123Def", try evalString("PROPER('abc123def')", &ctx));
    // Non-ASCII letter at a word start is upper-cased.
    try testing.expectEqualStrings("Über Café", try evalString("PROPER('über café')", &ctx));
}

// ── Tests: MOD ───────────────────────────────────────────────────────────

test "TRUNC: cuts toward zero, which is where it parts ways with FLOOR/ROUND" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    // Positives agree with FLOOR — the whole distinction lives on the negatives.
    try testing.expectEqualStrings("3", try evalString("TRUNC(3.999)", &ctx));
    try testing.expectEqualStrings("3", try evalString("FLOOR(3.999)", &ctx));
    try testing.expectEqualStrings("-3", try evalString("TRUNC(-3.999)", &ctx));
    try testing.expectEqualStrings("-4", try evalString("FLOOR(-3.999)", &ctx));

    // …and against ROUND at a precision, which is the case that had no clean
    // spelling before: -3.999 must become -3.99, never -4.
    try testing.expectEqualStrings("3.99",  try evalString("TRUNC(3.999, 2)", &ctx));
    try testing.expectEqualStrings("-3.99", try evalString("TRUNC(-3.999, 2)", &ctx));
    try testing.expectEqualStrings("-4",    try evalString("ROUND(-3.999, 2)", &ctx));

    // Negative n cuts at tens/hundreds, still toward zero.
    try testing.expectEqualStrings("1200",  try evalString("TRUNC(1234.5, -2)", &ctx));
    try testing.expectEqualStrings("-1200", try evalString("TRUNC(-1234.5, -2)", &ctx));

    // Past the fixed-point scale there is nothing left to cut…
    try testing.expectEqualStrings("1.23456789012", try evalString("TRUNC(1.23456789012, 12)", &ctx));
    try testing.expectEqualStrings("1.23456789012", try evalString("TRUNC(1.23456789012, 30)", &ctx));
    // …and a unit coarser than the numeric range can only produce zero.
    try testing.expectEqualStrings("0", try evalString("TRUNC(1234.5, -30)", &ctx));
    // Zero and exact values are unmoved.
    try testing.expectEqualStrings("0", try evalString("TRUNC(0, 4)", &ctx));
    try testing.expectEqualStrings("-5", try evalString("TRUNC(-5, 2)", &ctx));
}

test "POWER: exact whole powers, empty on what is not exact, loud on overflow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    // The Java/BigDecimal contract: no digit is discarded, so 1.1^2 is 1.21 —
    // the answer a float core cannot give without a visible tail.
    try testing.expectEqualStrings("1.21", try evalString("POWER(1.1, 2)", &ctx));
    try testing.expectEqualStrings("1024", try evalString("POWER(2, 10)", &ctx));
    try testing.expectEqualStrings("1", try evalString("POWER(7, 0)", &ctx));
    try testing.expectEqualStrings("-8", try evalString("POWER(-2, 3)", &ctx));
    // Compound growth to ten periods, rounded once into the fixed-point scale.
    try testing.expectEqualStrings("1.628894626777", try evalString("POWER(1.05, 10)", &ctx));
    // Neither of these is exact on a decimal core, so neither is guessed at.
    try testing.expectEqualStrings("", try evalString("POWER(2, 0.5)", &ctx));
    try testing.expectEqualStrings("", try evalString("POWER(2, -1)", &ctx));
    // …but the documented workarounds are.
    try testing.expectEqualStrings("1.414213562373", try evalString("SQRT(2)", &ctx));
    try testing.expectEqualStrings("0.5", try evalString("1 / POWER(2, 1)", &ctx));
    // Past the numeric range it is a data error, so IFERROR can catch it.
    try testing.expectError(error.NumberOverflow, eval("POWER(10, 30)", &ctx));
    try testing.expectEqualStrings("n/a", try evalString("IFERROR(POWER(10, 30), 'n/a')", &ctx));
    // A runaway exponent is refused before anything is materialised.
    try testing.expectEqualStrings("", try evalString("POWER(2, 100000)", &ctx));
}

test "SQRT: correctly rounded, exact when the root is exact, empty on negative" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("1.414213562373", try evalString("SQRT(2)", &ctx));
    try testing.expectEqualStrings("2.5", try evalString("SQRT(6.25)", &ctx));
    try testing.expectEqualStrings("1000", try evalString("SQRT(1000000)", &ctx));
    try testing.expectEqualStrings("0", try evalString("SQRT(0)", &ctx));
    // Undefined over the reals — "" rather than an invented answer.
    try testing.expectEqualStrings("", try evalString("SQRT(-1)", &ctx));
    // Round-trips through POWER for a perfect square.
    try testing.expectEqualStrings("144", try evalString("POWER(SQRT(144), 2)", &ctx));
}

test "MOD: truncated remainder, sign of dividend, div-by-zero" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("1", try evalString("MOD(7, 3)", &ctx));
    try testing.expectEqualStrings("-1", try evalString("MOD(-7, 3)", &ctx));
    try testing.expectEqualStrings("1", try evalString("MOD(7, -3)", &ctx));
    try testing.expectEqualStrings("0", try evalString("MOD(6, 3)", &ctx));
    // Fractional operands.
    try testing.expectEqualStrings("0.5", try evalString("MOD(2.5, 1)", &ctx));
    // Divide by zero → "" (mirrors the `/` operator).
    try testing.expectEqualStrings("", try evalString("MOD(7, 0)", &ctx));
}

// ── Tests: ISEMPTY ───────────────────────────────────────────────────────

test "ISEMPTY: empty / whitespace true, '0' is not empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    const ctx = h.ctx(&.{}, a);
    try testing.expectEqualStrings("true", try evalString("ISEMPTY('')", &ctx));
    try testing.expectEqualStrings("true", try evalString("ISEMPTY('   ')", &ctx));
    try testing.expectEqualStrings("false", try evalString("ISEMPTY('x')", &ctx));
    // The footgun ISEMPTY retires: '0' is NOT empty (a bare `= ''` would match it).
    try testing.expectEqualStrings("false", try evalString("ISEMPTY('0')", &ctx));
}

// ── Tests: numeric parse failure names ───────────────────────────────────

test "numeric errors: out-of-range vs malformed, data vs template" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = TestHelper.init(a);
    try h.col_index.put("big", 0);
    const ctx = h.ctx(&.{"999999999999999999999999999999"}, a);

    // A field value that IS a number but exceeds the i128 core: blame the
    // magnitude, not the shape. `Decimal.parse`'s typed error is what makes
    // the distinction available — the former `?Decimal` could not.
    try testing.expectError(error.NumberOutOfRange, eval("[big] + 1", &ctx));
    // A value that is not a number at all keeps the original name.
    try testing.expectError(error.NotANumber, eval("'abc' + 1", &ctx));
    // Same split for a literal written into the template.
    try testing.expectError(error.NumberOutOfRange, eval("999999999999999999999999999999 + 1", &ctx));
    try testing.expectError(error.MalformedNumber, eval("1.2.3 + 1", &ctx));
    // Out-of-range is a data error, so IFERROR catches it; a malformed literal
    // is a template error and stays loud.
    try testing.expectEqualStrings("0", try evalString("IFERROR([big] + 1, '0')", &ctx));
    try testing.expectError(error.MalformedNumber, eval("IFERROR(1.2.3 + 1, '0')", &ctx));
}
