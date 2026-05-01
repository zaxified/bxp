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
            .string => |s| if (s.len == 0) 0 else
                std.fmt.parseFloat(f80, s) catch
                parseAmericanNumber(s) catch
                return error.NotANumber,
            .boolean => |b| if (b) @as(f80, 1) else 0,
        };
    }

    pub fn toBool(self: Value) bool {
        return switch (self) {
            .boolean => |b| b,
            .number => |n| n != 0,
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

const Token = struct {
    kind: TokKind,
    text: []const u8,
};

const Tokenizer = struct {
    src: []const u8,
    pos: usize,
    /// Set before returning error.UnexpectedChar so the caller can build a detail message.
    error_char: u8 = 0,
    error_pos: usize = 0, // 0-based position of the bad character in src

    fn init(src: []const u8) Tokenizer {
        return .{ .src = src, .pos = 0 };
    }

    fn skipWs(self: *Tokenizer) void {
        while (self.pos < self.src.len and self.src[self.pos] == ' ')
            self.pos += 1;
    }

    fn next(self: *Tokenizer) !Token {
        self.skipWs();
        if (self.pos >= self.src.len) return Token{ .kind = .eof, .text = "" };

        const c = self.src[self.pos];

        // String literal 'text'
        // Special case: triple single-quote ''' is a placeholder for the output
        // quote character defined by csv_text_quote_out ("none"/"single"/"double").
        if (c == '\'') {
            self.pos += 1;
            if (self.pos + 1 < self.src.len and
                self.src[self.pos] == '\'' and self.src[self.pos + 1] == '\'')
            {
                self.pos += 2;
                return Token{ .kind = .triple_quote, .text = "'''" };
            }
            const start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != '\'')
                self.pos += 1;
            const text = self.src[start..self.pos];
            if (self.pos < self.src.len) self.pos += 1; // consume closing '
            return Token{ .kind = .string_lit, .text = text };
        }

        // Field reference [Name] or [n]
        if (c == '[') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != ']')
                self.pos += 1;
            const text = self.src[start..self.pos];
            if (self.pos < self.src.len) self.pos += 1; // consume ]
            return Token{ .kind = .field_ref, .text = text };
        }

        // Number literal
        if (std.ascii.isDigit(c) or (c == '-' and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1]))) {
            const start = self.pos;
            if (c == '-') self.pos += 1;
            while (self.pos < self.src.len and (std.ascii.isDigit(self.src[self.pos]) or self.src[self.pos] == '.'))
                self.pos += 1;
            return Token{ .kind = .number_lit, .text = self.src[start..self.pos] };
        }

        // Identifier or keyword
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = self.pos;
            while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_'))
                self.pos += 1;
            return Token{ .kind = .ident, .text = self.src[start..self.pos] };
        }

        // Operators
        self.pos += 1;
        return switch (c) {
            '(' => Token{ .kind = .lparen, .text = "(" },
            ')' => Token{ .kind = .rparen, .text = ")" },
            ',' => Token{ .kind = .comma, .text = "," },
            '+' => Token{ .kind = .plus, .text = "+" },
            '-' => Token{ .kind = .minus, .text = "-" },
            '*' => Token{ .kind = .star, .text = "*" },
            '/' => Token{ .kind = .slash, .text = "/" },
            '&' => Token{ .kind = .amp, .text = "&" },
            '=' => Token{ .kind = .eq, .text = "=" },
            '!' => blk: {
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    break :blk Token{ .kind = .neq, .text = "!=" };
                }
                self.error_char = '!';
                self.error_pos = self.pos - 1; // self.pos was already incremented above
                return error.UnexpectedChar;
            },
            '<' => blk: {
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    break :blk Token{ .kind = .lte, .text = "<=" };
                }
                break :blk Token{ .kind = .lt, .text = "<" };
            },
            '>' => blk: {
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    break :blk Token{ .kind = .gte, .text = ">=" };
                }
                break :blk Token{ .kind = .gt, .text = ">" };
            },
            else => {
                self.error_char = c;
                self.error_pos = self.pos - 1; // self.pos was already incremented above
                return error.UnexpectedChar;
            },
        };
    }

    fn peek(self: *Tokenizer) !Token {
        const saved = self.pos;
        const tok = try self.next();
        self.pos = saved;
        return tok;
    }
};

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
    fn setDetail(self: *const Parser, comptime fmt: []const u8, args: anytype) void {
        const d = self.ctx.error_detail orelse return;
        d.* = std.fmt.allocPrint(self.ctx.alloc, fmt, args) catch return;
    }

    /// Emit one NDJSON record describing a successful function call to
    /// `ctx.trace_writer` (no-op when the writer is null). Errors are
    /// swallowed — tracing must never disrupt evaluation.
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
        w.flush() catch return;
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

    // and_expr := cmp_expr ('AND' cmp_expr)*
    fn parseAnd(self: *Parser) anyerror!Value {
        var left = try self.parseCmp();
        while (true) {
            const t = try self.tok.peek();
            if (t.kind != .ident or !std.ascii.eqlIgnoreCase(t.text, "AND")) break;
            _ = try self.tok.next();
            const right = try self.parseCmp();
            left = Value{ .boolean = left.toBool() and right.toBool() };
        }
        return left;
    }

    // cmp_expr := add_expr (op add_expr)?
    fn parseCmp(self: *Parser) anyerror!Value {
        const left = try self.parseAdd();
        const t = try self.tok.peek();
        const op = t.kind;
        if (op != .eq and op != .neq and op != .lt and op != .gt and op != .lte and op != .gte)
            return left;
        _ = try self.tok.next();
        const right = try self.parseAdd();

        // Try numeric comparison first, fall back to string comparison.
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
                // Division by zero silently produces an empty string (no warning, no summary entry).
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
                const result = try self.evalCall(name);
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

        self.last_field_name = name;

        if (self.ctx.decimal_sep_in != '.' and
            std.mem.indexOfScalar(u8, raw, self.ctx.decimal_sep_in) != null and
            isNumericWithSep(raw, self.ctx.decimal_sep_in))
        {
            const copy = try self.ctx.alloc.dupe(u8, raw);
            std.mem.replaceScalar(u8, copy, self.ctx.decimal_sep_in, '.');
            return Value{ .string = copy };
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
    fn evalCall(self: *Parser, name: []const u8) anyerror!Value {
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
                return b.impl.?(self, args.items);
            }
        }

        self.setDetail("unknown function '{s}' — check function name spelling", .{name});
        return error.UnknownFunction;
    }
};

