/// Static documentation emitted by `bxp-fmt --docs`.
/// Single source of truth for bxp-ui's ExprPanel catalog and ConfigTree
/// inline field help. Update in lockstep with expr.zig and config.zig.
const std = @import("std");

// ── Types ─────────────────────────────────────────────────────────────────────

const FnDoc = struct {
    name: []const u8,
    signature: []const u8,
    description: []const u8,
};

const KeywordDoc = struct {
    name: []const u8,
    description: []const u8,
};

const OperatorDoc = struct {
    token: []const u8,
    description: []const u8,
};

const TokenDoc = struct {
    kind: []const u8,
    syntax: []const u8,
    description: []const u8,
};

const FieldDoc = struct {
    key: []const u8,
    type_name: []const u8,
    required: bool,
    default: ?[]const u8,
    description: []const u8,
};

// ── Functions ─────────────────────────────────────────────────────────────────

const functions = [_]FnDoc{
    .{
        .name = "IF",
        .signature = "IF(cond, yes, no)",
        .description = "Short-circuit conditional. Returns `yes` if `cond` is truthy, else `no`.",
    },
    .{
        .name = "ABS",
        .signature = "ABS(f)",
        .description = "Absolute numeric value.",
    },
    .{
        .name = "NOW",
        .signature = "NOW()",
        .description = "Current UTC datetime as ISO 8601 string (YYYY-MM-DDTHH:MM:SSZ).",
    },
    .{
        .name = "TRIM",
        .signature = "TRIM(f)",
        .description = "Strip leading and trailing whitespace from a string.",
    },
    .{
        .name = "ROUND",
        .signature = "ROUND(f, n)",
        .description = "Round `f` to `n` decimal places.",
    },
    .{
        .name = "FLOOR",
        .signature = "FLOOR(f)",
        .description = "Round `f` down to nearest integer.",
    },
    .{
        .name = "CEILING",
        .signature = "CEILING(f)",
        .description = "Round `f` up to nearest integer.",
    },
    .{
        .name = "RAND",
        .signature = "RAND()",
        .description = "Random float in [0, 1).",
    },
    .{
        .name = "COALESCE",
        .signature = "COALESCE(a, b, ...)",
        .description = "First non-empty argument (empty = whitespace-only string). Returns last argument verbatim as fallback.",
    },
    .{
        .name = "DATE_CONVERT",
        .signature = "DATE_CONVERT(f, from, to)",
        .description = "Reformat a date/time string. Format tokens use sunrise syntax (e.g. %Y-%m-%d, %d.%m.%Y, %H:%M:%S).",
    },
    .{
        .name = "PRICE_VALUE",
        .signature = "PRICE_VALUE(f)",
        .description = "Strip currency symbol or code from a price string, return the numeric part.",
    },
    .{
        .name = "PRICE_CURRENCY",
        .signature = "PRICE_CURRENCY(f)",
        .description = "Extract currency code from a price string (e.g. \"EUR\", \"USD\").",
    },
    .{
        .name = "TICKER",
        .signature = "TICKER(f)",
        .description = "Map field value through the template's ticker_map. Returns value unchanged if not found.",
    },
    .{
        .name = "LOOKUP",
        .signature = "LOOKUP(key, field)",
        .description = "Retrieve a value stored by the pre_pass table. `key` is the lookup key; `field` is the $variable name (without $).",
    },
    .{
        .name = "SPLIT_PART",
        .signature = "SPLIT_PART(s, delim, n)",
        .description = "Return the n-th part of `s` split by `delim` (1-based index).",
    },
    .{
        .name = "CONTAINS",
        .signature = "CONTAINS(haystack, needle)",
        .description = "Returns \"true\" if `haystack` contains `needle`, else \"false\".",
    },
    .{
        .name = "REPLACE",
        .signature = "REPLACE(s, from, to)",
        .description = "Replace all occurrences of `from` in `s` with `to`.",
    },
    .{
        .name = "FIELDS",
        .signature = "FIELDS(n)",
        .description = "Field value by 1-based column index (alternative to [ColumnName] when the header is unknown).",
    },
};

// ── Keywords ──────────────────────────────────────────────────────────────────

const keywords = [_]KeywordDoc{
    .{
        .name = "AND",
        .description = "Logical AND. Both operands are evaluated. Returns \"true\" or \"false\".",
    },
    .{
        .name = "OR",
        .description = "Logical OR. Both operands are evaluated. Returns \"true\" or \"false\".",
    },
};

// ── Operators ─────────────────────────────────────────────────────────────────

const operators = [_]OperatorDoc{
    .{ .token = "&",  .description = "String concatenation: \"hello\" & \" \" & \"world\"" },
    .{ .token = "=",  .description = "Equality comparison. Returns \"true\" or \"false\"." },
    .{ .token = "!=", .description = "Inequality comparison." },
    .{ .token = "<",  .description = "Less-than comparison (numeric or lexicographic)." },
    .{ .token = ">",  .description = "Greater-than comparison." },
    .{ .token = "<=", .description = "Less-than-or-equal comparison." },
    .{ .token = ">=", .description = "Greater-than-or-equal comparison." },
    .{ .token = "+",  .description = "Numeric addition." },
    .{ .token = "-",  .description = "Numeric subtraction." },
    .{ .token = "*",  .description = "Numeric multiplication." },
    .{ .token = "/",  .description = "Numeric division." },
};

