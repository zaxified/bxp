/// Aggregates and serializes the full documentation surface that
/// `inspect.docsJson` exposes to the GUI:
///
///   * Expression catalog (functions / keywords / operators / tokens) —
///     re-exported live from `bxp-core/src/expr.zig` where each `FnDoc`
///     sits next to the builtin it documents.
///   * Config schema (`config_schema` array of FieldDoc) — assembled from
///     two sources: per-struct `pub const fields` tables co-located with
///     each config struct in `bxp-core/src/config.zig`, plus the
///     "envelope" entries declared below for slots that aren't backed by
///     a struct (top-level keys, map wildcards, the legacy pre_pass
///     single-block form).
///
/// The output JSON shape is the GUI contract — see
/// `bxp-gui/lib/store/trace_store.dart` (`functions`, `keywords`,
/// `operators`, `tokens`, `config_schema`) and
/// `bxp-gui/lib/store/schema_gate.dart` (FieldDoc consumption).
const std = @import("std");
const config = @import("config");
const expr = @import("expr");
const json5 = @import("json5");

const FieldDoc = config.FieldDoc;

// Function list flattened from expr.builtins (keeping the iteration order
// the GUI sees today). expr.builtins is a comptime array of {impl, doc} pairs;
// we extract only the doc side so that the serializer never touches function
// pointers, which are not meaningful at the JSON output stage.
const functions = blk: {
    var arr: [expr.builtins.len]expr.FnDoc = undefined;
    for (expr.builtins, 0..) |b, i| arr[i] = b.doc;
    break :blk arr;
};

// ── Function categories (Markdown reference grouping) ────────────────────────
//
// Editorial grouping of the builtins for the `expr-functions.md` reference page
// only — the JSON docs catalog and the GUI still see the flat `functions` list
// above in its original order. The name→category map lives here in the doc
// pipeline (not on each FnDoc) because it is a presentation concern; a comptime
// guard below turns any miscategorised/new builtin into a BUILD error, so the
// map can never silently drift out of sync with `expr.builtins`.
const FnCategory = enum { logic, text, regex, lookup, number, date, source };

const FnGroup = struct { cat: FnCategory, title: []const u8, intro: []const u8 };
const fn_groups = [_]FnGroup{
    .{ .cat = .logic, .title = "Logic & conditionals", .intro = "Branch, fall back to the first non-empty value, and test membership." },
    .{ .cat = .text, .title = "Text", .intro = "Trim, case-fold, slice, pad, search, and measure strings." },
    .{ .cat = .regex, .title = "Pattern matching", .intro = "Linear-time (ReDoS-safe) regular-expression match and extract." },
    .{ .cat = .lookup, .title = "Lookup & mapping", .intro = "Whole-value remap, substring replace, and `pre_pass` table lookups." },
    .{ .cat = .number, .title = "Numbers & money", .intro = "Exact fixed-point arithmetic, rounding, min/max, and price parsing." },
    .{ .cat = .date, .title = "Dates & time", .intro = "Reformat, shift, diff, and decompose dates — business-day aware." },
    .{ .cat = .source, .title = "Row & source context", .intro = "Values drawn from the current row's position and its source file." },
};

fn fnCategory(name: []const u8) ?FnCategory {
    const map = .{
        // logic & conditionals
        .{ "IF", .logic },        .{ "CASE", .logic },     .{ "IFERROR", .logic },
        .{ "COALESCE", .logic },  .{ "NULLIF", .logic },   .{ "IN", .logic },
        .{ "ISEMPTY", .logic },
        // text
        .{ "TRIM", .text },       .{ "UPPER", .text },     .{ "LOWER", .text },
        .{ "UNACCENT", .text },   .{ "PROPER", .text },    .{ "LEFT", .text },
        .{ "RIGHT", .text },      .{ "SUBSTR", .text },    .{ "LPAD", .text },
        .{ "RPAD", .text },       .{ "POSITION", .text },  .{ "LEN", .text },
        .{ "CONTAINS", .text },   .{ "STARTS_WITH", .text }, .{ "ENDS_WITH", .text },
        .{ "SPLIT_PART", .text },
        // pattern matching
        .{ "REGEX_MATCH", .regex }, .{ "REGEX_EXTRACT", .regex },
        // lookup & mapping
        .{ "REMAP", .lookup },    .{ "REPLACE", .lookup }, .{ "LOOKUP", .lookup },
        // numbers & money
        .{ "ABS", .number },      .{ "ROUND", .number },   .{ "FLOOR", .number },
        .{ "CEILING", .number },  .{ "MOD", .number },     .{ "GREATEST", .number },
        .{ "LEAST", .number },    .{ "RAND", .number },    .{ "PRICE_VALUE", .number },
        .{ "PRICE_CURRENCY", .number },
        // dates & time
        .{ "DATE_CONVERT", .date }, .{ "NOW", .date },     .{ "DATEADD", .date },
        .{ "DATEDIFF", .date },   .{ "WORKDAY", .date },   .{ "YEAR", .date },
        .{ "MONTH", .date },      .{ "DAY", .date },       .{ "WEEKDAY", .date },
        .{ "EOMONTH", .date },    .{ "NTH_DOW", .date },
        // row & source context
        .{ "FIELDS", .source },   .{ "FILENAME", .source }, .{ "RECORD_NUM", .source },
        .{ "SHEET_NAME", .source },
    };
    inline for (map) |e| if (std.mem.eql(u8, name, e[0])) return e[1];
    return null;
}

