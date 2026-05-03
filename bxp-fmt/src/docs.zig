/// Static documentation emitted by `bxp-fmt --docs`.
///
/// FnDoc / OperatorDoc / KeywordDoc / TokenDoc tables are owned by
/// `bxp-core/src/expr.zig` (the catalog section near the bottom). Anything
/// the GUI needs about the expression language must originate there — this
/// file just re-exports those tables and serializes them to JSON together
/// with the config-schema FieldDoc[].
const std = @import("std");
const expr = @import("expr");
const json5 = @import("json5");

const FnDoc = expr.FnDoc;
const KeywordDoc = expr.KeywordDoc;
const OperatorDoc = expr.OperatorDoc;
const TokenDoc = expr.TokenDoc;

// Function list flattened from expr.builtins.
const functions = blk: {
    var arr: [expr.builtins.len]FnDoc = undefined;
    for (expr.builtins, 0..) |b, i| arr[i] = b.doc;
    break :blk arr;
};
const keywords = expr.keywords;
const operators = expr.operators;
const tokens = expr.tokens;

/// FieldDoc — one entry per JSON path in the config schema.
///
/// `key` uses dot-paths with `*` standing in for any object key (e.g.
/// `"conversion_templates.*.data_dir"` matches every template).
/// `enum_values` is non-null only when the field accepts a closed set of
/// strings (e.g. csv_text_quote_in: "none" | "single" | "double") — the GUI
/// can render a dropdown and validate values against this list.
/// `ordered` is true only for arrays/maps where document order has semantic
/// meaning (row_rules: first match wins; output_schema: column order in
/// output CSV) — the GUI uses it to gate ↑/↓ reorder buttons.
///
/// `insert_order` (Phase 5f) controls where the GUI places a new key when
/// inserting into THIS object: "schema" = match the canonical declaration
/// order in the `schema` array below; "alpha" = alphabetical by key;
/// "append" (or null) = end of object. Arrays always append.
///
/// `insert_template` (Phase 5f) is a JSON5 snippet used as the scaffold
/// when the GUI inserts a new value MATCHING this FieldDoc. The string is
/// preprocessed via bxp_core's json5 module at `writeDocs` time and
/// emitted as a nested JSON value, so the Dart consumer reads it directly
/// from `--docs` JSON without needing its own JSON5 parser.
const FieldDoc = struct {
    key: []const u8,
    type_name: []const u8,
    required: bool,
    default: ?[]const u8,
    description: []const u8,
    enum_values: ?[]const []const u8 = null,
    ordered: bool = false,
    insert_order: ?[]const u8 = null,
    insert_template: ?[]const u8 = null,
};

// ── Config schema ─────────────────────────────────────────────────────────────
//
// Authoritative source for these entries: bxp-core/src/config.zig (parsed
// keys) cross-checked with resources/bxp-cli.examples.json (rich inline
// comments giving defaults and option lists). When the two disagree, the
// examples file wins for description/options text — the user maintains it
// actively — and config.zig wins for required/default/type.

const file_type_values = [_][]const u8{ "csv", "json" };
const csv_quote_values = [_][]const u8{ "none", "single", "double" };
const csv_delimiter_values = [_][]const u8{ ",", ";", "\t", "|" };
const csv_decimal_values = [_][]const u8{ ".", "," };

// ── Phase 5f insert templates ─────────────────────────────────────────────────
//
// JSON5 source-side; preprocessed via bxp_core's json5 module at writeDocs
// time and emitted as nested JSON values in the --docs payload.

const template_broker_scaffold =
    \\{
    \\  data_dir: ".",
    \\  file_type_in: "csv",
    \\  file_pattern_in: ".csv",
    \\  file_pattern_out: ".csvx",
    \\  csv_delimiter_in: ",",
    \\  csv_delimiter_out: ",",
    \\  csv_decimal_separator_in: ".",
    \\  csv_decimal_separator_out: ".",
    \\  csv_text_quote_in: "double",
    \\  csv_text_quote_out: "none",
    \\  input_schema: {
    \\    $date: "",
    \\    $ticker: "",
    \\    $quantity: "",
    \\    $unitprice: "",
    \\    $currency: "",
    \\    $fee: "",
    \\    $amount: "",
    \\    $account: ""
    \\  },
    \\  row_rules: [
    \\    { when: "true", rows: [ { $action: "'DEPOSIT'" } ] }
    \\  ],
    \\  output_schema: {
    \\    date: "$date",
    \\    symbol: "$ticker",
    \\    quantity: "$quantity",
    \\    activityType: "$action",
    \\    unitPrice: "$unitprice",
    \\    currency: "$currency",
    \\    fee: "$fee",
    \\    amount: "$amount",
    \\    account: "$account"
    \\  }
    \\}