// ── Tokens ────────────────────────────────────────────────────────────────────

const tokens = [_]TokenDoc{
    .{
        .kind = "columnRef",
        .syntax = "[ColumnName]",
        .description = "Input CSV column value by header name. Case-sensitive.",
    },
    .{
        .kind = "inputVar",
        .syntax = "$variable",
        .description = "Named variable declared in input_schema. Must start with $.",
    },
    .{
        .kind = "string",
        .syntax = "'single quoted'",
        .description = "String literal. Escape with \\' for embedded quote.",
    },
    .{
        .kind = "number",
        .syntax = "123 / 3.14",
        .description = "Numeric literal. Decimals supported. American thousands separators (1,234.56) parsed automatically.",
    },
    .{
        .kind = "function",
        .syntax = "FUNCNAME(...)",
        .description = "Built-in function call. See function list below.",
    },
    .{
        .kind = "keyword",
        .syntax = "AND / OR",
        .description = "Logical keyword operators.",
    },
};

// ── Config schema ─────────────────────────────────────────────────────────────

const schema = [_]FieldDoc{
    // Top-level
    .{
        .key = "ticker_maps",
        .type_name = "object",
        .required = false,
        .default = null,
        .description = "Named ticker remapping tables. Each entry: map_name -> { broker_symbol: yahoo_symbol }. Referenced by templates via ticker_map: map_name.",
    },
    .{
        .key = "conversion_templates",
        .type_name = "object",
        .required = true,
        .default = null,
        .description = "Map of template_id -> broker config. Each key is a unique template identifier used with --template flag.",
    },
    // Template fields
    .{
        .key = "conversion_templates.*.data_dir",
        .type_name = "string",
        .required = true,
        .default = null,
        .description = "Path to input files, relative to this config file. e.g. \"my_broker\" or \"../data/broker\".",
    },
    .{
        .key = "conversion_templates.*.file_type_in",
        .type_name = "string",
        .required = false,
        .default = "csv",
        .description = "Input file format. Options: \"csv\" | \"json\" (array-of-objects).",
    },
    .{
        .key = "conversion_templates.*.file_type_out",
        .type_name = "string",
        .required = false,
        .default = "csv",
        .description = "Output file format. Options: \"csv\" | \"json\".",
    },
    .{
        .key = "conversion_templates.*.file_pattern_in",
        .type_name = "string",
        .required = true,
        .default = null,
        .description = "Suffix filter for input files in data_dir. e.g. \".csv\" (all), \"_cash.csv\" (specific suffix).",
    },
    .{
        .key = "conversion_templates.*.file_pattern_out",
        .type_name = "string",
        .required = true,
        .default = null,
        .description = "Output filename suffix. Replaces file_pattern_in in the output filename.",
    },
    .{
        .key = "conversion_templates.*.header_row",
        .type_name = "number",
        .required = false,
        .default = "1",
        .description = "1-based row number that contains the column headers.",
    },
    .{
        .key = "conversion_templates.*.csv_separator_in",
        .type_name = "string",
        .required = false,
        .default = ",",
        .description = "Input CSV field separator character.",
    },
    .{
        .key = "conversion_templates.*.csv_separator_out",
        .type_name = "string",
        .required = false,
        .default = ",",
        .description = "Output CSV field separator character.",
    },
    .{
        .key = "conversion_templates.*.csv_text_quote_in",
        .type_name = "string",
        .required = false,
        .default = "none",
        .description = "Input CSV text quoting style. Options: \"none\" | \"single\" | \"double\". Use ''' in expressions for a literal single-quote.",
    },
    .{
        .key = "conversion_templates.*.csv_text_quote_out",
        .type_name = "string",
        .required = false,
        .default = "none",
        .description = "Output CSV text quoting style. Options: \"none\" | \"single\" | \"double\".",
    },
    .{
        .key = "conversion_templates.*.ticker_map",
        .type_name = "string | object",
        .required = false,
        .default = null,
        .description = "Ticker remapping for this template. String = reference to a named ticker_maps entry. Object = inline map { broker_symbol: yahoo_symbol }.",
    },
    .{
        .key = "conversion_templates.*.date_filter_from_filename",
        .type_name = "boolean",
        .required = false,
        .default = "false",
        .description = "If true, extracts a date from the input filename and exposes it as $date in input_schema.",
    },
    .{
        .key = "conversion_templates.*.row_rules_debug_missing",
        .type_name = "boolean",
        .required = false,
        .default = "false",
        .description = "If true, rows that match no row_rules entry are printed in --debug output.",
    },
    .{
        .key = "conversion_templates.*.input_schema",
        .type_name = "object",
        .required = true,
        .default = null,
        .description = "Map of $variable -> expression. Each expression is evaluated per input row. Variables are referenced in output_schema and row_rules.",
    },
    .{
        .key = "conversion_templates.*.input_schema.*",
        .type_name = "expression",
        .required = true,
        .default = null,
        .description = "Expression evaluated per input row. Result stored in the $variable. Use [ColumnName] to reference input CSV columns.",
    },
    .{
        .key = "conversion_templates.*.output_schema",
        .type_name = "array",
        .required = true,
        .default = null,
        .description = "Ordered list of output columns. Each entry: { header: string, variable: $var }. Column order in output matches this array.",
    },
    .{
        .key = "conversion_templates.*.output_schema.*.header",
        .type_name = "string",
        .required = true,
        .default = null,
        .description = "Output CSV column header name.",
    },
    .{
        .key = "conversion_templates.*.output_schema.*.variable",
        .type_name = "string",
        .required = true,
        .default = null,
        .description = "Input schema $variable whose evaluated value fills this output column.",
    },
    .{
        .key = "conversion_templates.*.row_rules",
        .type_name = "array",
        .required = false,
        .default = null,
        .description = "Ordered list of output row rules. First matching rule produces the output rows. Rows matching no rule are silently skipped.",
    },
    .{
        .key = "conversion_templates.*.row_rules.*.when",
        .type_name = "expression",
        .required = true,
        .default = null,
        .description = "Condition expression. Rule applies when this evaluates to truthy (non-empty, non-zero, non-\"false\").",
    },
    .{
        .key = "conversion_templates.*.row_rules.*.rows",
        .type_name = "array",
        .required = true,
        .default = null,
        .description = "Output rows produced when `when` matches. Each entry is an object mapping $variable -> expression override.",
    },
    .{
        .key = "conversion_templates.*.pre_pass",
        .type_name = "object",
        .required = false,
        .default = null,
        .description = "First-pass lookup table configuration. Reads all input rows first, builds a keyed table, then expressions can call LOOKUP(key, field) in the main pass.",
    },
    .{
        .key = "conversion_templates.*.pre_pass.key",
        .type_name = "expression",
        .required = true,
        .default = null,
        .description = "Expression evaluated per row in the pre-pass to produce the lookup key string.",
    },
    .{
        .key = "conversion_templates.*.pre_pass.when",
        .type_name = "expression",
        .required = false,
        .default = null,
        .description = "Optional condition. Row is only included in the lookup table when this evaluates to truthy.",
    },
    .{
        .key = "conversion_templates.*.pre_pass.fields",
        .type_name = "object",
        .required = true,
        .default = null,
        .description = "Map of field_name -> expression. Values stored per key for retrieval via LOOKUP(key, field).",
    },
    .{
        .key = "conversion_templates.*.pre_pass.fields.*",
        .type_name = "expression",
        .required = true,
        .default = null,
        .description = "Expression evaluated per pre-pass row. Result stored under the field name for LOOKUP retrieval.",
    },
};