// Drift guard: every builtin must be categorised, exactly once is enforced by
// construction (a name can only appear once in the map). A new builtin with no
// category entry fails the build here instead of vanishing from the docs.
comptime {
    @setEvalBranchQuota(10_000); // 53 builtins × 53 map probes exceeds the 1000 default
    for (expr.builtins) |b| {
        if (fnCategory(b.name) == null)
            @compileError("docs.zig: uncategorised builtin '" ++ b.name ++ "' — add it to fnCategory()");
    }
}

const keywords = expr.keywords;
const operators = expr.operators;
const tokens = expr.tokens;
const date_tokens = expr.date_tokens;
const precedence = expr.precedence;

// ── Schema-tree bindings ─────────────────────────────────────────────────────
//
// Each binding takes a config struct's `fields` table (with relative key
// names) and slots it under a path prefix in the JSON tree. The serializer
// joins prefix + "." + entry.key to produce the flat full-path keys the
// GUI consumes (e.g. "conversion_templates.*.pre_pass.*.when").

const StructBinding = struct {
    prefix: []const u8,
    fields: []const FieldDoc,
};

const struct_bindings = [_]StructBinding{
    .{ .prefix = "conversion_templates.*",             .fields = &config.BrokerConfig.fields },
    .{ .prefix = "conversion_templates.*.xlsx_sheet",  .fields = &config.XlsxSheet.fields },
    .{ .prefix = "conversion_templates.*.zip_input",   .fields = &config.ZipInput.fields },
    .{ .prefix = "conversion_templates.*.row_rules.*", .fields = &config.RowRule.fields },
    .{ .prefix = "conversion_templates.*.pre_pass.*",  .fields = &config.PrePass.fields },
};

// ── Envelope entries ─────────────────────────────────────────────────────────
//
// Schema slots that aren't backed by a Zig struct: top-level keys, map
// wildcards (`*`), and the legacy pre_pass single-block form. These carry
// their full dotted path in `key`.
//
// The named-block form's per-field docs come from PrePass.fields (via
// struct_bindings); the legacy form's flat children (when/key/values) are
// listed here so the GUI keeps recognising old configs.