// ---------------------------------------------------------------------------
// Catalog types — exposed via `bxp-fmt --docs` for the GUI's expression
// catalog (functions / keywords / operators / tokens). Per-fn FnDoc
// declarations live RIGHT NEXT to each builtin impl + adapter further down,
// so adding a function in one place keeps doc/impl/adapter visibly in sync.
// The bottom `builtins` array just lists references to those named docs.
// ---------------------------------------------------------------------------

pub const FnDoc = struct {
    name: []const u8,
    signature: []const u8,
    description: []const u8,
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
};

// ---------------------------------------------------------------------------
// Number parsing helpers
// ---------------------------------------------------------------------------

/// Parses a number in American thousands-separated format: "1,234.56", "-1,234,567", "1,000".
/// Requires at least one thousands group (,ddd) — plain "123" is rejected (handled by parseFloat).
/// Returns error.NotANumber if the string does not match the pattern.
fn parseAmericanNumber(s: []const u8) error{NotANumber}!f80 {
    var i: usize = 0;
    if (i < s.len and s[i] == '-') i += 1;
    // 1–3 leading digits before the first thousands group
    const leading_start = i;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    const leading = i - leading_start;
    if (leading == 0 or leading > 3) return error.NotANumber;
    // At least one ',ddd' group required
    var groups: usize = 0;
    while (i < s.len and s[i] == ',') {
        if (s.len < i + 4) return error.NotANumber;
        if (!std.ascii.isDigit(s[i + 1]) or
            !std.ascii.isDigit(s[i + 2]) or
            !std.ascii.isDigit(s[i + 3])) return error.NotANumber;
        i += 4;
        groups += 1;
        // A digit immediately after the group means >3 digits between commas → invalid
        if (i < s.len and std.ascii.isDigit(s[i])) return error.NotANumber;
    }
    if (groups == 0) return error.NotANumber;
    // Optional decimal part
    if (i < s.len) {
        if (s[i] != '.') return error.NotANumber;
        i += 1;
        if (i >= s.len or !std.ascii.isDigit(s[i])) return error.NotANumber;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    }
    if (i != s.len) return error.NotANumber;
    // Strip commas into a stack buffer and parse
    var buf: [32]u8 = undefined;
    var bi: usize = 0;
    for (s) |c| {
        if (c == ',') continue;
        if (bi >= buf.len) return error.NotANumber;
        buf[bi] = c;
        bi += 1;
    }
    return std.fmt.parseFloat(f80, buf[0..bi]) catch return error.NotANumber;
}