// ── Serializer ────────────────────────────────────────────────────────────────

pub fn writeDocs(writer: *std.Io.Writer) !void {
    var jw: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };

    try jw.beginObject();

    // functions
    try jw.objectField("functions");
    try jw.beginArray();
    for (functions) |f| {
        try jw.beginObject();
        try jw.objectField("name");        try jw.write(f.name);
        try jw.objectField("signature");   try jw.write(f.signature);
        try jw.objectField("description"); try jw.write(f.description);
        try jw.endObject();
    }
    try jw.endArray();

    // keywords
    try jw.objectField("keywords");
    try jw.beginArray();
    for (keywords) |k| {
        try jw.beginObject();
        try jw.objectField("name");        try jw.write(k.name);
        try jw.objectField("description"); try jw.write(k.description);
        try jw.endObject();
    }
    try jw.endArray();

    // operators
    try jw.objectField("operators");
    try jw.beginArray();
    for (operators) |op| {
        try jw.beginObject();
        try jw.objectField("token");       try jw.write(op.token);
        try jw.objectField("description"); try jw.write(op.description);
        try jw.endObject();
    }
    try jw.endArray();

    // tokens
    try jw.objectField("tokens");
    try jw.beginArray();
    for (tokens) |tok| {
        try jw.beginObject();
        try jw.objectField("kind");        try jw.write(tok.kind);
        try jw.objectField("syntax");      try jw.write(tok.syntax);
        try jw.objectField("description"); try jw.write(tok.description);
        try jw.endObject();
    }
    try jw.endArray();

    // config_schema
    try jw.objectField("config_schema");
    try jw.beginArray();
    for (schema) |f| {
        try jw.beginObject();
        try jw.objectField("key");         try jw.write(f.key);
        try jw.objectField("type_name");   try jw.write(f.type_name);
        try jw.objectField("required");    try jw.write(f.required);
        try jw.objectField("default");
        if (f.default) |d| try jw.write(d) else try jw.write(null);
        try jw.objectField("description"); try jw.write(f.description);
        try jw.endObject();
    }
    try jw.endArray();

    try jw.endObject();
    try writer.writeByte('\n');
}