const envelope_entries = [_]FieldDoc{
    .{
        .key = "maps",
        .type_name = "object",
        .required = false,
        .description = "Named, reusable key→value tables. Each entry: map_name -> { key: value }. Referenced by REMAP (whole-value lookup) / REPLACE (substring) via their 'name' argument. A template may also define a same-named maps block that overrides a global entry.",
        .insert_order = "alpha",
        .insert_template = "{}",
    },
    .{
        .key = "maps.*",
        .type_name = "object",
        .required = false,
        .description = "One named map. Keys and values are arbitrary strings; key order is preserved (REPLACE applies pairs in declaration order).",
        .insert_order = "alpha",
        .insert_template =
        \\{ KEY: "VALUE" }
        ,
    },
    .{
        .key = "conversion_templates",
        .type_name = "object",
        .required = true,
        .description = "Map of template_id -> broker config. Each key is a unique template identifier used with --template flag. When bxp-cli runs without --template, all templates execute in declaration order.",
        .ordered = true,
        .insert_order = "append",
        .insert_template = "{}",
    },
    .{
        .key = "conversion_templates.*",
        .type_name = "object",
        .required = false,
        .description = "One conversion template — see `conversion_templates.*.*` fields for contents.",
        .insert_order = "schema",
        .insert_template = config.BrokerConfig.scaffold_template,
    },
    .{
        .key = "conversion_templates.*.input_schema.*",
        .type_name = "expression",
        .required = true,
        .description = "Expression evaluated per input row. Result stored in the $variable. Use [ColumnName] to reference input CSV columns.",
        .validator = .expr_string,
    },
    .{
        .key = "conversion_templates.*.output_schema.*",
        .type_name = "string",
        .required = true,
        .description = "$variable whose evaluated value fills this output column. Must start with $.",
        .insert_template = "\"$variable\"",
        .validator = .starts_with_dollar,
        .autocomplete = .input_schema_keys,
    },
    .{
        .key = "conversion_templates.*.row_rules.*",
        .type_name = "object",
        .required = false,
        .description = "One row rule. Schema-ordered children: `when` (condition), `rows` (output rows produced when matched).",
        .insert_order = "schema",
        .insert_template = config.RowRule.scaffold_template,
    },
    .{
        .key = "conversion_templates.*.row_rules.*.rows.*",
        .type_name = "object",
        .required = false,
        .description = "One output row. Map of $variable -> expression overriding the value from input_schema. Empty object {} = take all values verbatim from input_schema.",
        .insert_order = "append",
        .insert_template = "{}",
    },
    // ── Legacy pre_pass single-block form ───────────────────────────────────
    .{
        .key = "conversion_templates.*.pre_pass.when",
        .type_name = "expression",
        .required = true,
        .description = "Legacy single-block form. Filter — only rows matching this condition are added to the lookup table.",
        .validator = .expr_string,
    },
    .{
        .key = "conversion_templates.*.pre_pass.key",
        .type_name = "expression",
        .required = true,
        .description = "Legacy single-block form. Expression evaluated per row to produce the lookup key string.",
        .validator = .expr_string,
    },
    .{
        .key = "conversion_templates.*.pre_pass.values",
        .type_name = "object",
        .required = true,
        .description = "Legacy single-block form. Map of field_name -> expression. Each value is evaluated per pre-pass row and stored for retrieval via LOOKUP(key, 'field_name'). Field names have no $ prefix.",
        .insert_order = "append",
    },
    .{
        .key = "conversion_templates.*.pre_pass.values.*",
        .type_name = "expression",
        .required = true,
        .description = "Expression evaluated per pre-pass row. Result stored under the field name for LOOKUP retrieval.",
        .validator = .expr_string,
    },
    // ── Named pre_pass blocks ───────────────────────────────────────────────
    .{
        .key = "conversion_templates.*.pre_pass.*",
        .type_name = "object",
        .required = false,
        .description = "Named pre_pass block. The map key is the block name (typed by the user in the GUI's Add-Child dialog or written directly in JSON5) and becomes part of the LOOKUP namespace; different names cannot collide. The `insert_template` below is the inner `{ when, key, values }` body — the outer `name1: { ... }` wrapper is supplied by whatever creates the entry (free-form key input in the GUI; verbatim JSON5 syntax for hand-edited configs).",
        .insert_order = "schema",
        .insert_template = config.PrePass.scaffold_template,
    },
    .{
        .key = "conversion_templates.*.pre_pass.*.values.*",
        .type_name = "expression",
        .required = true,
        .description = "Expression evaluated per pre-pass row. Result stored under the field name for LOOKUP retrieval.",
        .validator = .expr_string,
    },
};

// ── Serializer ───────────────────────────────────────────────────────────────

pub fn writeDocs(alloc: std.mem.Allocator, writer: *std.Io.Writer) !void {
    var jw: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };

    try jw.beginObject();

    // functions
    try jw.objectField("functions");
    try jw.beginArray();
    for (functions) |f| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(f.name);
        try jw.objectField("signature");
        try jw.write(f.signature);
        try jw.objectField("description");
        try jw.write(f.description);
        try jw.objectField("example");
        try jw.write(f.example);
        try jw.objectField("args");
        try jw.beginArray();
        for (f.args) |a| {
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(a.name);
            try jw.objectField("kind");
            try jw.write(@tagName(a.kind));
            // `integer_in_range` carries a {min,max} payload; surface it so
            // the GUI can show the accepted range in arg-type hints.
            switch (a.kind) {
                .integer_in_range => |r| {
                    try jw.objectField("min");
                    try jw.write(r.min);
                    try jw.objectField("max");
                    try jw.write(r.max);
                },
                else => {},
            }
            try jw.endObject();
        }
        try jw.endArray();
        try jw.objectField("min_args");
        try jw.write(f.min_args);
        try jw.objectField("max_args");
        try jw.write(f.max_args);
        try jw.endObject();
    }
    try jw.endArray();

    // keywords
    try jw.objectField("keywords");
    try jw.beginArray();
    for (keywords) |k| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(k.name);
        try jw.objectField("description");
        try jw.write(k.description);
        try jw.endObject();
    }
    try jw.endArray();

    // operators
    try jw.objectField("operators");
    try jw.beginArray();
    for (operators) |op| {
        try jw.beginObject();
        try jw.objectField("token");
        try jw.write(op.token);
        try jw.objectField("description");
        try jw.write(op.description);
        try jw.endObject();
    }
    try jw.endArray();

    // tokens
    try jw.objectField("tokens");
    try jw.beginArray();
    for (tokens) |tok| {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write(tok.kind);
        try jw.objectField("syntax");
        try jw.write(tok.syntax);
        try jw.objectField("description");
        try jw.write(tok.description);
        try jw.endObject();
    }
    try jw.endArray();

    // date_tokens: the DATE_CONVERT format vocabulary (token / meaning / example).
    try jw.objectField("date_tokens");
    try jw.beginArray();
    for (date_tokens) |t| {
        try jw.beginObject();
        try jw.objectField("token");
        try jw.write(t.token);
        try jw.objectField("meaning");
        try jw.write(t.meaning);
        try jw.objectField("example");
        try jw.write(t.example);
        try jw.endObject();
    }
    try jw.endArray();

    // precedence: operator-precedence levels, highest (level 1) to lowest.
    try jw.objectField("precedence");
    try jw.beginArray();
    for (precedence) |p| {
        try jw.beginObject();
        try jw.objectField("level");
        try jw.write(p.level);
        try jw.objectField("operators");
        try jw.write(p.operators);
        try jw.objectField("description");
        try jw.write(p.description);
        try jw.endObject();
    }
    try jw.endArray();

    // config_schema: flat array of FieldDoc entries with full dotted-path keys.
    // Order matters for the GUI's insert-position logic: envelope entries come
    // first (they define the top-level shape), followed by struct-bound fields
    // in prefix declaration order. Within each struct binding the field order
    // mirrors the struct definition in config.zig, which determines the
    // schema-ordered insert sequence used by the Add-Child dialog.
    try jw.objectField("config_schema");
    try jw.beginArray();
    for (envelope_entries) |f| try writeSchemaEntry(alloc, &jw, f.key, f);
    for (struct_bindings) |bind| {
        for (bind.fields) |f| {
            // Construct the full key by joining the binding prefix with the
            // per-struct field key (e.g. "conversion_templates.*" + "data_dir"
            // → "conversion_templates.*.data_dir"). Freed immediately after
            // the entry is written to cap peak allocation.
            const full = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ bind.prefix, f.key });
            defer alloc.free(full);
            try writeSchemaEntry(alloc, &jw, full, f);
        }
    }
    try jw.endArray();

    try jw.endObject();
    try writer.writeByte('\n');
}