;

const template_ticker_map =
    \\{ BROKER_SYMBOL: "YAHOO_SYMBOL" }
;

const template_xlsx_sheet =
    \\{ name: "SHEET_NAME", header_row: 1 }
;

const template_input_schema =
    \\{ $variable1: "value1" }
;

const template_output_schema =
    \\{ column1: "$variable1" }
;

const template_row_rule =
    \\{ when: "[column1] = 'test-condition1'", rows: [ { $action: "'DEPOSIT'" } ] }
;

const template_pre_pass_legacy =
    \\{
    \\  when: "[column1] = 'stock buy order detail'",
    \\  key: "[order-id]",
    \\  values: {
    \\    amount: "ABS([amount])",
    \\    currency: "[currency]"
    \\  }
    \\}
;

const template_pre_pass_named =
    \\{
    \\  when: "[column1] = 'stock buy order detail'",
    \\  key: "[order-id]",
    \\  values: {
    \\    amount: "ABS([amount])",
    \\    currency: "[currency]"
    \\  }
    \\}
;

const schema = [_]FieldDoc{
    // ── Top-level ───────────────────────────────────────────────────────────
    .{
        .key = "ticker_maps",
        .type_name = "object",
        .required = false,
        .default = null,
        .description = "Named ticker remapping tables. Each entry: map_name -> { broker_symbol: yahoo_symbol }. Referenced by templates via ticker_map: map_name.",
        .insert_order = "alpha",
        .insert_template = "{}",
    },
    .{
        .key = "ticker_maps.*",
        .type_name = "object",
        .required = false,
        .default = null,
        .description = "One named ticker map. Keys are broker symbols, values are the remapped target symbols (typically Yahoo Finance tickers).",
        .insert_order = "alpha",
        .insert_template = template_ticker_map,
    },
    .{
        .key = "conversion_templates",
        .type_name = "object",
        .required = true,
        .default = null,
        .description = "Map of template_id -> broker config. Each key is a unique template identifier used with --template flag. When bxp-cli runs without --template, all templates execute in declaration order.",
        .ordered = true,
        .insert_order = "append",
        .insert_template = "{}",
    },
    .{
        // Phase 5f: per-template wildcard. The `insert_template` here is
        // the scaffold used when the user adds a NEW template under
        // `conversion_templates` (e.g. `conversion_templates.my_broker`).
        // The `insert_order: schema` governs how new keys land INSIDE an
        // existing template (data_dir before file_type_in before …).
        .key = "conversion_templates.*",
        .type_name = "object",
        .required = false,
        .default = null,
        .description = "One conversion template — see `conversion_templates.*.*` fields for contents.",
        .insert_order = "schema",
        .insert_template = template_broker_scaffold,
    },

    // ── Template fields ─────────────────────────────────────────────────────
    .{
        .key = "conversion_templates.*.data_dir",
        .type_name = "string",
        .required = true,
        .default = null,
        .description = "Path to input files, relative to this config file. e.g. \"my_broker\", \"../data/broker\", or an absolute path.",
    },
    .{
        .key = "conversion_templates.*.file_type_in",
        .type_name = "string",
        .required = false,
        .default = "csv",
        .description = "Input file format. \"json\" reads an array-of-objects.",
        .enum_values = &file_type_values,
    },
    .{
        .key = "conversion_templates.*.file_type_out",
        .type_name = "string",
        .required = false,
        .default = "csv",
        .description = "Output file format. \"json\" writes an array-of-objects.",
        .enum_values = &file_type_values,
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
        .key = "conversion_templates.*.csv_delimiter_in",
        .type_name = "string",
        .required = false,
        .default = ",",
        .description = "Input CSV field separator (single character).",
        .enum_values = &csv_delimiter_values,
    },
    .{
        .key = "conversion_templates.*.csv_delimiter_out",
        .type_name = "string",
        .required = false,
        .default = ",",
        .description = "Output CSV field separator (single character).",
        .enum_values = &csv_delimiter_values,
    },
    .{
        .key = "conversion_templates.*.csv_decimal_separator_in",
        .type_name = "string",
        .required = false,
        .default = ".",
        .description = "Decimal separator in input numeric fields. Set to \",\" for European-style CSV. Must differ from csv_delimiter_in.",
        .enum_values = &csv_decimal_values,
    },
    .{
        .key = "conversion_templates.*.csv_decimal_separator_out",
        .type_name = "string",
        .required = false,
        .default = ".",
        .description = "Decimal separator written in numeric output fields.",
        .enum_values = &csv_decimal_values,
    },
    .{
        .key = "conversion_templates.*.csv_text_quote_in",
        .type_name = "string",
        .required = false,
        .default = "double",
        .description = "Input CSV text quoting style. Use ''' in expressions for a literal single-quote.",
        .enum_values = &csv_quote_values,
    },
    .{
        .key = "conversion_templates.*.csv_text_quote_out",
        .type_name = "string",
        .required = false,
        .default = "none",
        .description = "Output CSV text quoting style.",
        .enum_values = &csv_quote_values,
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
        .description = "When true, rows whose $date falls outside the date range encoded in the filename (YYYY-MM-DD_YYYY-MM-DD) are silently skipped. Requires $date in input_schema.",
    },
    .{
        .key = "conversion_templates.*.row_rules_debug_missing",
        .type_name = "boolean",
        .required = false,
        .default = "false",
        .description = "When true, rows that match no row_rules entry are printed in --debug output.",
    },

    // ── xlsx_sheet (only present for xlsx-input templates) ──────────────────
    .{
        .key = "conversion_templates.*.xlsx_sheet",
        .type_name = "object",
        .required = false,
        .default = null,
        .description = "When set, the xlsx file in data_dir is converted to an intermediate CSV before the normal CSV processing loop.",
        .insert_order = "schema",
        .insert_template = template_xlsx_sheet,
    },
    .{
        .key = "conversion_templates.*.xlsx_sheet.name",
        .type_name = "string",
        .required = true,
        .default = null,
        .description = "Sheet name as it appears in the xlsx workbook (e.g. \"CASH OPERATION\").",
    },
    .{
        .key = "conversion_templates.*.xlsx_sheet.header_row",
        .type_name = "number",
        .required = false,
        .default = "1",
        .description = "1-based row number that contains the column headers within this sheet.",
    },
    .{
        .key = "conversion_templates.*.xlsx_sheet.output_suffix",
        .type_name = "string",
        .required = false,
        .default = "",
        .description = "Appended before \".csv\" in the intermediate filename (e.g. \"_3\").",
    },

    // ── input_schema ────────────────────────────────────────────────────────
    .{
        .key = "conversion_templates.*.input_schema",
        .type_name = "object",
        .required = true,
        .default = null,
        .description = "Map of $variable -> expression. Each expression is evaluated per input row. Variables are referenced in output_schema and row_rules. Iteration order does not affect results.",
        .insert_order = "append",
        .insert_template = template_input_schema,
    },
    .{
        .key = "conversion_templates.*.input_schema.*",
        .type_name = "expression",
        .required = true,
        .default = null,
        .description = "Expression evaluated per input row. Result stored in the $variable. Use [ColumnName] to reference input CSV columns.",
    },

    // ── output_schema (object: header -> $variable) ─────────────────────────
    .{
        .key = "conversion_templates.*.output_schema",
        .type_name = "object",
        .required = true,
        .default = null,
        .description = "Output CSV column headers mapped to $variable values. Insertion order determines column order in the output file.",
        .ordered = true,
        .insert_order = "append",
        .insert_template = template_output_schema,
    },
    .{
        .key = "conversion_templates.*.output_schema.*",
        .type_name = "string",
        .required = true,
        .default = null,
        .description = "$variable whose evaluated value fills this output column. Must start with $.",
        .insert_template = "\"$variable\"",
    },

    // ── row_rules (ordered: first match wins) ───────────────────────────────
    .{
        .key = "conversion_templates.*.row_rules",
        .type_name = "array",
        .required = false,
        .default = null,
        .description = "Ordered list of conditional routing rules. The first rule whose `when` matches produces the output rows; later rules are not evaluated. Rows matching no rule are silently skipped (or shown via row_rules_debug_missing).",
        .ordered = true,
        .insert_template = "[]",
    },
    .{
        // Phase 5f: array element wildcard. Carries the canonical scaffold
        // for "add a new row_rules entry" and declares schema-order for the
        // rule's child keys (when, rows).
        .key = "conversion_templates.*.row_rules.*",
        .type_name = "object",
        .required = false,
        .default = null,
        .description = "One row rule. Schema-ordered children: `when` (condition), `rows` (output rows produced when matched).",
        .insert_order = "schema",
        .insert_template = template_row_rule,
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
        .description = "Output rows produced when `when` matches. Each entry is an object overriding $variables; rows: [] silently skips the row, rows: [{}] emits one row using input_schema variables verbatim.",
        .insert_template = "[{}]",
    },
    .{
        .key = "conversion_templates.*.row_rules.*.rows.*",
        .type_name = "object",
        .required = false,
        .default = null,
        .description = "One output row. Map of $variable -> expression overriding the value from input_schema. Empty object {} = take all values verbatim from input_schema.",
        .insert_order = "append",
        .insert_template = "{}",
    },

    // ── pre_pass (first-pass lookup table) ──────────────────────────────────
    .{
        .key = "conversion_templates.*.pre_pass",
        .type_name = "object",
        .required = false,
        .default = null,
        .description = "First-pass lookup table(s) built before the main loop. Two accepted shapes: legacy single block `{ when, key, values }` (detected by the presence of `when`) — accessed via 2-arg `LOOKUP(key, 'field')`; or named blocks `{ name1: { when, key, values }, ... }` — each block is its own namespace, accessed via 3-arg `LOOKUP('name', key, 'field')`.",
        .insert_template = template_pre_pass_legacy,
    },
    .{
        .key = "conversion_templates.*.pre_pass.when",
        .type_name = "expression",
        .required = true,
        .default = null,
        .description = "Legacy single-block form. Filter — only rows matching this condition are added to the lookup table.",
    },
    .{
        .key = "conversion_templates.*.pre_pass.key",
        .type_name = "expression",
        .required = true,
        .default = null,
        .description = "Legacy single-block form. Expression evaluated per row to produce the lookup key string.",
    },
    .{
        .key = "conversion_templates.*.pre_pass.values",
        .type_name = "object",
        .required = true,
        .default = null,
        .description = "Legacy single-block form. Map of field_name -> expression. Each value is evaluated per pre-pass row and stored for retrieval via LOOKUP(key, 'field_name'). Field names have no $ prefix.",
        .insert_order = "append",
    },
    .{
        .key = "conversion_templates.*.pre_pass.values.*",
        .type_name = "expression",
        .required = true,
        .default = null,
        .description = "Expression evaluated per pre-pass row. Result stored under the field name for LOOKUP retrieval.",
    },
    .{
        .key = "conversion_templates.*.pre_pass.*",
        .type_name = "object",
        .required = false,
        .default = null,
        .description = "Named pre_pass block. The map key is the block name and becomes part of the LOOKUP namespace; different names cannot collide.",
        .insert_order = "schema",
        .insert_template = template_pre_pass_named,
    },
    .{
        .key = "conversion_templates.*.pre_pass.*.when",
        .type_name = "expression",
        .required = true,
        .default = null,
        .description = "Filter — only rows matching this condition are added to the named lookup table.",
    },
    .{
        .key = "conversion_templates.*.pre_pass.*.key",
        .type_name = "expression",
        .required = true,
        .default = null,
        .description = "Expression evaluated per row to produce the lookup key string for this named block.",
    },
    .{
        .key = "conversion_templates.*.pre_pass.*.values",
        .type_name = "object",
        .required = true,
        .default = null,
        .description = "Map of field_name -> expression evaluated per pre-pass row, retrieved via 3-arg LOOKUP('name', key, 'field_name').",
        .insert_order = "append",
    },
    .{
        .key = "conversion_templates.*.pre_pass.*.values.*",
        .type_name = "expression",
        .required = true,
        .default = null,
        .description = "Expression evaluated per pre-pass row. Result stored under the field name for LOOKUP retrieval.",
    },
};

// ── Serializer ────────────────────────────────────────────────────────────────

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

    // config_schema
    try jw.objectField("config_schema");
    try jw.beginArray();
    for (schema) |f| {
        try jw.beginObject();
        try jw.objectField("key");
        try jw.write(f.key);
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
            // JSON5 (source-side) → JSON → std.json.Value → emit nested.
            // Failures here surface as build/runtime errors during
            // `bxp-fmt --docs`, catching template typos at CI time.
            const json_bytes = try json5.preprocess(alloc, snippet);
            defer alloc.free(json_bytes);
            var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{});
            defer parsed.deinit();
            try jw.write(parsed.value);
        } else {
            try jw.write(null);
        }
        try jw.endObject();
    }
    try jw.endArray();

    try jw.endObject();
    try writer.writeByte('\n');
}