// ---------------------------------------------------------------------------
// Built-in function implementations
// ---------------------------------------------------------------------------

// ── ABS ─────────────────────────────────────────────────────────────────
const abs_doc: FnDoc = .{
    .name = "ABS",
    .signature = "ABS(f)",
    .description = "Absolute numeric value.",
};
fn builtinAbs(args: []Value) !Value {
    if (args.len != 1) return error.WrongArgCount;
    return Value{ .number = @abs(try args[0].toNumber()) };
}
fn adaptAbs(p: *Parser, args: []Value) anyerror!Value {
    return builtinAbs(args) catch |err| {
        if (args.len >= 1) switch (args[0]) { .string => |s| p.setNotANumber(s), else => {} };
        return err;
    };
}

// ── FIELDS ──────────────────────────────────────────────────────────────
const fields_doc: FnDoc = .{
    .name = "FIELDS",
    .signature = "FIELDS(n)",
    .description = "Field value by 1-based column index (alternative to [ColumnName] when the header is unknown).",
};
fn builtinFields(args: []Value, ctx: *const Context) !Value {
    if (args.len != 1) return error.WrongArgCount;
    const idx = @as(usize, @intFromFloat(try args[0].toNumber()));
    return Value{ .string = ctx.field(idx - 1) };
}
fn adaptFields(p: *Parser, args: []Value) anyerror!Value {
    return builtinFields(args, p.ctx) catch |err| {
        if (args.len >= 1) switch (args[0]) { .string => |s| p.setNotANumber(s), else => {} };
        return err;
    };
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
    .description = "Strip currency symbol or code from a price string, return the numeric part.",
};
/// PRICE_VALUE("$88744.27") → "88744.27"
/// PRICE_VALUE("€24.00") → "24.00"
/// PRICE_VALUE("24.00 CZK") → "24.00"
fn builtinPriceValue(args: []Value) !Value {
    if (args.len != 1) return error.WrongArgCount;
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
};
/// PRICE_CURRENCY("$88744.27") → "USD"
/// PRICE_CURRENCY("€24.00") → "EUR"
/// PRICE_CURRENCY("24.00 CZK") → "CZK"
fn builtinPriceCurrency(args: []Value) !Value {
    if (args.len != 1) return error.WrongArgCount;
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
    .description = "Map field value through the template's ticker_map. Returns value unchanged if not found.",
};
/// TICKER(field) — look up in ticker_map, return as-is if not found.
fn builtinTicker(args: []Value, ctx: *const Context) !Value {
    if (args.len != 1) return error.WrongArgCount;
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
};
/// LOOKUP — reads a value stored by pre_pass.
///   3-arg: LOOKUP(name, key, field)  — explicit pre_pass name.
///   2-arg: LOOKUP(key, field)        — only when a single pre_pass is defined;
///                                      its name is taken from ctx.single_prepass_name.
/// The lookup table uses composite keys "name\x00key\x00field".
/// Returns empty string if no pre_pass table is present or key/field not found.
fn builtinLookup(args: []Value, ctx: *const Context) !Value {
    if (args.len != 2 and args.len != 3) return error.WrongArgCount;
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
        if (err == error.LookupRequiresName) {
            p.setDetail("LOOKUP requires explicit name when multiple pre_passes are defined", .{});
        }
        return err;
    };
}