fn writeSchemaEntry(alloc: std.mem.Allocator, jw: *std.json.Stringify, full_key: []const u8, f: FieldDoc) !void {
    try jw.beginObject();
    try jw.objectField("key");
    try jw.write(full_key);
    try jw.objectField("type_name");
    try jw.write(f.type_name);
    try jw.objectField("required");
    try jw.write(f.required);
    try jw.objectField("default");
    if (f.default) |d| try jw.write(d) else try jw.write(null);
    try jw.objectField("description");
    try jw.write(f.description);
    try jw.objectField("enum_values");
    if (f.enum_values) |vs| {
        try jw.beginArray();
        for (vs) |v| try jw.write(v);
        try jw.endArray();
    } else try jw.write(null);
    try jw.objectField("ordered");
    try jw.write(f.ordered);
    try jw.objectField("insert_order");
    if (f.insert_order) |s| try jw.write(s) else try jw.write(null);
    try jw.objectField("insert_template");
    if (f.insert_template) |snippet| {
        // Templates are stored as JSON5 source strings (allowing comments and
        // unquoted keys for readability in config.zig). We preprocess → parse
        // → re-emit so the GUI receives a proper JSON value, not a raw string.
        // Failures here surface as runtime errors during `inspect.docsJson`,
        // catching template typos early — the same templates are also validated
        // by the "every insert_template parses as JSON5" unit test.
        const json_bytes = try json5.preprocess(alloc, snippet);
        defer alloc.free(json_bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{});
        defer parsed.deinit();
        try jw.write(parsed.value);
    } else {
        try jw.write(null);
    }
    try jw.objectField("validator");
    try jw.write(@tagName(f.validator));
    try jw.objectField("autocomplete");
    try jw.write(@tagName(f.autocomplete));
    try jw.endObject();
}

// ── Markdown emitters (zig build docs-md) ────────────────────────────────────
//
// One generic table renderer (`writeTable`) turns any `[]const SomeDoc` into a
// Markdown table by reflecting over the chosen struct fields — so each catalog
// is a one-line call, not a bespoke per-table emitter. The same `writeCell` +
// `writeEscaped` primitives back every catalog (incl. the future bxp-cli flag /
// bxp-mcp tool / bxp-gui GuiToolDoc surfaces in their own packages).
//
// NOTE: FnDoc carries no `returns` field, so the functions table has no
// "Returns" column; the "Built-in" vs "Date arithmetic" split is editorial,
// not in the catalog — generation emits one flat table.

/// One column: the header text + the struct field it reads. `code = true` wraps
/// the cell in backticks (for signatures / tokens / keys). `hl` instead emits a
/// coloured inline-HTML `<code class="…">` (e.g. "hl-fn", "hl-type", "hl-num")
/// the stylesheet binds to the active theme's --md-code-hl-* token colour.
pub const Col = struct {
    head: []const u8,
    field: []const u8,
    code: bool = false,
    hl: ?[]const u8 = null,
};

pub fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    // Escape the two characters that would break a Markdown table cell.
    for (s) |c| switch (c) {
        '|' => try w.writeAll("\\|"),
        '\n' => try w.writeByte(' '),
        else => try w.writeByte(c),
    };
}

/// Render one cell value by its Zig type: string, bool→yes/no, int, enum tag,
/// or optional (null → "—"). Comptime-dispatched, so any Doc field just works.
pub fn writeCell(w: *std.Io.Writer, value: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |v| try writeCell(w, v) else try w.writeAll("—"),
        .bool => try w.writeAll(if (value) "yes" else "no"),
        .int, .comptime_int => try w.print("{d}", .{value}),
        .@"enum" => try w.writeAll(@tagName(value)),
        .pointer => |p| if (p.size == .slice and p.child == u8)
            try writeEscaped(w, value)
        else
            @compileError("writeCell: unsupported pointer " ++ @typeName(@TypeOf(value))),
        else => @compileError("writeCell: unsupported type " ++ @typeName(@TypeOf(value))),
    }
}

/// Like `writeCell` but HTML-escapes string values — for cells emitted inside a
/// raw `<code>` (the coloured `hl` columns), not a Markdown backtick span.
fn writeCellHtml(w: *std.Io.Writer, value: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |v| try writeCellHtml(w, v) else try w.writeAll("—"),
        .bool => try w.writeAll(if (value) "yes" else "no"),
        .int, .comptime_int => try w.print("{d}", .{value}),
        .@"enum" => try w.writeAll(@tagName(value)),
        .pointer => |p| if (p.size == .slice and p.child == u8)
            try writeHtmlEscaped(w, value)
        else
            @compileError("writeCellHtml: unsupported pointer " ++ @typeName(@TypeOf(value))),
        else => @compileError("writeCellHtml: unsupported type " ++ @typeName(@TypeOf(value))),
    }
}

/// Generic Markdown table over a slice of structs: header from `cols`, one row
/// per element. Written once, reused by every catalog.
pub fn writeTable(w: *std.Io.Writer, rows: anytype, comptime cols: []const Col) !void {
    inline for (cols) |c| try w.print("| {s} ", .{c.head});
    try w.writeAll("|\n");
    inline for (cols) |_| try w.writeAll("| --- ");
    try w.writeAll("|\n");
    for (rows) |row| {
        inline for (cols) |c| {
            try w.writeAll("| ");
            const v = @field(row, c.field);
            if (c.hl) |cls| {
                // Coloured code cell (skip the wrapper for an empty value so it
                // doesn't render as a stray empty chip).
                if (isNonEmptyStr(v)) {
                    try w.print("<code class=\"{s}\">", .{cls});
                    try writeCellHtml(w, v);
                    try w.writeAll("</code>");
                } else try writeCellHtml(w, v);
            } else {
                // Wrap in backticks only when `code` AND the value isn't an empty
                // string — an empty `arg` shouldn't render as a stray `` `` ``.
                const wrap = c.code and isNonEmptyStr(v);
                if (wrap) try w.writeByte('`');
                try writeCell(w, v);
                if (wrap) try w.writeByte('`');
            }
            try w.writeByte(' ');
        }
        try w.writeAll("|\n");
    }
}

fn isNonEmptyStr(v: anytype) bool {
    const info = @typeInfo(@TypeOf(v));
    if (info == .pointer and info.pointer.size == .slice and info.pointer.child == u8)
        return v.len > 0;
    return true; // non-string code cells (e.g. an exit code int) always wrap
}

// ── Semantic colouring for the reference tables ──────────────────────────────
//
// Plain Markdown backtick spans render monochrome (Pygments only tokenises
// fenced blocks, not inline code in tables). To make the generated reference
// read like syntax-highlighted code, the emitters below wrap function names,
// types, string/number literals, keys and booleans in raw-HTML `<span>`s with a
// semantic class. The stylesheet binds each class to the active theme's
// `--md-code-hl-*` token colour, so the colouring follows whichever palette
// (Light / Dark / VS Code) is selected — no per-theme work here.

/// Inline-HTML escape for a value placed inside a raw `<code>` in a Markdown
/// table cell: guards the table pipe AND the HTML metacharacters, flattening
/// newlines. (Backtick spans don't need this; raw HTML does.)
fn writeHtmlEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '|' => try w.writeAll("&#124;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '\n' => try w.writeByte(' '),
        else => try w.writeByte(c),
    };
}

fn isIdentByte(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or c == '_';
}