// ── SPLIT_PART ──────────────────────────────────────────────────────────
const split_part_doc: FnDoc = .{
    .name = "SPLIT_PART",
    .signature = "SPLIT_PART(s, delim, n)",
    .description = "Return the n-th part of `s` split by `delim` (1-based index).",
};
/// SPLIT_PART(string, delimiter, n) — split string by delimiter, return nth part (1-based).
/// Returns "" when fewer than n parts exist or delimiter is empty.
fn builtinSplitPart(args: []Value) !Value {
    if (args.len != 3) return error.WrongArgCount;
    const s = switch (args[0]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const delim = switch (args[1]) {
        .string => |v| v,
        else => return error.StringExpected,
    };
    const n = @as(usize, @intFromFloat(try args[2].toNumber()));
    if (n == 0 or delim.len == 0) return Value{ .string = "" };

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
fn adaptSplitPart(p: *Parser, args: []Value) anyerror!Value {
    return builtinSplitPart(args) catch |err| {
        if (args.len >= 3) switch (args[2]) { .string => |s| p.setNotANumber(s), else => {} };
        return err;
    };
}

// ── CONTAINS ────────────────────────────────────────────────────────────
const contains_doc: FnDoc = .{
    .name = "CONTAINS",
    .signature = "CONTAINS(haystack, needle)",
    .description = "Returns \"true\" if `haystack` contains `needle`, else \"false\".",
};
/// CONTAINS(string, substring) → bool — true when substring is found inside string.
fn builtinContains(args: []Value) !Value {
    if (args.len != 2) return error.WrongArgCount;
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
    .description = "Replace all occurrences of `from` in `s` with `to`.",
};
/// REPLACE(string, old, new) — replace all occurrences of old with new.
fn builtinReplace(args: []Value, alloc: std.mem.Allocator) !Value {
    if (args.len != 3) return error.WrongArgCount;
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
};
/// TRIM(f) — strip leading and trailing whitespace (spaces, tabs, CR, LF).
fn builtinTrim(args: []Value) !Value {
    if (args.len != 1) return error.WrongArgCount;
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
    .description = "Round `f` to `n` decimal places.",
};
/// ROUND(f, n) — round f to n decimal places.
/// n >= 0: round to n places after decimal point; n < 0: round to tens/hundreds/etc.
fn builtinRound(args: []Value) !Value {
    if (args.len != 2) return error.WrongArgCount;
    const x = try args[0].toNumber();
    const n: i32 = @intFromFloat(@trunc(try args[1].toNumber()));
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
};
/// FLOOR(f) — largest integer less than or equal to f.
fn builtinFloor(args: []Value) !Value {
    if (args.len != 1) return error.WrongArgCount;
    return Value{ .number = @floor(try args[0].toNumber()) };
}
fn adaptFloor(p: *Parser, args: []Value) anyerror!Value {
    return builtinFloor(args) catch |err| {
        if (args.len >= 1) switch (args[0]) { .string => |s| p.setNotANumber(s), else => {} };
        return err;
    };
}

// ── CEILING ─────────────────────────────────────────────────────────────
const ceiling_doc: FnDoc = .{
    .name = "CEILING",
    .signature = "CEILING(f)",
    .description = "Round `f` up to nearest integer.",
};
/// CEILING(f) — smallest integer greater than or equal to f.
fn builtinCeiling(args: []Value) !Value {
    if (args.len != 1) return error.WrongArgCount;
    return Value{ .number = @ceil(try args[0].toNumber()) };
}
fn adaptCeiling(p: *Parser, args: []Value) anyerror!Value {
    return builtinCeiling(args) catch |err| {
        if (args.len >= 1) switch (args[0]) { .string => |s| p.setNotANumber(s), else => {} };
        return err;
    };
}

// ── RAND ────────────────────────────────────────────────────────────────
const rand_doc: FnDoc = .{
    .name = "RAND",
    .signature = "RAND()",
    .description = "Random float in [0, 1).",
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
};
/// COALESCE(a, b, ...) — return the first non-empty argument.
/// A string is considered empty if its trimmed length is 0 (whitespace-only
/// counts as empty). Numbers and booleans are never empty — even 0 and false
/// are returned. If every argument is empty, the last argument is returned
/// verbatim so callers can supply a default: COALESCE(@a, @b, "0").
fn builtinCoalesce(args: []Value) !Value {
    if (args.len == 0) return error.WrongArgCount;
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
    .description = "Reformat a date/time string. Format tokens use sunrise syntax (e.g. %Y-%m-%d, %d.%m.%Y, %H:%M:%S).",
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
    if (args.len != 3) return error.WrongArgCount;
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
    const normalized = if (containsMMM(from_fmt))
        try normalizeMonthAbbrev(input, alloc)
    else
        input;
    // Parse failures silently produce an empty string (no warning, no summary entry).
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

pub const keywords = [_]KeywordDoc{ and_kw_doc, or_kw_doc };

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