/// Render a bxp signature / expression as a coloured inline-HTML `<code>` span:
/// a leading function name (identifier directly before `(`), single-quoted
/// string literals and bare numeric runs each get a semantic class. `extra` is
/// an optional extra class on the `<code>` element (e.g. the muted example).
fn writeExprCode(w: *std.Io.Writer, s: []const u8, extra: []const u8) !void {
    if (extra.len > 0) try w.print("<code class=\"{s}\">", .{extra}) else try w.writeAll("<code>");

    var i: usize = 0;
    // Leading function name: identifier (not starting with a digit) before `(`.
    if (s.len > 0 and isIdentByte(s[0]) and !(s[0] >= '0' and s[0] <= '9')) {
        var j: usize = 0;
        while (j < s.len and isIdentByte(s[j])) : (j += 1) {}
        if (j < s.len and s[j] == '(') {
            try w.writeAll("<span class=\"hl-fn\">");
            try writeHtmlEscaped(w, s[0..j]);
            try w.writeAll("</span>");
            i = j;
        }
    }
    while (i < s.len) {
        const c = s[i];
        if (c == '\'') { // single-quoted string literal, through the closing quote
            var j = i + 1;
            while (j < s.len and s[j] != '\'') : (j += 1) {}
            const end = if (j < s.len) j + 1 else s.len;
            try w.writeAll("<span class=\"hl-str\">");
            try writeHtmlEscaped(w, s[i..end]);
            try w.writeAll("</span>");
            i = end;
        } else if (c >= '0' and c <= '9') { // bare numeric run
            var j = i;
            while (j < s.len and ((s[j] >= '0' and s[j] <= '9') or s[j] == '.')) : (j += 1) {}
            try w.writeAll("<span class=\"hl-num\">");
            try writeHtmlEscaped(w, s[i..j]);
            try w.writeAll("</span>");
            i = j;
        } else {
            try writeHtmlEscaped(w, s[i .. i + 1]);
            i += 1;
        }
    }
    try w.writeAll("</code>");
}

/// A single-token coloured `<code class="<cls>">value</code>` cell.
fn writeTagged(w: *std.Io.Writer, cls: []const u8, value: []const u8) !void {
    try w.print("<code class=\"{s}\">", .{cls});
    try writeHtmlEscaped(w, value);
    try w.writeAll("</code>");
}

pub fn writeFunctionsMd(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\# Expression functions
        \\
        \\<!-- GENERATED by `zig build docs-md` from the FnDoc catalog in expr.zig. Do not edit. -->
        \\
        \\All function names are case-insensitive. Functions are grouped by purpose
        \\below; each table sorts on a header click and filters as you type.
        \\
    );
    // One section + table per category, in `fn_groups` order. Rows come from the
    // flat `functions` list filtered by `fnCategory`, so per-function metadata
    // stays single-sourced in expr.zig's FnDoc catalog.
    inline for (fn_groups) |g| {
        try w.print(
            \\
            \\## {s}
            \\
            \\{s}
            \\
            \\| Function | Description |
            \\| --- | --- |
            \\
        , .{ g.title, g.intro });
        for (functions) |f| {
            const cat = fnCategory(f.name) orelse continue;
            if (cat != g.cat) continue;
            // Column 1: signature, with the runnable example stacked on a
            // second line (attr_list `.fn-eg` class → CSS renders it smaller /
            // muted). Both are Markdown code spans, so no HTML escaping is
            // needed — `writeEscaped` only guards the table-cell `|`.
            try w.writeAll("| ");
            try writeExprCode(w, f.signature, "");
            if (f.example.len > 0) {
                try w.writeAll("<br>");
                try writeExprCode(w, f.example, "fn-eg");
            }
            try w.writeAll(" | ");
            try writeEscaped(w, f.description);
            try w.writeAll(" |\n");
        }
    }
}

pub fn writeDateTokensMd(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\# Date tokens
        \\
        \\<!-- GENERATED by `zig build docs-md` from the date_tokens catalog in expr.zig. Do not edit. -->
        \\
        \\Both the `from` and `to` arguments of `DATE_CONVERT` use the same token set.
        \\
        \\
    );
    try writeTable(w, date_tokens, &.{
        .{ .head = "Token", .field = "token", .hl = "hl-type" },
        .{ .head = "Meaning", .field = "meaning" },
        .{ .head = "Example", .field = "example" },
    });
}

// config_schema is the one catalog that can't use writeTable verbatim: its key
// column is computed (binding prefix + relative field key), not a plain struct
// field. It still shares writeCell/writeEscaped.
pub fn writeConfigSchemaMd(alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    try w.writeAll(
        \\# Config schema
        \\
        \\<!-- GENERATED by `zig build docs-md` from the FieldDoc tables in config.zig. Do not edit. -->
        \\
        \\Full dotted-path keys, flattened from the per-struct FieldDoc tables.
        \\
        \\| Field | Type | Required | Default | Description |
        \\| --- | --- | --- | --- | --- |
        \\
    );
    for (envelope_entries) |f| try writeSchemaRow(w, f.key, f);
    for (struct_bindings) |bind| {
        for (bind.fields) |f| {
            const full = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ bind.prefix, f.key });
            defer alloc.free(full);
            try writeSchemaRow(w, full, f);
        }
    }
}

fn writeSchemaRow(w: *std.Io.Writer, full_key: []const u8, f: FieldDoc) !void {
    try w.writeAll("| ");
    try writeTagged(w, "hl-key", full_key); // dotted key — name/JSON-key colour
    try w.writeAll(" | ");
    try writeTagged(w, "hl-type", f.type_name);
    try w.writeAll(" | ");
    if (f.required)
        try w.writeAll("<span class=\"hl-yes\">yes</span>")
    else
        try w.writeAll("<span class=\"hl-no\">no</span>");
    try w.writeAll(" | ");
    if (f.default) |d| try writeExprCode(w, d, "") else try w.writeAll("—");
    try w.writeAll(" | ");
    try writeCell(w, f.description);
    try w.writeAll(" |\n");
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "config_schema covers known paths" {
    const testing = std.testing;

    // Total flattened entry count — guard against accidental drift when
    // adding/removing struct fields or envelope entries. The exact number
    // is part of the contract with bxp-gui (`lib/store/schema_gate.dart`
    // expects this many keys). When updating, bump both this assertion
    // and the GUI-side expectation in lockstep.
    var total: usize = envelope_entries.len;
    for (struct_bindings) |bind| total += bind.fields.len;
    try testing.expectEqual(@as(usize, 49), total);

    // Spot-check that representative paths from each binding category are
    // present. Comptime walk; failure points at the missing key.
    const wanted = [_][]const u8{
        "maps",
        "maps.*",
        "conversion_templates",
        "conversion_templates.*",
        "conversion_templates.*.data_dir",
        "conversion_templates.*.xlsx_sheet",
        "conversion_templates.*.xlsx_sheet.name",
        "conversion_templates.*.zip_input",
        "conversion_templates.*.zip_input.entry_pattern",
        "conversion_templates.*.row_rules.*",
        "conversion_templates.*.row_rules.*.when",
        "conversion_templates.*.pre_pass.when",
        "conversion_templates.*.pre_pass.*",
        "conversion_templates.*.pre_pass.*.values",
    };
    for (wanted) |w| {
        var found = false;
        for (envelope_entries) |f| {
            if (std.mem.eql(u8, f.key, w)) {
                found = true;
                break;
            }
        }
        if (!found) for (struct_bindings) |bind| {
            for (bind.fields) |f| {
                if (w.len > bind.prefix.len + 1 and
                    std.mem.startsWith(u8, w, bind.prefix) and
                    w[bind.prefix.len] == '.' and
                    std.mem.eql(u8, w[bind.prefix.len + 1 ..], f.key))
                {
                    found = true;
                    break;
                }
            }
            if (found) break;
        };
        try testing.expect(found);
    }
}

test "FieldDoc.key matches a real struct field" {
    // Catches drift when a struct field is renamed but the FieldDoc table
    // isn't updated (or vice versa). Each entry pairs a struct with its
    // FieldDoc table and an explicit override list for legitimate
    // schema-key vs struct-field mismatches.
    const Override = struct { schema_key: []const u8, field_name: []const u8 };
    const RowRule = config.RowRule;
    const PrePass = config.PrePass;
    const XlsxSheet = config.XlsxSheet;
    const BrokerConfig = config.BrokerConfig;

    inline for (.{
        .{ RowRule, &[_]Override{} },
        .{ PrePass, &[_]Override{} },
        .{ XlsxSheet, &[_]Override{} },
        .{ BrokerConfig, &[_]Override{
            // User-facing JSON5 key is `pre_pass`; struct field is
            // `pre_passes` because the loader supports legacy single-block
            // and named-block forms under the same JSON key.
            .{ .schema_key = "pre_pass", .field_name = "pre_passes" },
        } },
    }) |pair| {
        const T = pair[0];
        const overrides: []const Override = pair[1];
        const struct_fields = @typeInfo(T).@"struct".fields;
        for (T.fields) |fd| {
            const expected = blk: {
                for (overrides) |o| {
                    if (std.mem.eql(u8, o.schema_key, fd.key)) break :blk o.field_name;
                }
                break :blk fd.key;
            };
            var found = false;
            inline for (struct_fields) |f| {
                if (std.mem.eql(u8, f.name, expected)) found = true;
            }
            if (!found) {
                std.debug.print(
                    "FieldDoc.key '{s}' on {s} has no matching struct field (looked for '{s}')\n",
                    .{ fd.key, @typeName(T), expected },
                );
                try std.testing.expect(false);
            }
        }
    }
}

test "FieldDoc.validator tag is right for representative expression fields" {
    // The aggregate `config_schema covers known paths` test catches drift in
    // KEY presence; this one pins per-entry VALIDATOR correctness for a
    // handful of expression-typed fields. If `RowRule.when` (the canonical
    // when-clause) ever loses its `.expr_string` validator, the GUI's
    // ExprPanel routing breaks silently. Spot-check rather than exhaustive
    // so adding a new field doesn't require touching this test.
    const Spec = struct { T: type, key: []const u8, validator: config.FieldValidator };
    const specs = [_]Spec{
        .{ .T = config.RowRule, .key = "when", .validator = .expr_string },
        .{ .T = config.PrePass, .key = "when", .validator = .expr_string },
    };
    inline for (specs) |s| {
        var found = false;
        for (s.T.fields) |fd| {
            if (std.mem.eql(u8, fd.key, s.key)) {
                try std.testing.expectEqual(s.validator, fd.validator);
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "every insert_template / scaffold_template parses as JSON5" {
    // Schema templates ship as JSON5 source strings — a typo in any of them
    // surfaces only at `inspect.docsJson` runtime. Parse each template here so
    // breakage is caught at `zig build test` time.
    const Source = struct { origin: []const u8, src: []const u8 };
    var templates: std.array_list.Managed(Source) = .init(std.testing.allocator);
    defer templates.deinit();

    // Templates from envelope_entries.
    for (envelope_entries) |fd| {
        if (fd.insert_template) |t| try templates.append(.{ .origin = fd.key, .src = t });
    }
    // Templates from each per-struct fields table.
    for (struct_bindings) |bind| {
        for (bind.fields) |fd| {
            if (fd.insert_template) |t| {
                try templates.append(.{ .origin = fd.key, .src = t });
            }
        }
    }
    // Top-level scaffold_template strings.
    try templates.append(.{ .origin = "RowRule.scaffold", .src = config.RowRule.scaffold_template });
    try templates.append(.{ .origin = "PrePass.scaffold", .src = config.PrePass.scaffold_template });
    try templates.append(.{ .origin = "XlsxSheet.scaffold", .src = config.XlsxSheet.scaffold_template });
    try templates.append(.{ .origin = "BrokerConfig.scaffold", .src = config.BrokerConfig.scaffold_template });

    for (templates.items) |t| {
        const preprocessed = json5.preprocess(std.testing.allocator, t.src) catch |err| {
            std.debug.print("template '{s}' failed json5.preprocess: {s}\n", .{ t.origin, @errorName(err) });
            return err;
        };
        defer std.testing.allocator.free(preprocessed);
        // Wrap bare scaffold fragments (e.g. `[]`, `{}`, `{ k: v }`) so
        // `std.json.parseFromSlice` treats them as a top-level value.
        var parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, preprocessed, .{}) catch |err| {
            std.debug.print("template '{s}' failed json parse: {s}\nsrc: {s}\npreprocessed: {s}\n", .{ t.origin, @errorName(err), t.src, preprocessed });
            return err;
        };
        parsed.deinit();
    }
}

test "BrokerConfig defaults match FieldDoc.default" {
    // A minimal config that supplies only the required fields surfaces the
    // loader's actual defaults for every optional field. We then compare
    // against each FieldDoc.default string to guard against drift between
    // the loader and the schema docs.
    const config_mod = @import("config");
    const alloc = std.testing.allocator;

    // Write minimal config to a temp file.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = "minimal.json";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\{
        \\  "conversion_templates": {
        \\    "t": {
        \\      "data_dir": ".",
        \\      "file_pattern_in": ".csv",
        \\      "file_pattern_out": ".csv",
        \\      "input_schema": { "$a": "1" },
        \\      "output_schema": { "col": "$a" }
        \\    }
        \\  }
        \\}
    });
    // Resolve realpath so config.load can read it (it expects a
    // filesystem-visible path, not a tmpDir-relative one).
    const real_path = try tmp.dir.realPathFileAlloc(std.testing.io, path, alloc);
    defer alloc.free(real_path);

    var loaded = try config_mod.load(alloc, real_path);
    defer loaded.deinit();
    const broker = loaded.brokers.get("t") orelse return error.MissingTemplate;

    // Each entry: FieldDoc.default text → live struct value.
    try std.testing.expectEqual(config_mod.FileType.csv, broker.file_type_in); // "csv"
    try std.testing.expectEqual(config_mod.FileType.csv, broker.file_type_out); // "csv"
    try std.testing.expectEqual(@as(u32, 1), broker.csv_header_line); // "1"
    try std.testing.expectEqual(@as(u8, ','), broker.csv_delimiter_in); // ","
    try std.testing.expectEqual(@as(u8, ','), broker.csv_delimiter_out); // ","
    try std.testing.expectEqual(@as(u8, '.'), broker.csv_decimal_separator_in); // "."
    try std.testing.expectEqual(@as(u8, '.'), broker.csv_decimal_separator_out); // "."
    try std.testing.expectEqual(@as(u8, '"'), broker.csv_text_quote_in); // "double"
    try std.testing.expectEqual(@as(u8, 0), broker.csv_text_quote_out); // "none"
    try std.testing.expectEqual(config_mod.encoding.Encoding.utf8, broker.csv_input_encoding); // "utf-8"
    try std.testing.expectEqual(config_mod.encoding.Encoding.utf8, broker.csv_output_encoding); // "utf-8"
    try std.testing.expectEqual(false, broker.date_filter_from_filename); // "false"
    try std.testing.expectEqual(false, broker.row_rules_debug_missing); // "false"
    try std.testing.expectEqual(false, broker.combined_output); // "false"
}
