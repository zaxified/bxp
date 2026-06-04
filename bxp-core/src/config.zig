/// Configuration types and JSON loader for bxp.
///
/// Reads bxp-cli.json from the current working directory and populates the Config
/// struct.  All heap memory is owned by Config and released via Config.deinit().
/// If bxp-cli.json does not exist the loader returns an empty Config (no error).
///
/// xlsx support:
///   Templates with "xlsx_sheet" in their config have their xlsx files converted
///   to intermediate CSV files before the normal CSV processing loop runs.
///   "file_pattern_in" restricts which CSV files a template processes (suffix match).

const std = @import("std");
const json5 = @import("json5.zig");
const diagnostics = @import("diagnostics");
const expr = @import("expr");

pub const Diagnostic = diagnostics.Diagnostic;
pub const Diagnostics = diagnostics.Diagnostics;
pub const Severity = diagnostics.Severity;

const CONFIG_MAX_FILE_SIZE: usize = 1024 * 1024;

/// Per-field documentation entry. Co-located with the config struct it
/// describes (search for `pub const fields` below); aggregated and
/// serialized by `bxp-core/src/docs.zig` as the `config_schema` array
/// inside `bxp-fmt --docs` output.
///
/// `key` is the dotted path segment for this entry. Per-struct tables
/// hold the local field name (e.g. "data_dir"); the docs aggregator
/// prepends the binding prefix (e.g. "conversion_templates.*") when
/// flattening. Top-level envelope entries declared directly in docs.zig
/// store the full path here.
///
/// `insert_order` (Phase 5f) controls how the GUI orders new keys when
/// inserting INTO this object: "schema" = match this `fields` table's
/// declaration order; "alpha" = alphabetical; "append" (or null) = end
/// of object. Arrays always append.
///
/// `insert_template` (Phase 5f) is a JSON5 snippet used as the scaffold
/// when the GUI inserts a new value matching this entry. The string is
/// preprocessed to JSON via bxp-core's json5 module at serialize time
/// and emitted as a nested JSON value.
/// Per-field semantic validator. Default `none` means "no special
/// check"; specialized values drive the bxp-gui Dart-side tree
/// validator + per-edit feedback. Pure metadata today — no Zig
/// validator dispatches per `validator` (the existing per-struct
/// `BrokerConfig.validate` and friends remain hardcoded; adding Zig
/// dispatch is a follow-up). Adding a kind = add an enum variant +
/// populate relevant FieldDoc entries; bxp-gui consumes via
/// `bxp-fmt --docs`.
pub const FieldValidator = enum {
    /// No special check.
    none,
    /// String value must be non-empty (whitespace-only also empty).
    non_empty,
    /// String must start with `$` (input_schema $variable references).
    starts_with_dollar,
    /// Value is an expression — Dart routes to ExprPanel autocomplete
    /// + delegates static checks to the FnArgDoc-driven path.
    expr_string,
};

/// Per-field autocomplete data source used by the bxp-gui editors.
/// Default `none` means "no source-specific suggestions"; specialized
/// values name a live source (current AST, dry-run cache, top-level
/// keys) the GUI cross-references at edit time.
pub const AutocompleteSource = enum {
    none,
    /// Suggest names of pre_pass blocks declared in the active
    /// template's `pre_pass` map.
    pre_pass_names,
    /// Suggest $variable identifiers declared in the active template's
    /// `input_schema` map (e.g. for `output_schema.*` values).
    input_schema_keys,
    /// Suggest top-level `ticker_maps` entry names (e.g. for the
    /// `ticker_map` field's string form).
    ticker_map_names,
    /// Suggest CSV header names cached from the most recent dry-run
    /// `file_start` event (per active template).
    csv_headers_via_dryrun,
    /// Reuse the FieldDoc.enum_values list as the suggestion source.
    /// Marker for the GUI; today already inferred from `enum_values`.
    enum_values,
};

pub const FieldDoc = struct {
    key: []const u8,
    type_name: []const u8,
    required: bool,
    default: ?[]const u8 = null,
    description: []const u8,
    enum_values: ?[]const []const u8 = null,
    ordered: bool = false,
    insert_order: ?[]const u8 = null,
    insert_template: ?[]const u8 = null,
    /// Phase 1b — Dart-side per-edit validator hint. Default `.none`
    /// preserves the historical "no check" behavior.
    validator: FieldValidator = .none,
    /// Phase 1b — Dart-side autocomplete source hint. Default `.none`
    /// preserves the historical "no per-field suggestions" behavior.
    autocomplete: AutocompleteSource = .none,
};

/// Per-row variable overrides produced by a row rule.
/// Keys are variable names; values are expression strings evaluated against raw fields.
pub const RowOverride = std.StringHashMap([]const u8);

/// A conditional row routing rule.
/// When `when` evaluates to true, the row is replaced by one output row per entry
/// in `rows`.  An empty `rows` slice silently skips the row.
pub const RowRule = struct {
    /// Boolean expression evaluated against the current row's raw fields.
    when: []const u8,
    /// Variable override maps — one per desired output row.  Empty = skip row.
    rows: []RowOverride,

    /// Schema docs for this struct's fields. Bound at
    /// `conversion_templates.*.row_rules.*` by `bxp-core/src/docs.zig`.
    pub const fields = [_]FieldDoc{
        .{
            .key = "when",
            .type_name = "expression",
            .required = true,
            .description = "Condition expression. Rule applies when this evaluates to truthy (non-empty, non-zero, non-\"false\").",
            .validator = .expr_string,
        },
        .{
            .key = "rows",
            .type_name = "array",
            .required = true,
            .description = "Output rows produced when `when` matches. Each entry is an object overriding $variables; rows: [] silently skips the row, rows: [{}] emits one row using input_schema variables verbatim.",
            .insert_template = "[{}]",
        },
    };

    /// JSON5 scaffold the GUI inserts for a new `row_rules` entry.
    pub const scaffold_template =
        \\{ when: "[column1] = 'test-condition1'", rows: [ { $action: "'DEPOSIT'" } ] }
    ;
};

/// Optional first-pass lookup table configuration.
///
/// Before the main processing loop, all rows in the input file are scanned.
/// Rows where when evaluates to true are collected; for each such row
/// the key expression is evaluated to obtain a lookup key, and every entry in
/// values is stored in a flat table under the composite key "key\x00field_name".
/// Expressions in input_schema can then retrieve these values with LOOKUP(key, field).
pub const PrePass = struct {
    /// Expression evaluated for every row; the row is collected only when truthy.
    when: []const u8,
    /// Expression that produces the string lookup key for the collected row.
    key: []const u8,
    /// Maps field names to expressions evaluated for each collected row.
    values: std.StringHashMap([]const u8),

    /// Schema docs for the named-block form. Bound at
    /// `conversion_templates.*.pre_pass.*` by `bxp-core/src/docs.zig`.
    /// Legacy single-block (`pre_pass.when` / `pre_pass.key` / `pre_pass.values`)
    /// is documented as separate envelope entries in docs.zig.
    pub const fields = [_]FieldDoc{
        .{
            .key = "when",
            .type_name = "expression",
            .required = true,
            .description = "Filter — only rows matching this condition are added to the named lookup table.",
            .validator = .expr_string,
        },
        .{
            .key = "key",
            .type_name = "expression",
            .required = true,
            .description = "Expression evaluated per row to produce the lookup key string for this named block.",
            .validator = .expr_string,
        },
        .{
            .key = "values",
            .type_name = "object",
            .required = true,
            .description = "Map of field_name -> expression evaluated per pre-pass row, retrieved via 3-arg LOOKUP('name', key, 'field_name').",
            .insert_order = "append",
        },
    };

    /// JSON5 scaffold the GUI inserts for a new named pre_pass block.
    pub const scaffold_template =
        \\{
        \\  when: "[column1] = 'stock buy order detail'",
        \\  key: "[order-id]",
        \\  values: {
        \\    amount: "ABS([amount])",
        \\    currency: "[currency]"
        \\  }
        \\}
    ;
};

/// One column in the output CSV.
/// The header string becomes the column header; variable names a key in
/// the evaluated input_schema map.  Column order in output_schema determines
/// the column order in the output file.
pub const OutputColumn = struct {
    header: []const u8,   // output CSV column header
    variable: []const u8, // input_schema variable whose value fills this column
};

/// Input/output file format for a conversion template.
pub const FileType = enum {
    /// Delimited text (CSV/TSV).  Default.
    csv,
    /// JSON array-of-objects.
    json,
};

/// Specifies one xlsx sheet to extract to an intermediate CSV file.
/// Mirrors xlsx.SheetSpec but is owned by Config (heap-allocated strings).
pub const XlsxSheet = struct {
    /// Sheet name as it appears in the xlsx workbook (e.g. "CASH OPERATION").
    name: []const u8,
    /// 1-based row number that contains the column headers.
    header_row: u32,
    /// Appended before ".csv" in the output filename (e.g. "_3").
    output_suffix: []const u8,

    /// Schema docs for this struct's fields. Bound at
    /// `conversion_templates.*.xlsx_sheet` by `bxp-core/src/docs.zig`.
    /// All three keys are required — the loader treats `xlsx_sheet` as
    /// all-or-nothing; any missing/wrong-typed sub-key silently aborts
    /// xlsx parsing for the whole template.
    pub const fields = [_]FieldDoc{
        .{
            .key = "name",
            .type_name = "string",
            .required = true,
            .description = "Sheet name as it appears in the xlsx workbook (e.g. \"CASH OPERATION\").",
            .validator = .non_empty,
        },
        .{
            .key = "header_row",
            .type_name = "number",
            .required = true,
            .description = "1-based row number that contains the column headers within this sheet.",
        },
        .{
            .key = "output_suffix",
            .type_name = "string",
            .required = true,
            .description = "Appended before \".csv\" in the intermediate filename (e.g. \"_3\"). Use \"\" for no suffix.",
        },
    };

    /// JSON5 scaffold the GUI inserts for a new `xlsx_sheet` block.
    pub const scaffold_template =
        \\{ name: "SHEET_NAME", header_row: 1 }
    ;
};

/// Per-template configuration loaded from a single entry inside "conversion_templates" in bxp-cli.json.
pub const BrokerConfig = struct {
    /// Path to the directory containing input CSV files for this broker.
    data_dir: []const u8,
    /// Maps broker symbol names to Yahoo Finance tickers, e.g. "BTC" -> "BTC-USD".
    ticker_map: std.StringHashMap([]const u8),
    /// Variable definitions evaluated per row: name → expression string.
    /// Required — must not be empty.  "@date" is required when date_filter_from_filename is true.
    /// `StringArrayHashMap` (not `StringHashMap`): preserves JSON5
    /// declaration order so `var_eval` trace events emit in the same
    /// order as the user wrote them — the bxp-gui row-transform
    /// `variables` table relies on this for deterministic display.
    input_schema: std.StringArrayHashMap([]const u8),
    /// When non-empty, only CSV files whose name ends with this suffix are processed.
    /// Example: "_3.csv" processes only files like "account_..._3.csv".
    file_pattern_in: []const u8,
    /// Output filename suffix.  The file_pattern_in suffix is stripped from the input
    /// filename and replaced with file_pattern_out.
    /// Example: file_pattern_in="_cash.csv", file_pattern_out="_open.csvx"
    /// turns "CZK_2025-12-01_2025-12-31_cash.csv" into "CZK_2025-12-01_2025-12-31_open.csvx".
    file_pattern_out: []const u8,
    /// When non-null, the xlsx file in data_dir is converted to an intermediate CSV
    /// file before the normal CSV processing loop.  Null when no "xlsx_sheet" key is present in config.
    xlsx_sheet: ?XlsxSheet,
    /// When true, rows whose "@date" value falls outside the date range encoded in
    /// the input filename (YYYY-MM-DD_YYYY-MM-DD) are silently skipped.
    /// Default: false — no date filtering unless explicitly enabled.
    date_filter_from_filename: bool,
    /// When true, all input files in data_dir produce a single combined
    /// output file `1-{template_id}-combined.csvx` instead of one output
    /// per input file. Header is written once (CSV) or wrapped in one
    /// JSON array (JSON). Files are processed in alphabetical name order
    /// (same sort as the per-file mode), so the combined row order is
    /// deterministic.  Default: false.
    combined_output: bool,
    /// Named first-pass lookup tables.  Empty map when not defined in bxp-cli.json.
    /// Legacy single-block form is internally mapped to `_default`; multiple named
    /// blocks each occupy their own namespace inside `lookup_table`.
    /// `StringArrayHashMap` (not `StringHashMap`): preserves the JSON5
    /// declaration order so `prepass_set` trace events, validation error
    /// emit order, and any other iteration over `pre_passes.iterator()`
    /// is deterministic per-run.
    pre_passes: std.StringArrayHashMap(PrePass),
    /// Ordered list of row routing rules.  First matching rule wins.
    /// Empty rows = silent skip; no match + row_rules_debug_missing = debug output.
    /// Null when no "row_rules" key is present (all rows silently skipped).
    row_rules: ?[]RowRule,
    /// When true, rows that match no row_rules entry are printed in --debug output.
    row_rules_debug_missing: bool,
    /// Output column definitions for this template.  Required — must not be empty.
    output_schema: std.array_list.Managed(OutputColumn),
    /// 1-based line number of the CSV header row.  Default: 1 (first line).
    /// 0 = the file has NO header: no line is consumed as headers, every line
    /// (including the first) is data, and columns are reachable only by position
    /// via FIELDS(n) (`[Name]` yields "" since there are no names). N > 1 skips
    /// the N-1 preceding preamble lines and uses line N as the header.
    /// CSV input only; ignored for JSON (object keys) and xlsx (xlsx_sheet.header_row).
    csv_header_line: u32,
    /// Field delimiter used in input CSV files.  Default: ','.
    csv_delimiter_in: u8,
    /// Field delimiter written to output CSV files.  Default: ','.
    csv_delimiter_out: u8,
    /// Decimal separator used in numeric fields of the input CSV.  Default: '.'.
    /// Set to ',' for European-style CSV (e.g. "1234,56" → parsed as 1234.56).
    /// Must differ from csv_delimiter_in.
    csv_decimal_separator_in: u8,
    /// Decimal separator written in numeric output fields.  Default: '.'.
    csv_decimal_separator_out: u8,
    /// Quote character recognised in input CSV fields.
    /// '"' = RFC 4180 double-quote (default); '\'' = single-quote; 0 = no quoting.
    /// Configured via "csv_text_quote_in": "none" | "single" | "double".
    csv_text_quote_in: u8,
    /// Quote character used to wrap output CSV field values that contain the field
    /// delimiter, the quote character itself, or a newline (RFC 4180 §2.5–2.7).
    /// 0 = no quoting (default); '\'' = single-quote; '"' = double-quote.
    /// Configured via "csv_text_quote_out": "none" | "single" | "double".
    csv_text_quote_out: u8,
    /// Input file format.  Default: .csv.
    /// Set to .json to read JSON array-of-objects instead of CSV.
    /// Configured via "file_type_in": "csv" | "json".
    file_type_in: FileType,
    /// Output file format.  Default: .csv.
    /// Set to .json to write JSON array-of-objects instead of CSV.
    /// Configured via "file_type_out": "csv" | "json".
    file_type_out: FileType,

    // Enum-value tables for FieldDoc.enum_values below. File-scope only —
    // sole consumers are the FieldDoc entries in this struct's `fields`
    // table, so the `pub` qualifier was incidental.
    const file_type_values = [_][]const u8{ "csv", "json" };
    const csv_quote_values = [_][]const u8{ "none", "single", "double" };
    const csv_delimiter_values = [_][]const u8{ ",", ";", "\t", "|" };
    const csv_decimal_values = [_][]const u8{ ".", "," };

    /// Schema docs for this struct's fields. Bound at
    /// `conversion_templates.*` by `bxp-core/src/docs.zig`.
    pub const fields = [_]FieldDoc{
        .{
            .key = "data_dir",
            .type_name = "string",
            .required = true,
            .description = "Path to input files, relative to this config file. e.g. \"my_broker\", \"../data/broker\", or an absolute path.",
            .validator = .non_empty,
        },
        .{
            .key = "file_type_in",
            .type_name = "string",
            .required = false,
            .default = "csv",
            .description = "Input file format. \"json\" reads an array-of-objects.",
            .enum_values = &file_type_values,
        },
        .{
            .key = "file_type_out",
            .type_name = "string",
            .required = false,
            .default = "csv",
            .description = "Output file format. \"json\" writes an array-of-objects.",
            .enum_values = &file_type_values,
        },
        .{
            .key = "file_pattern_in",
            .type_name = "string",
            .required = true,
            .description = "Suffix filter for input files in data_dir. e.g. \".csv\" (all), \"_cash.csv\" (specific suffix).",
            .validator = .non_empty,
        },
        .{
            .key = "file_pattern_out",
            .type_name = "string",
            .required = true,
            .description = "Output filename suffix. Replaces file_pattern_in in the output filename.",
            .validator = .non_empty,
        },
        .{
            .key = "csv_header_line",
            .type_name = "number",
            .required = false,
            .default = "1",
            .description = "1-based line number of the CSV header row (default 1). 0 = headerless input: no line is treated as headers, the first line is data, and columns are reachable only by position via FIELDS(n). N>1 skips N-1 preamble lines. CSV input only.",
        },
        .{
            .key = "csv_delimiter_in",
            .type_name = "string",
            .required = false,
            .default = ",",
            .description = "Input CSV field separator (single character).",
            .enum_values = &csv_delimiter_values,
        },
        .{
            .key = "csv_delimiter_out",
            .type_name = "string",
            .required = false,
            .default = ",",
            .description = "Output CSV field separator (single character).",
            .enum_values = &csv_delimiter_values,
        },
        .{
            .key = "csv_decimal_separator_in",
            .type_name = "string",
            .required = false,
            .default = ".",
            .description = "Decimal separator in input numeric fields. Set to \",\" for European-style CSV. Must differ from csv_delimiter_in.",
            .enum_values = &csv_decimal_values,
        },
        .{
            .key = "csv_decimal_separator_out",
            .type_name = "string",
            .required = false,
            .default = ".",
            .description = "Decimal separator written in numeric output fields.",
            .enum_values = &csv_decimal_values,
        },
        .{
            .key = "csv_text_quote_in",
            .type_name = "string",
            .required = false,
            .default = "double",
            .description = "Input CSV text quoting style. Use ''' in expressions for a literal single-quote.",
            .enum_values = &csv_quote_values,
        },
        .{
            .key = "csv_text_quote_out",
            .type_name = "string",
            .required = false,
            .default = "none",
            .description = "Output CSV text quoting style.",
            .enum_values = &csv_quote_values,
        },
        .{
            .key = "ticker_map",
            .type_name = "string | object",
            .required = false,
            .description = "Ticker remapping for this template. String = reference to a named ticker_maps entry. Object = inline map { broker_symbol: yahoo_symbol }.",
            .autocomplete = .ticker_map_names,
        },
        .{
            .key = "date_filter_from_filename",
            .type_name = "boolean",
            .required = false,
            .default = "false",
            .description = "When true, rows whose $date falls outside the date range encoded in the filename (YYYY-MM-DD_YYYY-MM-DD) are silently skipped. Requires $date in input_schema.",
        },
        .{
            .key = "combined_output",
            .type_name = "boolean",
            .required = false,
            .default = "false",
            .description = "When true, all input files in data_dir produce a single combined output file '1-<template_id>-combined.csvx' instead of one output per input. Files are processed in alphabetical order so combined row order is deterministic.",
        },
        .{
            .key = "row_rules_debug_missing",
            .type_name = "boolean",
            .required = false,
            .default = "false",
            .description = "When true, rows that match no row_rules entry are printed in --debug output.",
        },
        .{
            .key = "xlsx_sheet",
            .type_name = "object",
            .required = false,
            .description = "When set, the xlsx file in data_dir is converted to an intermediate CSV before the normal CSV processing loop.",
            .insert_order = "schema",
            .insert_template = XlsxSheet.scaffold_template,
        },
        // Declared before input_schema so the GUI's schema-ordered insert
        // (BrokerConfig.fields uses `insert_order = "schema"`) drops a new
        // pre_pass into the position users expect — right before the
        // input_schema whose LOOKUP() expressions depend on it. Matches the
        // canonical pattern in DEV/bxp-cli.json (anycoin, xtb1_closed, ...).
        .{
            .key = "pre_pass",
            .type_name = "object",
            .required = false,
            .description = "First-pass lookup table(s) built before the main loop. Two accepted shapes: legacy single block `{ when, key, values }` (detected by the presence of `when`) — accessed via 2-arg `LOOKUP(key, 'field')`; or named blocks `{ name1: { when, key, values }, ... }` — each block is its own namespace, accessed via 3-arg `LOOKUP('name', key, 'field')`.",
            .insert_template = PrePass.scaffold_template,
        },
        .{
            .key = "input_schema",
            .type_name = "object",
            .required = true,
            .description = "Map of $variable -> expression. Each expression is evaluated per input row. Variables are referenced in output_schema and row_rules. Iteration order does not affect results.",
            .insert_order = "append",
            .insert_template =
            \\{ $variable1: "value1" }
            ,
        },
        .{
            .key = "output_schema",
            .type_name = "object",
            .required = true,
            .description = "Output CSV column headers mapped to $variable values. Insertion order determines column order in the output file.",
            .ordered = true,
            .insert_order = "append",
            .insert_template =
            \\{ column1: "$variable1" }
            ,
        },
        .{
            .key = "row_rules",
            .type_name = "array",
            .required = false,
            .description = "Ordered list of conditional routing rules. The first rule whose `when` matches produces the output rows; later rules are not evaluated. Rows matching no rule are silently skipped (or shown via row_rules_debug_missing).",
            .ordered = true,
            .insert_template = "[]",
        },
    };

    /// JSON5 scaffold the GUI inserts for a new `conversion_templates` entry.
    pub const scaffold_template =
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

    /// Validates the structural integrity of this template configuration.
    /// Prints a descriptive error to writer and returns error.InvalidConfig on the first violation.
    ///
    /// This is the bxp-cli fail-fast path: the first error aborts processing and
    /// the user sees a single clear message. `validateCollect` is the bxp-fmt
    /// deep-pass equivalent that accumulates all errors in one pass.
    pub fn validate(self: *const BrokerConfig, template_id: []const u8, config_path: []const u8, writer: anytype) !void {
        if (self.data_dir.len == 0) {
            try writer.print("---\n# {s}: config error: template '{s}': data_dir must not be empty\n", .{ config_path, template_id });
            return error.InvalidConfig;
        }
        if (self.file_pattern_in.len == 0) {
            try writer.print("---\n# {s}: config error: template '{s}': file_pattern_in must not be empty (use \".csv\" to process all CSV files)\n", .{ config_path, template_id });
            return error.InvalidConfig;
        }
        if (self.file_pattern_out.len == 0) {
            try writer.print("---\n# {s}: config error: template '{s}': file_pattern_out must not be empty\n", .{ config_path, template_id });
            return error.InvalidConfig;
        }
        if (self.input_schema.count() == 0) {
            try writer.print("---\n# {s}: config error: template '{s}': input_schema must not be empty\n", .{ config_path, template_id });
            return error.InvalidConfig;
        }
        {
            var it = self.input_schema.iterator();
            while (it.next()) |e| {
                if (e.key_ptr.*.len == 0 or e.key_ptr.*[0] != '$') {
                    try writer.print("---\n# {s}: config error: template '{s}': input_schema key '{s}' must start with '$'\n", .{ config_path, template_id, e.key_ptr.* });
                    return error.InvalidConfig;
                }
            }
        }
        if (self.output_schema.items.len == 0) {
            try writer.print("---\n# {s}: config error: template '{s}': output_schema must not be empty\n", .{ config_path, template_id });
            return error.InvalidConfig;
        }
        for (self.output_schema.items) |col| {
            if (col.header.len == 0) {
                try writer.print("---\n# {s}: config error: template '{s}': output_schema header must not be empty\n", .{ config_path, template_id });
                return error.InvalidConfig;
            }
            if (col.variable.len == 0 or col.variable[0] != '$') {
                try writer.print("---\n# {s}: config error: template '{s}': output_schema variable '{s}' must start with '$'\n", .{ config_path, template_id, col.variable });
                return error.InvalidConfig;
            }
        }
        if (self.date_filter_from_filename and !self.input_schema.contains("$date")) {
            try writer.print("---\n# {s}: config error: template '{s}': date_filter_from_filename requires '$date' in input_schema\n", .{ config_path, template_id });
            return error.InvalidConfig;
        }
        if (self.row_rules_debug_missing and (self.row_rules == null or self.row_rules.?.len == 0)) {
            try writer.print("---\n# {s}: config error: template '{s}': row_rules_debug_missing is true but row_rules is empty or not defined\n", .{ config_path, template_id });
            return error.InvalidConfig;
        }
        if (self.row_rules) |rules| {
            for (rules) |rule| {
                if (rule.when.len == 0) {
                    try writer.print("---\n# {s}: config error: template '{s}': row_rules entry has empty 'when'\n", .{ config_path, template_id });
                    return error.InvalidConfig;
                }
            }
        }
        // Cross-reference: every output_schema variable must be declared in input_schema
        // OR explicitly set by every rows entry of every matching row_rules rule.
        // The invariant catches copy-paste errors where a $variable is referenced in
        // output_schema but forgotten in input_schema, which would produce a blank
        // output column silently. When row_rules is empty (rules == &.{}), the inner
        // loops are no-ops and only the input_schema check fires.
        const rules = self.row_rules orelse &.{};
        for (self.output_schema.items) |col| {
            if (self.input_schema.contains(col.variable)) continue;
            for (rules) |rule| {
                for (rule.rows) |row_override| {
                    if (!row_override.contains(col.variable)) {
                        try writer.print(
                            "---\n# {s}: config error: template '{s}': '{s}' is not in input_schema and not set by all row_rules rows\n",
                            .{ config_path, template_id, col.variable });
                        return error.InvalidConfig;
                    }
                }
            }
        }
        if (self.csv_delimiter_in == self.csv_decimal_separator_in) {
            try writer.print(
                "---\n# {s}: config error: template '{s}': csv_delimiter_in and csv_decimal_separator_in must be different characters\n",
                .{ config_path, template_id },
            );
            return error.InvalidConfig;
        }
        {
            // Legacy single-block form lives under the synthetic `_default`
            // name; users never type `_default` themselves, so we strip the
            // name segment from the error path for legacy blocks. Mirrors
            // `validateCollect` (4A.2 alignment) — both validation paths
            // now emit identical text for the same fault.
            var pp_it = self.pre_passes.iterator();
            while (pp_it.next()) |pp_entry| {
                const name = pp_entry.key_ptr.*;
                const pp = pp_entry.value_ptr.*;
                const is_legacy = std.mem.eql(u8, name, "_default");
                if (pp.when.len == 0) {
                    if (is_legacy) {
                        try writer.print("---\n# {s}: config error: template '{s}': pre_pass.when must not be empty\n", .{ config_path, template_id });
                    } else {
                        try writer.print("---\n# {s}: config error: template '{s}': pre_pass.{s}.when must not be empty\n", .{ config_path, template_id, name });
                    }
                    return error.InvalidConfig;
                }
                if (pp.key.len == 0) {
                    if (is_legacy) {
                        try writer.print("---\n# {s}: config error: template '{s}': pre_pass.key must not be empty\n", .{ config_path, template_id });
                    } else {
                        try writer.print("---\n# {s}: config error: template '{s}': pre_pass.{s}.key must not be empty\n", .{ config_path, template_id, name });
                    }
                    return error.InvalidConfig;
                }
                if (pp.values.count() == 0) {
                    if (is_legacy) {
                        try writer.print("---\n# {s}: config error: template '{s}': pre_pass.values must not be empty\n", .{ config_path, template_id });
                    } else {
                        try writer.print("---\n# {s}: config error: template '{s}': pre_pass.{s}.values must not be empty\n", .{ config_path, template_id, name });
                    }
                    return error.InvalidConfig;
                }
            }
        }
        {
            var it = self.ticker_map.iterator();
            while (it.next()) |e| {
                if (e.key_ptr.*.len == 0) {
                    try writer.print("---\n# {s}: config error: template '{s}': ticker_map key must not be empty\n", .{ config_path, template_id });
                    return error.InvalidConfig;
                }
                if (e.value_ptr.*.len == 0) {
                    try writer.print("---\n# {s}: config error: template '{s}': ticker_map value for '{s}' must not be empty\n", .{ config_path, template_id, e.key_ptr.* });
                    return error.InvalidConfig;
                }
            }
        }
    }

    /// Like validate() but collects ALL errors instead of stopping at the first one.
    /// Appends ValidationError items to `errors`; caller owns the strings (free via deinit).
    ///
    /// Used by bxp-fmt's deep validation pass so the user sees the complete picture
    /// in one run. Error text is kept identical to validate() so both paths produce
    /// the same wording — the only difference is accumulation vs. early-exit.
    pub fn validateCollect(
        self: *const BrokerConfig,
        template_id: []const u8,
        alloc: std.mem.Allocator,
        errors: *std.ArrayList(ValidationError),
    ) !void {
        const base = try std.fmt.allocPrint(alloc, "conversion_templates.{s}", .{template_id});
        defer alloc.free(base);

        if (self.data_dir.len == 0)
            try errors.append(alloc, try ValidationError.init(alloc, base, "data_dir", "data_dir must not be empty"));
        if (self.file_pattern_in.len == 0)
            try errors.append(alloc, try ValidationError.init(alloc, base, "file_pattern_in", "file_pattern_in must not be empty (use \".csv\" to process all CSV files)"));
        if (self.file_pattern_out.len == 0)
            try errors.append(alloc, try ValidationError.init(alloc, base, "file_pattern_out", "file_pattern_out must not be empty"));
        if (self.input_schema.count() == 0)
            try errors.append(alloc, try ValidationError.init(alloc, base, "input_schema", "input_schema must not be empty"));
        {
            var it = self.input_schema.iterator();
            while (it.next()) |e| {
                if (e.key_ptr.*.len == 0 or e.key_ptr.*[0] != '$') {
                    const msg = try std.fmt.allocPrint(alloc, "input_schema key '{s}' must start with '$'", .{e.key_ptr.*});
                    defer alloc.free(msg);
                    try errors.append(alloc, try ValidationError.init(alloc, base, "input_schema", msg));
                }
            }
        }
        if (self.output_schema.items.len == 0)
            try errors.append(alloc, try ValidationError.init(alloc, base, "output_schema", "output_schema must not be empty"));
        for (self.output_schema.items) |col| {
            // output_schema is a JSON object; the key (header) is the path segment.
            if (col.header.len == 0) {
                try errors.append(alloc, try ValidationError.init(alloc, base, "output_schema", "output_schema header must not be empty"));
            } else if (col.variable.len == 0 or col.variable[0] != '$') {
                const msg = try std.fmt.allocPrint(alloc, "output_schema variable '{s}' must start with '$'", .{col.variable});
                defer alloc.free(msg);
                const field = try std.fmt.allocPrint(alloc, "output_schema.{s}", .{col.header});
                defer alloc.free(field);
                try errors.append(alloc, try ValidationError.init(alloc, base, field, msg));
            }
        }
        if (self.date_filter_from_filename and !self.input_schema.contains("$date"))
            try errors.append(alloc, try ValidationError.init(alloc, base, "date_filter_from_filename", "date_filter_from_filename requires '$date' in input_schema"));
        if (self.row_rules_debug_missing and (self.row_rules == null or self.row_rules.?.len == 0))
            try errors.append(alloc, try ValidationError.init(alloc, base, "row_rules_debug_missing", "row_rules_debug_missing is true but row_rules is empty or not defined"));
        if (self.row_rules) |rules| {
            for (rules, 0..) |rule, i| {
                if (rule.when.len == 0) {
                    const field = try std.fmt.allocPrint(alloc, "row_rules.{d}.when", .{i});
                    defer alloc.free(field);
                    try errors.append(alloc, try ValidationError.init(alloc, base, field, "row_rules entry has empty 'when'"));
                }
            }
        }
        // Same cross-reference check as validate(), accumulating instead of aborting.
        // The `break` after appending ensures we emit at most one error per output column
        // rather than one per (rule × row_override) pair — the first missing row_override
        // already tells the user which column needs fixing.
        const rules = self.row_rules orelse &.{};
        for (self.output_schema.items) |col| {
            if (self.input_schema.contains(col.variable)) continue;
            for (rules) |rule| {
                for (rule.rows) |row_override| {
                    if (!row_override.contains(col.variable)) {
                        const msg = try std.fmt.allocPrint(alloc, "'{s}' is not in input_schema and not set by all row_rules rows", .{col.variable});
                        defer alloc.free(msg);
                        // The path uses the JSON5-side header (the object key under
                        // output_schema), not the OutputColumn array index — bxp-fmt's
                        // path resolver navigates the loaded JSON tree, where
                        // output_schema is `{ header: "$variable", ... }`.
                        const field = try std.fmt.allocPrint(alloc, "output_schema.{s}", .{col.header});
                        defer alloc.free(field);
                        try errors.append(alloc, try ValidationError.init(alloc, base, field, msg));
                        break;
                    }
                }
            }
        }
        if (self.csv_delimiter_in == self.csv_decimal_separator_in)
            try errors.append(alloc, try ValidationError.init(alloc, base, "csv_delimiter_in", "csv_delimiter_in and csv_decimal_separator_in must be different characters"));
        {
            var pp_it = self.pre_passes.iterator();
            while (pp_it.next()) |pp_entry| {
                const name = pp_entry.key_ptr.*;
                const pp = pp_entry.value_ptr.*;
                // Legacy single block lives under the synthetic `_default` name; for backwards
                // compatible diagnostics we skip the name segment in the error path so that
                // existing GUI consumers see the original `pre_pass.when` paths.
                const is_legacy = std.mem.eql(u8, name, "_default");
                if (pp.when.len == 0) {
                    const field = if (is_legacy)
                        try alloc.dupe(u8, "pre_pass.when")
                    else
                        try std.fmt.allocPrint(alloc, "pre_pass.{s}.when", .{name});
                    defer alloc.free(field);
                    try errors.append(alloc, try ValidationError.init(alloc, base, field, "pre_pass.when must not be empty"));
                }
                if (pp.key.len == 0) {
                    const field = if (is_legacy)
                        try alloc.dupe(u8, "pre_pass.key")
                    else
                        try std.fmt.allocPrint(alloc, "pre_pass.{s}.key", .{name});
                    defer alloc.free(field);
                    try errors.append(alloc, try ValidationError.init(alloc, base, field, "pre_pass.key must not be empty"));
                }
                if (pp.values.count() == 0) {
                    const field = if (is_legacy)
                        try alloc.dupe(u8, "pre_pass.values")
                    else
                        try std.fmt.allocPrint(alloc, "pre_pass.{s}.values", .{name});
                    defer alloc.free(field);
                    try errors.append(alloc, try ValidationError.init(alloc, base, field, "pre_pass.values must not be empty"));
                }
            }
        }
        {
            var it = self.ticker_map.iterator();
            while (it.next()) |e| {
                if (e.key_ptr.*.len == 0)
                    try errors.append(alloc, try ValidationError.init(alloc, base, "ticker_map", "ticker_map key must not be empty"));
                if (e.value_ptr.*.len == 0) {
                    const msg = try std.fmt.allocPrint(alloc, "ticker_map value for '{s}' must not be empty", .{e.key_ptr.*});
                    defer alloc.free(msg);
                    try errors.append(alloc, try ValidationError.init(alloc, base, "ticker_map", msg));
                }
            }
        }
    }

    /// Phase G expression parse-time validation. Walks every expression
    /// string the broker config holds (input_schema values + each
    /// row_rules.when), invokes `expr.eval` against a bare Context (no
    /// fields, no ticker_map, no lookup table) and surfaces any error
    /// as a path-aware Diagnostic. Bare-Context evaluation catches the
    /// errors that don't depend on row data: UnknownFunction
    /// (`BLAH(...)`), syntax errors, mismatched parens, wrong arg
    /// counts in builtins.
    ///
    /// What it doesn't catch (deferred to follow-ups):
    ///   - `[FieldName]` cross-ref against input_schema keys (would
    ///     need a Context with the right col_index)
    ///   - `LOOKUP` resolution against pre_pass blocks
    ///   - Any error that only fires once per-row data is present.
    ///
    /// Includes a tiny did-you-mean for `error.UnknownFunction`: parses
    /// the bad function name out of `error_detail` (which expr.zig
    /// formats as `unknown function 'NAME' — …`) and Levenshtein-
    /// matches against the `expr.builtins` catalog. Suggestions only
    /// emit when distance ≤ 2.
    pub fn validateExprsCollect(
        self: *const BrokerConfig,
        template_id: []const u8,
        alloc: std.mem.Allocator,
        diag: ?*Diagnostics,
    ) !void {
        if (diag == null) return;

        // Build a validate-mode whitelist of pre_pass block names so that
        // `builtinLookup` can flag 3-arg LOOKUP calls that reference a name
        // not declared in this template. The whitelist is only active in the
        // deep-validation pass (diag != null); runtime evals always see
        // pre_pass_names==null and the existing "silent '' on miss" behaviour.
        var pre_pass_names = std.StringHashMap(void).init(alloc);
        defer pre_pass_names.deinit();
        var pp_names_it = self.pre_passes.iterator();
        while (pp_names_it.next()) |e| try pre_pass_names.put(e.key_ptr.*, {});
        // Mirror pipeline.zig: when exactly one pre_pass block exists,
        // 2-arg LOOKUP resolves to it implicitly — so the validator must
        // also treat a 2-arg call as valid in that case.
        const single_prepass_name: ?[]const u8 = if (self.pre_passes.count() == 1)
            self.pre_passes.keys()[0]
        else
            null;

        // input_schema values: $variable → expression
        var is_it = self.input_schema.iterator();
        while (is_it.next()) |entry| {
            try checkOneExpr(
                alloc,
                diag,
                template_id,
                "input_schema",
                entry.key_ptr.*,
                entry.value_ptr.*,
                &pre_pass_names,
                single_prepass_name,
            );
        }

        // row_rules[i].when + row_rules[i].rows[j].$var override expressions.
        const rules = self.row_rules orelse &.{};
        for (rules, 0..) |rule, i| {
            const when_prefix = try std.fmt.allocPrint(alloc, "row_rules.{d}", .{i});
            defer alloc.free(when_prefix);
            try checkOneExpr(
                alloc,
                diag,
                template_id,
                when_prefix,
                "when",
                rule.when,
                &pre_pass_names,
                single_prepass_name,
            );
            // Phase G6: each rule.rows[j] is a RowOverride map ($var →
            // expression). Typos here today silently emit "" into the
            // output column; surfacing them at load time saves a dry-run.
            for (rule.rows, 0..) |row, j| {
                const row_prefix = try std.fmt.allocPrint(
                    alloc, "row_rules.{d}.rows.{d}", .{ i, j });
                defer alloc.free(row_prefix);
                var ov_it = row.iterator();
                while (ov_it.next()) |ov| {
                    try checkOneExpr(
                        alloc,
                        diag,
                        template_id,
                        row_prefix,
                        ov.key_ptr.*,
                        ov.value_ptr.*,
                        &pre_pass_names,
                        single_prepass_name,
                    );
                }
            }
        }

        // Phase G6: pre_passes[name].values entries (lookup-table value
        // expressions). Path encoding mirrors the existing
        // validateCollect logic above: legacy single block (`_default`
        // synthetic name) collapses to `pre_pass.values.<field>`, named
        // blocks expand to `pre_pass.<name>.values.<field>`.
        var pp_it = self.pre_passes.iterator();
        while (pp_it.next()) |pp_entry| {
            const name = pp_entry.key_ptr.*;
            const pp = pp_entry.value_ptr.*;
            const is_legacy = std.mem.eql(u8, name, "_default");
            const values_prefix = if (is_legacy)
                try alloc.dupe(u8, "pre_pass.values")
            else
                try std.fmt.allocPrint(alloc, "pre_pass.{s}.values", .{name});
            defer alloc.free(values_prefix);
            var v_it = pp.values.iterator();
            while (v_it.next()) |v| {
                try checkOneExpr(
                    alloc,
                    diag,
                    template_id,
                    values_prefix,
                    v.key_ptr.*,
                    v.value_ptr.*,
                    &pre_pass_names,
                    single_prepass_name,
                );
            }
        }

        // Phase G2 layer B: gather every expression source in this
        // broker, run frequency clustering, surface a warning when one
        // `[X]` looks like a typo of a high-frequency reference. Loads
        // without a real CSV header (bxp-fmt and bxp-cli load path), so
        // this complements the runtime header check (layer A) — both
        // are warnings, both share the `expr.UnknownField` code.
        var sources = std.array_list.Managed([]const u8).init(alloc);
        defer sources.deinit();
        var is2 = self.input_schema.iterator();
        while (is2.next()) |e| try sources.append(e.value_ptr.*);
        for (rules) |rule| {
            try sources.append(rule.when);
            for (rule.rows) |row| {
                var ov = row.iterator();
                while (ov.next()) |o| try sources.append(o.value_ptr.*);
            }
        }
        var pp2 = self.pre_passes.iterator();
        while (pp2.next()) |pp_entry| {
            const pp = pp_entry.value_ptr.*;
            try sources.append(pp.when);
            try sources.append(pp.key);
            var v_it = pp.values.iterator();
            while (v_it.next()) |v| try sources.append(v.value_ptr.*);
        }
        if (try staticCheckFieldClustering(sources.items, alloc)) |outlier| {
            const path = try std.fmt.allocPrint(
                alloc,
                "conversion_templates.{s}.input_schema",
                .{template_id},
            );
            const message = try std.fmt.allocPrint(
                alloc,
                "field '{s}' is referenced once but '{s}' is used many times — possible typo",
                .{ outlier.bad, outlier.suggest },
            );
            const suggest = try std.fmt.allocPrint(
                alloc,
                "did you mean '{s}'?",
                .{outlier.suggest},
            );
            try diag.?.append(.{
                .path = path,
                .severity = .warning,
                .code = "expr.UnknownField",
                .message = message,
                .suggest = suggest,
            });
        }
    }
};

/// Run a single expression through `expr.eval` with a bare Context and
/// emit a Diagnostic on failure. Empty source is treated as success
/// (matches `eval`'s explicit empty-string short-circuit).
///
/// "Bare Context" means: no actual CSV fields, no ticker_map entries, no
/// lookup table. This catches structural/syntax errors (unknown function,
/// unbalanced parens, wrong arg count) without needing a real row. Errors
/// that only fire on real data (e.g. type mismatches on specific field values)
/// are intentionally not caught here — they surface at dry-run time.
fn checkOneExpr(
    alloc: std.mem.Allocator,
    diag: ?*Diagnostics,
    template_id: []const u8,
    field_prefix: []const u8,
    field_leaf: []const u8,
    src: []const u8,
    pre_pass_names: *const std.StringHashMap(void),
    single_prepass_name: ?[]const u8,
) !void {
    if (src.len == 0) return;
    const d = diag orelse return;

    var col_index = std.StringHashMap(usize).init(alloc);
    defer col_index.deinit();
    var ticker_map_ = std.StringHashMap([]const u8).init(alloc);
    defer ticker_map_.deinit();
    var detail: []const u8 = "";
    var err_offset: u32 = 0;
    var err_len: u32 = 0;
    const ctx = expr.Context{
        .fields = &.{},
        .col_index = &col_index,
        .ticker_map = &ticker_map_,
        .lookup_table = null,
        .pre_pass_names = pre_pass_names,
        .single_prepass_name = single_prepass_name,
        .alloc = alloc,
        .error_detail = &detail,
        .error_offset = &err_offset,
        .error_len = &err_len,
    };

    _ = expr.eval(src, &ctx) catch |err| {
        // Build the path: <prefix>.<leaf>. For input_schema/output_schema
        // the leaf is the variable / header name; for row_rules.<idx>
        // the prefix already encodes the index and the leaf is "when".
        const full_field = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ field_prefix, field_leaf });
        defer alloc.free(full_field);

        // Code mirrors the expr error name with a `expr.` prefix so the
        // GUI can route by category (e.g. "expr.UnknownFunction" vs
        // "expr.NotANumber"). `detail` (when set) carries the human
        // wording from expr.zig's setDetail call; when empty, we fall
        // back to the raw error name so there's always something actionable.
        const code = try std.fmt.allocPrint(alloc, "expr.{s}", .{@errorName(err)});
        const message = if (detail.len > 0)
            try std.fmt.allocPrint(alloc, "expression in {s}: {s}", .{ field_leaf, detail })
        else
            try std.fmt.allocPrint(alloc, "expression in {s}: {s}", .{ field_leaf, @errorName(err) });

        // Did-you-mean for UnknownFunction. Parse the function name out
        // of detail ("unknown function 'NAME' — …"), compute Levenshtein
        // distance against every builtin, suggest the closest match
        // when distance ≤ 2 (typo tolerance).
        var suggest: ?[]const u8 = null;
        if (err == error.UnknownFunction and detail.len > 0) {
            if (extractQuotedName(detail)) |bad_name| {
                if (closestBuiltin(bad_name)) |hint| {
                    suggest = try std.fmt.allocPrint(alloc, "did you mean '{s}'?", .{hint});
                }
            }
        }

        const path = try std.fmt.allocPrint(alloc, "conversion_templates.{s}.{s}", .{ template_id, full_field });
        // Phase G1: forward token offset/len from expr.zig so the GUI
        // ExprPanel can highlight the offending token. Both are 0
        // when the parser couldn't pin a specific span (early failure
        // before any token consumed) — caller treats null-or-zero as
        // "no highlight".
        const has_span = err_len > 0;
        try d.append(.{
            .path = path,
            .severity = .@"error",
            .code = code,
            .message = message,
            .suggest = suggest,
            .expr_off = if (has_span) err_offset else null,
            .expr_len = if (has_span) err_len else null,
        });
    };

    // Unified static-arg checker (replaces former staticCheckSplitPart
    // + staticCheckDateFormat name-hardcoded scanners). Walks every
    // call once, dispatches per FnDoc.args[i].kind. Severity for both
    // hits is `.error` because both are silent-failure modes
    // (1-indexed SPLIT_PART with ≤ 0 returns "" unconditionally;
    // DATE_CONVERT with an unrecognized format letter produces
    // garbage output). Adding a new ArgKind diagnostic = add a
    // StaticCheckResult field + emit branch here, no dispatch
    // changes elsewhere.
    const sc = expr.staticCheckCalls(src);
    if (sc.split_part) |bad| {
        const full_field = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ field_prefix, field_leaf });
        defer alloc.free(full_field);
        const path = try std.fmt.allocPrint(alloc, "conversion_templates.{s}.{s}", .{ template_id, full_field });
        const message = try std.fmt.allocPrint(alloc,
            "expression in {s}: index argument is 1-based; literal {d} always returns \"\"",
            .{ field_leaf, bad.bad_idx });
        try d.append(.{
            .path = path,
            .severity = .@"error",
            .code = "expr.SplitPartBadIndex",
            .message = message,
            .expr_off = bad.off,
            .expr_len = bad.len,
        });
    }
    if (sc.date_format) |bad| {
        const full_field = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ field_prefix, field_leaf });
        defer alloc.free(full_field);
        const path = try std.fmt.allocPrint(alloc, "conversion_templates.{s}.{s}", .{ template_id, full_field });
        const message = try std.fmt.allocPrint(alloc,
            "expression in {s}: DATE_CONVERT format '{s}' has unrecognized letter '{c}' at offset {d} — wrap any literal letters in brackets, e.g. '[T]'",
            .{ field_leaf, bad.fmt, bad.fmt[bad.pos], bad.pos });
        try d.append(.{
            .path = path,
            .severity = .@"error",
            .code = "expr.DateFormatBadToken",
            .message = message,
            .expr_off = bad.off,
            .expr_len = bad.len,
        });
    }
}

/// Extract the first single-quoted name from `s`. Returns null when no
/// matched pair is found. Used to recover the bad function name from
/// expr.zig's `setDetail("unknown function '{s}' — …", ...)` output.
fn extractQuotedName(s: []const u8) ?[]const u8 {
    const start = std.mem.indexOfScalar(u8, s, '\'') orelse return null;
    const after = start + 1;
    if (after >= s.len) return null;
    const end_rel = std.mem.indexOfScalar(u8, s[after..], '\'') orelse return null;
    return s[after .. after + end_rel];
}

/// Return the builtin function name closest to `name` by Levenshtein
/// distance, or null when the closest is more than 2 edits away. Only
/// case-insensitive matches are considered.
fn closestBuiltin(name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = std.math.maxInt(usize);
    for (expr.builtins) |entry| {
        const d = levenshteinIgnoreCase(name, entry.doc.name);
        if (d < best_dist) {
            best_dist = d;
            best = entry.doc.name;
        }
    }
    if (best_dist > 2) return null;
    return best;
}

/// Phase G2 layer B: load-time field-name clustering. Given a slice of
/// expression sources from a single broker, collect every `[X]` named
/// reference (via `expr.staticReferences`), build a frequency map, and
/// return the first outlier — a name with `freq == 1` whose Levenshtein
/// distance to some name with `freq >= 3` is `≤ 2`.
///
/// Threshold rationale:
///   - `freq == 1`: low-frequency outlier candidate (typos rarely
///     repeat).
///   - `freq >= 3`: high-frequency cluster (3+ uses = intentional
///     convention).
///   - The gap (`freq == 2`) is neutral on purpose — neither outlier
///     nor cluster.
///
/// Returned strings are slices into the input sources / hash map keys.
/// Caller must ensure those outlive the result, or dupe before the
/// per-broker arena tears down.
pub const FieldOutlier = struct {
    bad: []const u8,
    suggest: []const u8,
};

pub fn staticCheckFieldClustering(
    sources: []const []const u8,
    alloc: std.mem.Allocator,
) !?FieldOutlier {
    var freq = std.StringHashMap(u32).init(alloc);
    defer freq.deinit();

    for (sources) |src| {
        if (src.len == 0) continue;
        var refs = try expr.staticReferences(src, alloc);
        defer refs.deinit();
        var it = refs.fields.iterator();
        while (it.next()) |e| {
            const gop = try freq.getOrPut(e.key_ptr.*);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }

    // Scan for outliers. Hash-map iteration order is non-deterministic so
    // which of several potential outliers gets reported first may vary
    // between runs. This is acceptable: the user fixes the reported one
    // and re-runs, seeing the next one. Reporting all at once would require
    // a deterministic-order structure (e.g. sorting by name), adding
    // complexity for a marginal benefit (typos are rare and usually singular).
    var f1 = freq.iterator();
    while (f1.next()) |e1| {
        if (e1.value_ptr.* != 1) continue;
        const bad = e1.key_ptr.*;

        var best: ?[]const u8 = null;
        var best_d: usize = std.math.maxInt(usize);
        var f2 = freq.iterator();
        while (f2.next()) |e2| {
            if (e2.value_ptr.* < 3) continue;
            const cand = e2.key_ptr.*;
            const d = levenshteinIgnoreCase(bad, cand);
            if (d < best_d) {
                best_d = d;
                best = cand;
            }
        }
        // Length-relative threshold. At length 4 edit-distance 2 means
        // half the characters differ — more likely a different word
        // than a typo. Mirror the dart_validator gate so the GUI and
        // bxp-fmt agree on `Time` vs `Type`-class pairs.
        const max_d: usize = if (bad.len < 6) 1 else 2;
        if (best != null and best_d <= max_d) {
            return .{ .bad = bad, .suggest = best.? };
        }
    }
    return null;
}

/// Classic O(m*n) Levenshtein distance, case-insensitive. Buffers are
/// stack-allocated — function/key names are short (≤ 16 chars) so the
/// 64-byte cap is sufficient for all realistic inputs. Falls back to an
/// absolute-difference length estimate for oversize strings (theoretical;
/// no real builtin name or config key approaches 64 chars).
pub fn levenshteinIgnoreCase(a: []const u8, b: []const u8) usize {
    const max_len: usize = 64;
    if (a.len > max_len or b.len > max_len) {
        return if (a.len > b.len) a.len - b.len else b.len - a.len;
    }
    // Rolling two-row DP: `prev` holds the previous row, `curr` is built
    // from it. After processing each character of `a`, `curr` is copied
    // into `prev` for the next iteration.
    var prev: [max_len + 1]usize = undefined;
    var curr: [max_len + 1]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ac, i| {
        curr[0] = i + 1;
        for (b, 0..) |bc, j| {
            const same = std.ascii.toLower(ac) == std.ascii.toLower(bc);
            const ins = curr[j] + 1;
            const del = prev[j + 1] + 1;
            const sub = prev[j] + @as(usize, if (same) 0 else 1);
            curr[j + 1] = @min(@min(ins, del), sub);
        }
        @memcpy(prev[0 .. b.len + 1], curr[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// A single validation error with a dot-separated JSON path and a human-readable message.
/// Both strings are owned by the allocator passed to init() and freed via deinit().
pub const ValidationError = struct {
    path: []u8,
    message: []u8,
    alloc: std.mem.Allocator,

    /// path_base + "." + field_suffix → full dot path; message is duped.
    pub fn init(alloc: std.mem.Allocator, path_base: []const u8, field_suffix: []const u8, message: []const u8) !ValidationError {
        const path = if (field_suffix.len > 0)
            try std.fmt.allocPrint(alloc, "{s}.{s}", .{ path_base, field_suffix })
        else
            try alloc.dupe(u8, path_base);
        errdefer alloc.free(path);
        const msg = try alloc.dupe(u8, message);
        return .{ .path = path, .message = msg, .alloc = alloc };
    }

    pub fn deinit(self: *ValidationError) void {
        self.alloc.free(self.path);
        self.alloc.free(self.message);
    }
};

/// Top-level configuration loaded from bxp-cli.json.
pub const Config = struct {
    /// Map from user-defined template key (e.g. "revolutx_to_wealthfolio") to its configuration.
    brokers: std.StringArrayHashMap(BrokerConfig),
    _alloc: std.mem.Allocator,

    /// Releases all heap memory owned by this Config.  Call once when done.
    pub fn deinit(self: *Config) void {
        var it = self.brokers.iterator();
        while (it.next()) |entry| {
            // Free template ID key, data_dir, file_pattern_in and file_pattern_out strings.
            self._alloc.free(entry.key_ptr.*);
            self._alloc.free(entry.value_ptr.data_dir);
            self._alloc.free(entry.value_ptr.file_pattern_in);
            self._alloc.free(entry.value_ptr.file_pattern_out);

            // Free xlsx_sheet string fields.
            if (entry.value_ptr.xlsx_sheet) |s| {
                self._alloc.free(s.name);
                self._alloc.free(s.output_suffix);
            }

            // Free ticker_map keys and values.
            var tm = entry.value_ptr.ticker_map;
            var tm_it = tm.iterator();
            while (tm_it.next()) |te| {
                self._alloc.free(te.key_ptr.*);
                self._alloc.free(te.value_ptr.*);
            }
            tm.deinit();

            // Free input_schema keys and expression strings.
            var is = entry.value_ptr.input_schema;
            var is_it = is.iterator();
            while (is_it.next()) |e| {
                self._alloc.free(e.key_ptr.*);
                self._alloc.free(e.value_ptr.*);
            }
            is.deinit();

            // Free output_schema header and variable name strings.
            var os = entry.value_ptr.output_schema;
            for (os.items) |col| {
                self._alloc.free(col.header);
                self._alloc.free(col.variable);
            }
            os.deinit();

            // Free pre_passes: each entry's name + when/key + values map (keys and values).
            var pps = entry.value_ptr.pre_passes;
            var pps_it = pps.iterator();
            while (pps_it.next()) |pp_entry| {
                self._alloc.free(pp_entry.key_ptr.*);
                self._alloc.free(pp_entry.value_ptr.when);
                self._alloc.free(pp_entry.value_ptr.key);
                var pv_it = pp_entry.value_ptr.values.iterator();
                while (pv_it.next()) |ve| {
                    self._alloc.free(ve.key_ptr.*);
                    self._alloc.free(ve.value_ptr.*);
                }
                pp_entry.value_ptr.values.deinit();
            }
            pps.deinit();

            // Free row_rules: each rule's when string, each row override map, and the slices.
            if (entry.value_ptr.row_rules) |rules| {
                for (rules) |*rule| {
                    self._alloc.free(rule.when);
                    for (rule.rows) |*row| {
                        var row_it = row.iterator();
                        while (row_it.next()) |e| {
                            self._alloc.free(e.key_ptr.*);
                            self._alloc.free(e.value_ptr.*);
                        }
                        row.deinit();
                    }
                    self._alloc.free(rule.rows);
                }
                self._alloc.free(rules);
            }
        }
        self.brokers.deinit();
    }

};


/// Cross-template invariants that aren't visible to per-template
/// `validateCollect` (which sees only one BrokerConfig at a time).
/// Today: pair-wise `file_pattern_in` overlap detection — two
/// templates rooted at the same `data_dir` whose suffix patterns
/// match a common subset of files. The runtime would silently process
/// the same file twice (once per template), which is rarely intended.
///
/// Only emits warnings, never errors — bxp-cli's load path stays
/// untouched (this function is only invoked by bxp-fmt's deep
/// validation pass via a non-null diag sink). Returns immediately
/// when `diag == null`.
pub fn validateCrossTemplate(
    cfg: *const Config,
    alloc: std.mem.Allocator,
    diag: ?*Diagnostics,
) !void {
    if (diag == null) return;

    const ids = cfg.brokers.keys();
    for (ids, 0..) |id_a, i| {
        const a = cfg.brokers.get(id_a) orelse continue;
        for (ids[i + 1 ..]) |id_b| {
            const b = cfg.brokers.get(id_b) orelse continue;
            if (!std.mem.eql(u8, a.data_dir, b.data_dir)) continue;
            if (!suffixOverlap(a.file_pattern_in, b.file_pattern_in)) continue;
            try emitTemplateDiag(alloc, diag, .warning, "config.pattern_collision",
                id_a, "file_pattern_in",
                "data_dir+file_pattern_in matches the same files as template '{s}' (data_dir='{s}', patterns: '{s}' vs '{s}')",
                .{ id_b, a.data_dir, a.file_pattern_in, b.file_pattern_in });
        }
    }
}

/// Filesystem-touching invariants: each broker's resolved `data_dir`
/// is opened with `std.fs.cwd().openDir` (FileNotFound →
/// `fs.dir_not_found` error, other open failures → `fs.dir_unreadable`
/// warning), then iterated to count files whose name ends with
/// `file_pattern_in` — zero matches → `fs.no_input_files` warning.
/// bxp-cli skips this entirely (early return on null sink); the deep
/// pass in bxp-fmt and the opt-in `--check-fs=N` path in bxp-cli both
/// invoke it.
///
/// Implementation is synchronous; `validateFilesystemWithTimeout`
/// wraps it in a worker thread + deadline for environments with slow
/// network mounts.
pub fn validateFilesystem(
    cfg: *const Config,
    alloc: std.mem.Allocator,
    diag: ?*Diagnostics,
) !void {
    if (diag == null) return;

    var it = cfg.brokers.iterator();
    while (it.next()) |entry| {
        const id = entry.key_ptr.*;
        const broker = entry.value_ptr.*;
        var dir = std.fs.cwd().openDir(broker.data_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                try emitTemplateDiag(alloc, diag, .@"error", "fs.dir_not_found",
                    id, "data_dir",
                    "data_dir does not exist: '{s}'", .{broker.data_dir});
            } else {
                try emitTemplateDiag(alloc, diag, .warning, "fs.dir_unreadable",
                    id, "data_dir",
                    "data_dir cannot be opened ({s}): '{s}'", .{ @errorName(err), broker.data_dir });
            }
            continue;
        };
        defer dir.close();

        // Scan for files matching file_pattern_in. Mirrors
        // pipeline.zig's runtime suffix-match — one matched file is
        // enough to confirm the template has work to do; we stop
        // counting after the first hit. Iteration errors break the
        // loop (rare on Linux) and fall through to the
        // `fs.no_input_files` warning below.
        // Accept `.sym_link` as well as `.file`: the runtime loop
        // (pipeline.zig) opens symlinked CSVs transparently, so a
        // data_dir holding only symlinks (or hardlinks — those report
        // as `.file`) has real work to do and must not warn here.
        var matched: u32 = 0;
        var dir_it = dir.iterate();
        while (dir_it.next() catch null) |dir_entry| {
            if (dir_entry.kind != .file and dir_entry.kind != .sym_link) continue;
            if (std.mem.endsWith(u8, dir_entry.name, broker.file_pattern_in)) {
                matched = 1;
                break;
            }
        }
        if (matched == 0) {
            try emitTemplateDiag(alloc, diag, .warning, "fs.no_input_files",
                id, "data_dir",
                "data_dir '{s}' contains no files matching '{s}'",
                .{ broker.data_dir, broker.file_pattern_in });
        }
    }
}

/// Async wrapper around [validateFilesystem]: spawns a worker thread,
/// waits up to `deadline_ms` for it to finish via a shared
/// `ResetEvent`, and on timeout abandons the worker (detach + leak
/// page-allocated context) while emitting one `fs.timeout` warning.
///
/// Total deadline applies across all brokers — per-broker timeout
/// would need N worker threads or signal handling for marginal
/// real-world benefit. Worker uses `std.heap.page_allocator` so
/// allocations don't dangle when the caller returns first; on
/// successful completion main copies diagnostics into the caller's
/// allocator and frees the page-allocated context.
///
/// `deadline_ms == 0` short-circuits to a no-op (FS check disabled).
pub fn validateFilesystemWithTimeout(
    cfg: *const Config,
    alloc: std.mem.Allocator,
    diag: ?*Diagnostics,
    deadline_ms: u64,
) !void {
    const sink = diag orelse return;
    if (deadline_ms == 0) return;

    const page = std.heap.page_allocator;
    const ctx = try page.create(FsCheckCtx);
    ctx.* = .{
        .cfg = cfg,
        .diag_buffer = .init(page),
        .done = .{},
    };

    const thread = std.Thread.spawn(.{}, fsCheckWorker, .{ctx}) catch |err| {
        // Spawn failure: leak nothing — clean ctx, fall back to sync.
        ctx.diag_buffer.deinit();
        page.destroy(ctx);
        if (err == error.OutOfMemory) return err;
        // Other spawn errors (system thread limit, etc.): degrade to
        // sync call so the user still gets the validation result.
        return validateFilesystem(cfg, alloc, sink);
    };

    ctx.done.timedWait(deadline_ms * std.time.ns_per_ms) catch {
        // Timeout. Detach the worker (it will continue to completion in
        // the background and exit when its syscall returns; OS reaps
        // the thread on process exit). The ctx and its page-allocated
        // diagnostics leak intentionally — bxp-fmt / bxp-cli are
        // short-lived processes, the cost is negligible.
        thread.detach();
        try emitGlobalDiag(alloc, sink, .warning, "fs.timeout",
            "[fs.timeout] filesystem check exceeded {d}ms — data_dir existence not verified",
            .{deadline_ms});
        return;
    };

    // Worker finished within deadline. Join, copy diagnostics into the
    // caller's allocator (page-allocated originals are about to be
    // freed), and clean up.
    thread.join();
    for (ctx.diag_buffer.items.items) |item| {
        try sink.append(.{
            .path = try alloc.dupe(u8, item.path),
            .severity = item.severity,
            .code = item.code, // codes are 'static-like string literals — safe to alias
            .message = try alloc.dupe(u8, item.message),
            .suggest = if (item.suggest) |s| try alloc.dupe(u8, s) else null,
        });
    }
    ctx.diag_buffer.deinit();
    page.destroy(ctx);
}

/// Heap-allocated worker context that survives both threads. Lives in
/// `std.heap.page_allocator` so the worker can keep using it after
/// the main thread has detached and moved on.
const FsCheckCtx = struct {
    cfg: *const Config,
    diag_buffer: Diagnostics,
    done: std.Thread.ResetEvent,
};

fn fsCheckWorker(ctx: *FsCheckCtx) void {
    // Always signal completion, even on partial / errored validation —
    // main side cares about "did the worker get this far in time", not
    // about specific failure modes. Diagnostic emission errors
    // (OutOfMemory) are silently dropped here; the partial diagnostics
    // already in diag_buffer still get copied out by main.
    defer ctx.done.set();
    validateFilesystem(ctx.cfg, std.heap.page_allocator, &ctx.diag_buffer) catch {};
}

/// Root-level diagnostic (empty path). Sibling of [emitTemplateDiag]
/// for findings that aren't tied to a specific template — today only
/// `fs.timeout` from [validateFilesystemWithTimeout]. The empty path
/// fits the `_validationPathAlive("")` true case in bxp-gui (commit
/// `354769f`), so the warning is never filtered as an orphan.
fn emitGlobalDiag(
    alloc: std.mem.Allocator,
    diag: ?*Diagnostics,
    severity: Severity,
    code: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const d = diag orelse return;
    const message = try std.fmt.allocPrint(alloc, fmt, args);
    try d.append(.{
        .path = "", // root-level diagnostic
        .severity = severity,
        .code = code,
        .message = message,
    });
}

// ── Phase G8: unused pre_pass / input_schema cross-walk (D3) ──────────

/// Phase G8: cross-walk every expression in the broker config to
/// collect referenced `pre_pass` block names and `$variable` names,
/// then emit a `config.unused_pre_pass` / `config.unused_input_var`
/// warning for any declared item that nothing references.
///
/// Skipped when any expression contains a computed-name LOOKUP
/// (`LOOKUP(name_var, ...)`) — we can't statically prove which block
/// is reached, so flagging an apparent "unused" block could be wrong.
///
/// `[$var]` references are recorded under the literal `$var` key
/// (with `$` prefix); `output_schema` values are treated as direct
/// `$variable` references too — the values there are bare `$var`
/// strings (e.g. `"date": "$date"`).
pub fn validateUnusedCollect(
    self: *const BrokerConfig,
    template_id: []const u8,
    alloc: std.mem.Allocator,
    diag: ?*Diagnostics,
) !void {
    const d = diag orelse return;

    var referenced_lookups = std.StringHashMap(void).init(alloc);
    defer referenced_lookups.deinit();
    var referenced_vars = std.StringHashMap(void).init(alloc);
    defer referenced_vars.deinit();
    var any_computed_lookup = false;
    var any_two_arg_lookup = false;

    // Helper closure-style: scan one expression source and merge into
    // the union sets. Skips empty source.
    const Scan = struct {
        fn run(
            src: []const u8,
            a: std.mem.Allocator,
            lookups_out: *std.StringHashMap(void),
            vars_out: *std.StringHashMap(void),
            computed_out: *bool,
            two_arg_out: *bool,
        ) !void {
            if (src.len == 0) return;
            var refs = try expr.staticReferences(src, a);
            defer refs.deinit();
            var f_it = refs.fields.iterator();
            while (f_it.next()) |e| try vars_out.put(e.key_ptr.*, {});
            var l_it = refs.lookups.iterator();
            while (l_it.next()) |e| try lookups_out.put(e.key_ptr.*, {});
            if (refs.has_computed_lookup_name) computed_out.* = true;
            if (refs.has_two_arg_lookup) two_arg_out.* = true;
        }
    };

    // Scan all expression-bearing fields:
    //   - input_schema values
    //   - output_schema values (each is a `$var` reference verbatim)
    //   - row_rules[].when + row_rules[].rows[].$var
    //   - pre_pass[name].when + .key + .values.*
    var is_it = self.input_schema.iterator();
    while (is_it.next()) |entry| {
        try Scan.run(entry.value_ptr.*, alloc,
            &referenced_lookups, &referenced_vars,
            &any_computed_lookup, &any_two_arg_lookup);
    }
    for (self.output_schema.items) |col| {
        // OutputColumn.variable is a `$variable` reference (not an
        // expression — it's a verbatim `$var` lookup). Treat it as a
        // direct ref so the unused-input-var pass sees it.
        if (col.variable.len > 0) try referenced_vars.put(col.variable, {});
    }
    const rules = self.row_rules orelse &.{};
    for (rules) |rule| {
        try Scan.run(rule.when, alloc,
            &referenced_lookups, &referenced_vars,
            &any_computed_lookup, &any_two_arg_lookup);
        for (rule.rows) |row| {
            var ov_it = row.iterator();
            while (ov_it.next()) |ov| {
                try Scan.run(ov.value_ptr.*, alloc,
                    &referenced_lookups, &referenced_vars,
                    &any_computed_lookup, &any_two_arg_lookup);
            }
        }
    }
    var pp_it = self.pre_passes.iterator();
    while (pp_it.next()) |pp_entry| {
        const pp = pp_entry.value_ptr.*;
        try Scan.run(pp.when, alloc,
            &referenced_lookups, &referenced_vars,
            &any_computed_lookup, &any_two_arg_lookup);
        try Scan.run(pp.key, alloc,
            &referenced_lookups, &referenced_vars,
            &any_computed_lookup, &any_two_arg_lookup);
        var v_it = pp.values.iterator();
        while (v_it.next()) |v| {
            try Scan.run(v.value_ptr.*, alloc,
                &referenced_lookups, &referenced_vars,
                &any_computed_lookup, &any_two_arg_lookup);
        }
    }

    // Unused pre_pass detection — opt out when any computed-name
    // LOOKUP exists (could reach any block).
    if (!any_computed_lookup) {
        // 2-arg LOOKUP resolves implicitly to the only block when count==1.
        // Mark it as referenced so we don't false-positive.
        if (any_two_arg_lookup and self.pre_passes.count() == 1) {
            try referenced_lookups.put(self.pre_passes.keys()[0], {});
        }
        var pp_walk = self.pre_passes.iterator();
        while (pp_walk.next()) |pp_entry| {
            const name = pp_entry.key_ptr.*;
            if (referenced_lookups.contains(name)) continue;
            const is_legacy = std.mem.eql(u8, name, "_default");
            const path_suffix = if (is_legacy)
                try alloc.dupe(u8, "pre_pass")
            else
                try std.fmt.allocPrint(alloc, "pre_pass.{s}", .{name});
            defer alloc.free(path_suffix);
            try emitTemplateDiag(alloc, d, .warning, "config.unused_pre_pass",
                template_id, path_suffix,
                "pre_pass block '{s}' is declared but never referenced via LOOKUP",
                .{name});
        }
    }

    // Unused input_schema $variable detection — independent of LOOKUP
    // computed-name caveat.
    var iv_it = self.input_schema.iterator();
    while (iv_it.next()) |entry| {
        const var_name = entry.key_ptr.*;
        if (referenced_vars.contains(var_name)) continue;
        const path_suffix = try std.fmt.allocPrint(alloc, "input_schema.{s}", .{var_name});
        defer alloc.free(path_suffix);
        try emitTemplateDiag(alloc, d, .warning, "config.unused_input_var",
            template_id, path_suffix,
            "input_schema variable '{s}' is declared but never referenced in any expression or output_schema",
            .{var_name});
    }
}

// ── Phase G7: unknown-key detection (D2) ─────────────────────────────────

/// Top-level keys recognized by the loader. Hardcoded because there's
/// no Config.fields table — only `ticker_maps` and `conversion_templates`
/// reach this level. Must stay in sync with `loadFromBytes`'s root
/// dispatch (and `docs.zig`'s envelope_entries).
const root_keys = [_][]const u8{ "ticker_maps", "conversion_templates" };

/// Legacy single-block pre_pass form. `_default` synthetic name is
/// detected by the presence of any of these literal child keys at the
/// `pre_pass` level — they signal a flat block instead of a named-blocks
/// map.
const legacy_pre_pass_keys = [_][]const u8{ "when", "key", "values" };

/// Phase G7: walk the raw JSON5 tree (the `std.json.Value` produced by
/// `preprocessAnnotated` + `parseFromSliceLeaky` in bxp-fmt) and emit a
/// `config.unknown_key` warning for every key that isn't in the
/// FieldDoc whitelist for its schema path. Includes a Levenshtein-based
/// `did_you_mean` hint when a sibling within distance 2 exists.
///
/// User-defined-key parents are skipped entirely:
/// `input_schema`, `output_schema`, `ticker_map(s)`, `row_rules[].rows[]`,
/// and `pre_pass.{values, *.values}` — those are typed by the user with
/// custom names. Annotation siblings (`$comm_*`, `$err_*`, `$warn_*`,
/// `$info_*`) are also silently skipped so the walker can run on the
/// already-annotated tree without flagging its own injected entries.
pub fn validateUnknownKeysCollect(
    raw: *const std.json.Value,
    alloc: std.mem.Allocator,
    diag: ?*Diagnostics,
) !void {
    const d = diag orelse return;
    if (raw.* != .object) return;

    // Root-level keys.
    try walkObjectKeys(raw, "", &root_keys, alloc, d);

    // Recurse into conversion_templates → per-template trees.
    if (raw.object.getPtr("conversion_templates")) |ct| {
        if (ct.* == .object) {
            var it = ct.object.iterator();
            while (it.next()) |entry| {
                const tmpl_id = entry.key_ptr.*;
                if (isAnnotationKey(tmpl_id)) continue;
                try walkBroker(entry.value_ptr, tmpl_id, alloc, d);
            }
        }
    }
    // ticker_maps children are user-defined names → user-defined values.
    // No whitelist applies anywhere inside.
}

/// Emit `config.unknown_key` warning for every key in `node.object`
/// that isn't in `whitelist` and isn't an annotation sibling. `path`
/// is the dotted schema path *of `node` itself* (used as the parent
/// path for the warning's full path).
fn walkObjectKeys(
    node: *const std.json.Value,
    path: []const u8,
    whitelist: []const []const u8,
    alloc: std.mem.Allocator,
    diag: *Diagnostics,
) !void {
    if (node.* != .object) return;
    var it = node.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (isAnnotationKey(key)) continue;
        if (containsString(whitelist, key)) continue;
        // Unknown — emit warning with optional did-you-mean.
        const full_path = if (path.len > 0)
            try std.fmt.allocPrint(alloc, "{s}.{s}", .{ path, key })
        else
            try alloc.dupe(u8, key);
        // Did-you-mean is concatenated into `message` because the
        // `$warn_*` marker today serializes only the message string
        // (Diagnostic.suggest field isn't plumbed into the annotated
        // JSON output yet — that's the Phase G1 contract change). Once
        // G1 ships, both fields can be split into structured siblings.
        const hint = closestKey(key, whitelist);
        const message = if (hint) |h|
            try std.fmt.allocPrint(
                alloc,
                "unknown config key '{s}' — did you mean '{s}'?",
                .{ key, h },
            )
        else
            try std.fmt.allocPrint(
                alloc,
                "unknown config key '{s}' — typo or extraneous entry",
                .{key},
            );
        var suggest: ?[]const u8 = null;
        if (hint) |h| {
            suggest = try std.fmt.allocPrint(alloc, "did you mean '{s}'?", .{h});
        }
        try diag.append(.{
            .path = full_path,
            .severity = .@"error",
            .code = "config.unknown_key",
            .message = message,
            .suggest = suggest,
        });
    }
}

/// Recurse into a single broker's expected children.
fn walkBroker(
    broker: *const std.json.Value,
    tmpl_id: []const u8,
    alloc: std.mem.Allocator,
    diag: *Diagnostics,
) !void {
    if (broker.* != .object) return;

    const broker_path = try std.fmt.allocPrint(alloc, "conversion_templates.{s}", .{tmpl_id});
    defer alloc.free(broker_path);

    // Whitelist for direct broker keys.
    var broker_keys: [BrokerConfig.fields.len][]const u8 = undefined;
    inline for (BrokerConfig.fields, 0..) |f, i| broker_keys[i] = f.key;
    try walkObjectKeys(broker, broker_path, &broker_keys, alloc, diag);

    // Recurse into known children.
    if (broker.object.getPtr("xlsx_sheet")) |xs| {
        const path = try std.fmt.allocPrint(alloc, "{s}.xlsx_sheet", .{broker_path});
        defer alloc.free(path);
        var keys: [XlsxSheet.fields.len][]const u8 = undefined;
        inline for (XlsxSheet.fields, 0..) |f, i| keys[i] = f.key;
        try walkObjectKeys(xs, path, &keys, alloc, diag);
    }
    if (broker.object.getPtr("row_rules")) |rr| {
        if (rr.* == .array) {
            for (rr.array.items, 0..) |*rule, idx| {
                const path = try std.fmt.allocPrint(alloc, "{s}.row_rules.{d}", .{ broker_path, idx });
                defer alloc.free(path);
                var keys: [RowRule.fields.len][]const u8 = undefined;
                inline for (RowRule.fields, 0..) |f, i| keys[i] = f.key;
                try walkObjectKeys(rule, path, &keys, alloc, diag);
                // rows[].rows[] are user-defined $variable overrides — no whitelist.
            }
        }
    }
    if (broker.object.getPtr("pre_pass")) |pp| {
        try walkPrePass(pp, broker_path, alloc, diag);
    }
    // input_schema / output_schema / ticker_map: user-defined-key
    // territory — no recursion into per-key whitelist applies.
}

/// Recurse into `pre_pass` — branch on legacy single-block vs
/// named-blocks form. Named form children are user-typed names whose
/// values are PrePass structs; iterate each child as a PrePass.
fn walkPrePass(
    pp: *const std.json.Value,
    broker_path: []const u8,
    alloc: std.mem.Allocator,
    diag: *Diagnostics,
) !void {
    if (pp.* != .object) return;

    // Legacy detection: any direct child named `when` / `key` / `values`
    // → flat block. Else assume named-blocks map.
    var is_legacy = false;
    var it_detect = pp.object.iterator();
    while (it_detect.next()) |entry| {
        const key = entry.key_ptr.*;
        if (isAnnotationKey(key)) continue;
        if (containsString(&legacy_pre_pass_keys, key)) {
            is_legacy = true;
            break;
        }
    }

    if (is_legacy) {
        // Whitelist matches PrePass.fields (which are when/key/values).
        const path = try std.fmt.allocPrint(alloc, "{s}.pre_pass", .{broker_path});
        defer alloc.free(path);
        var keys: [PrePass.fields.len][]const u8 = undefined;
        inline for (PrePass.fields, 0..) |f, i| keys[i] = f.key;
        try walkObjectKeys(pp, path, &keys, alloc, diag);
        // values children are user-defined field names — no recursion.
    } else {
        // Named-blocks: each child is a user-typed name with PrePass shape.
        var it_walk = pp.object.iterator();
        while (it_walk.next()) |entry| {
            const block_name = entry.key_ptr.*;
            if (isAnnotationKey(block_name)) continue;
            const path = try std.fmt.allocPrint(alloc, "{s}.pre_pass.{s}", .{ broker_path, block_name });
            defer alloc.free(path);
            var keys: [PrePass.fields.len][]const u8 = undefined;
            inline for (PrePass.fields, 0..) |f, i| keys[i] = f.key;
            try walkObjectKeys(entry.value_ptr, path, &keys, alloc, diag);
        }
    }
}

fn isAnnotationKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "$err_") or
        std.mem.startsWith(u8, key, "$warn_") or
        std.mem.startsWith(u8, key, "$info_") or
        std.mem.startsWith(u8, key, "$comm_");
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| if (std.mem.eql(u8, s, needle)) return true;
    return false;
}

/// Levenshtein-based did-you-mean over a string list. Returns the
/// closest match within edit distance ≤ 2, or null otherwise. Mirrors
/// `closestBuiltin` but generalised over an explicit candidate list.
fn closestKey(name: []const u8, candidates: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = std.math.maxInt(usize);
    for (candidates) |c| {
        const d = levenshteinIgnoreCase(name, c);
        if (d < best_dist) {
            best_dist = d;
            best = c;
        }
    }
    if (best_dist > 2) return null;
    return best;
}

/// True when one string is a suffix of the other (or they're equal).
/// Used by `validateCrossTemplate` to detect `file_pattern_in`
/// overlaps — `".csv"` and `"_closed.csv"` both match
/// `"x_closed.csv"`, but `"_closed.csv"` and `"_cash.csv"` don't
/// overlap (neither is a suffix of the other).
fn suffixOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    return std.mem.endsWith(u8, a, b) or std.mem.endsWith(u8, b, a);
}

/// Maps a std.json parse error to a human-readable description.
fn jsonErrorDesc(err: anyerror) []const u8 {
    return switch (err) {
        error.DuplicateField     => "duplicate key in object — remove or rename the repeated key",
        error.SyntaxError        => "unexpected character — check for missing quotes, commas, or brackets",
        error.UnexpectedToken    => "unexpected token — check for misplaced brackets or missing separators",
        error.InvalidCharacter   => "invalid character in value",
        error.Overflow           => "number value out of range",
        error.InvalidNumber      => "value is not a valid number",
        error.InvalidUtf8        => "invalid UTF-8 sequence in string",
        error.InvalidUnicodeHexSymbol => "invalid \\uXXXX escape sequence",
        error.InvalidEnumTag     => "value does not match any expected tag",
        else                     => @errorName(err),
    };
}

/// Scans preprocessed JSON `content` to find the first duplicate object key.
/// Tracks object/array nesting to distinguish keys from values.
/// On success, prints a diagnostic with file, line, key name and source snippet.
/// Returns true if a duplicate was found and printed.
///
/// When `diag` is non-null and a duplicate is found, also appends a
/// structured Diagnostic with line/col + the duplicated key in the
/// message. Path is root (`""`) — Phase C ships line/col precision;
/// path-from-scanner-stack is a future micro-iteration.
///
/// This scanner is separate from `diagJsonError` because std.json's
/// `parseFromSlice` silently coalesces duplicate keys (last-value-wins),
/// so the parse error path never fires for them. We must detect them
/// before the parse so the user doesn't silently get wrong config values.
fn diagDuplicateKey(
    alloc: std.mem.Allocator,
    content: []const u8,
    raw: []const u8,
    config_path: []const u8,
    diag: ?*Diagnostics,
) bool {
    var scanner = std.json.Scanner.initCompleteInput(alloc, content);
    defer scanner.deinit();
    var scan_diag: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&scan_diag);

    // Per-level nesting state. The `expect_key` toggle alternates between
    // "next string is a key" and "next string is a value" so we don't
    // accidentally record a string-valued field as a duplicate key.
    const Level = struct {
        is_object: bool,
        expect_key: bool,               // true when the next string token is an object key
        keys: std.StringHashMap(void),  // keys seen at this object level
    };
    var stack: std.ArrayList(Level) = .empty;
    defer {
        for (stack.items) |*lvl| {
            var kit = lvl.keys.keyIterator();
            while (kit.next()) |k| alloc.free(k.*);
            lvl.keys.deinit();
        }
        stack.deinit(alloc);
    }

    while (true) {
        const tok = scanner.next() catch break;
        switch (tok) {
            .object_begin => stack.append(alloc, .{
                .is_object  = true,
                .expect_key = true,
                .keys       = std.StringHashMap(void).init(alloc),
            }) catch return false,

            .array_begin => stack.append(alloc, .{
                .is_object  = false,
                .expect_key = false,
                .keys       = std.StringHashMap(void).init(alloc),
            }) catch return false,

            .object_end, .array_end => {
                if (stack.items.len > 0) {
                    var top = stack.pop().?;
                    var kit = top.keys.keyIterator();
                    while (kit.next()) |k| alloc.free(k.*);
                    top.keys.deinit();
                }
                // The container that just closed was a value in its parent object;
                // the next token in that parent is a key (or closing '}').
                if (stack.items.len > 0 and stack.items[stack.items.len - 1].is_object) {
                    stack.items[stack.items.len - 1].expect_key = true;
                }
            },

            .string => |s| {
                if (stack.items.len == 0) continue;
                const top = &stack.items[stack.items.len - 1];
                if (!top.is_object) continue; // array element, not a key
                if (top.expect_key) {
                    // diag position is after the closing '"'; adjust back to the opening '"'.
                    const col_end = scan_diag.getColumn();
                    const ln      = scan_diag.getLine();
                    const caret_col: u64 = if (col_end >= s.len + 2) col_end - s.len - 2 else 1;

                    if (top.keys.contains(s)) {
                        // Found the first duplicate. We stop here — finding
                        // further duplicates in the same document would just
                        // confuse the user who hasn't fixed the first one yet.
                        // Emit a structured diagnostic for bxp-fmt before
                        // printing to stderr (bxp-cli's existing behavior).
                        if (diag) |d| {
                            const msg = std.fmt.allocPrint(
                                alloc,
                                "duplicate key '{s}' — remove or rename the repeated key",
                                .{s},
                            ) catch {
                                std.debug.print(
                                    "# {s}:{d}:{d}: JSON error (line {d}, pos {d}) — duplicate key '{s}' — remove or rename the repeated key\n",
                                    .{ config_path, ln, caret_col, ln, caret_col, s },
                                );
                                return true;
                            };
                            d.append(.{
                                .path = "",
                                .line = std.math.cast(u32, ln) orelse null,
                                .col = std.math.cast(u32, caret_col) orelse null,
                                .severity = .@"error",
                                .code = "json5.duplicate_key",
                                .message = msg,
                            }) catch {};
                        }
                        std.debug.print(
                            "# {s}:{d}:{d}: JSON error (line {d}, pos {d}) — duplicate key '{s}' — remove or rename the repeated key\n",
                            .{ config_path, ln, caret_col, ln, caret_col, s },
                        );
                        var line_iter = std.mem.splitScalar(u8, raw, '\n');
                        var cur: u64 = 1;
                        while (line_iter.next()) |line_content| : (cur += 1) {
                            if (cur == ln) {
                                const trimmed = std.mem.trimRight(u8, line_content, "\r");
                                std.debug.print("#   {s}\n#   ", .{trimmed});
                                var c: u64 = 1;
                                while (c < caret_col) : (c += 1) std.debug.print(" ", .{});
                                std.debug.print("^\n", .{});
                                break;
                            }
                        }
                        return true;
                    }
                    const key_copy = alloc.dupe(u8, s) catch continue;
                    top.keys.put(key_copy, {}) catch {};
                    top.expect_key = false; // next token at this level is the value
                } else {
                    // String value; the next token at this level is a key.
                    top.expect_key = true;
                }
            },

            // Scalar values: next token in the same object is a key.
            .number, .true, .false, .null => {
                if (stack.items.len > 0 and stack.items[stack.items.len - 1].is_object) {
                    stack.items[stack.items.len - 1].expect_key = true;
                }
            },

            .end_of_document => break,
            else => {},
        }
    }
    return false;
}

/// Scans preprocessed JSON `content` to locate a syntax error and prints a diagnostic
/// to stderr with file, line, column and the offending line with a caret marker.
/// `raw` is the original JSON5 source — its line numbers match `content` because the
/// preprocessor preserves newlines for single-line comments and unquoted keys.
/// For semantic errors (e.g. DuplicateField) that pass the scanner, falls back to a
/// description without position.
///
/// When `out_diag` is non-null, also appends a structured Diagnostic
/// with line/col attributes mirroring the stderr output. Path is root
/// (`""`).
fn diagJsonError(
    alloc: std.mem.Allocator,
    content: []const u8,
    raw: []const u8,
    config_path: []const u8,
    err: anyerror,
    out_diag: ?*Diagnostics,
) void {
    std.debug.print("---\n", .{});
    var scanner = std.json.Scanner.initCompleteInput(alloc, content);
    defer scanner.deinit();
    var scan_diag: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&scan_diag);
    var found_pos = false;
    while (true) {
        const tok = scanner.next() catch |scan_err| {
            found_pos = true;
            const ln = scan_diag.getLine();    // 1-based
            const col = scan_diag.getColumn(); // 1-based
            // Use the scanner's own error for the description — it matches the shown position.
            // The `err` from parseFromSlice is only used in the no-position fallback below.
            if (out_diag) |d| {
                const msg = std.fmt.allocPrint(alloc, "{s}", .{jsonErrorDesc(scan_err)}) catch null;
                if (msg) |m| {
                    d.append(.{
                        .path = "",
                        .line = std.math.cast(u32, ln) orelse null,
                        .col = std.math.cast(u32, col) orelse null,
                        .severity = .@"error",
                        .code = "json5.parse_error",
                        .message = m,
                    }) catch {};
                }
            }
            std.debug.print("# {s}:{d}:{d}: JSON error (line {d}, pos {d}) — {s}\n", .{ config_path, ln, col, ln, col, jsonErrorDesc(scan_err) });
            // Show the original source line (line numbers match content for typical JSON5)
            var line_iter = std.mem.splitScalar(u8, raw, '\n');
            var cur: u64 = 1;
            while (line_iter.next()) |line_content| : (cur += 1) {
                if (cur == ln) {
                    const trimmed = std.mem.trimRight(u8, line_content, "\r");
                    std.debug.print("#   {s}\n#   ", .{trimmed});
                    var c: u64 = 1;
                    while (c < col) : (c += 1) std.debug.print(" ", .{});
                    std.debug.print("^\n", .{});
                    break;
                }
            }
            break;
        };
        if (tok == .end_of_document) break;
    }
    if (!found_pos) {
        // Semantic error — scanner found no position.
        // For DuplicateField, scan again to find key name and location.
        if (err == error.DuplicateField) {
            if (!diagDuplicateKey(alloc, content, raw, config_path, out_diag)) {
                // Fallback if duplicate scan fails (should not happen).
                if (out_diag) |d| {
                    const msg = std.fmt.allocPrint(alloc, "{s}", .{jsonErrorDesc(err)}) catch null;
                    if (msg) |m| d.append(.{
                        .path = "",
                        .severity = .@"error",
                        .code = "json5.parse_error",
                        .message = m,
                    }) catch {};
                }
                std.debug.print("# {s}: JSON error — {s}\n", .{ config_path, jsonErrorDesc(err) });
            }
        } else {
            if (out_diag) |d| {
                const msg = std.fmt.allocPrint(alloc, "{s}", .{jsonErrorDesc(err)}) catch null;
                if (msg) |m| d.append(.{
                    .path = "",
                    .severity = .@"error",
                    .code = "json5.parse_error",
                    .message = m,
                }) catch {};
            }
            std.debug.print("# {s}: JSON error — {s}\n", .{ config_path, jsonErrorDesc(err) });
        }
    }
}

/// Parses a single `{ when, key, values }` pre_pass block into a PrePass.
/// Caller owns all heap-allocated strings (released by Config.deinit).
/// Missing fields are silently treated as empty so that downstream validation
/// (`BrokerConfig.validate` / `validateCollect`) can produce a descriptive
/// error path including the block name — e.g. "pre_pass.my_block.when must
/// not be empty" — rather than a generic parse error here without context.
fn parsePrePassBlock(alloc: std.mem.Allocator, ppobj: std.json.ObjectMap) !PrePass {
    var when: []const u8 = try alloc.dupe(u8, "");
    var pp_key: []const u8 = try alloc.dupe(u8, "");
    var pp_values = std.StringHashMap([]const u8).init(alloc);

    if (ppobj.get("when")) |v| {
        if (v == .string) {
            alloc.free(when);
            when = try alloc.dupe(u8, v.string);
        }
    }
    if (ppobj.get("key")) |v| {
        if (v == .string) {
            alloc.free(pp_key);
            pp_key = try alloc.dupe(u8, v.string);
        }
    }
    if (ppobj.get("values")) |vals_val| {
        if (vals_val == .object) {
            var vit = vals_val.object.iterator();
            while (vit.next()) |e| {
                if (e.value_ptr.* == .string) {
                    try pp_values.put(
                        try alloc.dupe(u8, e.key_ptr.*),
                        try alloc.dupe(u8, e.value_ptr.string),
                    );
                }
            }
        }
    }
    return .{ .when = when, .key = pp_key, .values = pp_values };
}

/// Reads the config file at `config_path` (relative to cwd) and returns a fully
/// populated Config.  All strings are duplicated into alloc so the caller
/// owns the memory — release with Config.deinit().
///
/// Missing file → returns an empty Config (no error).
/// Malformed JSON5 → returns an error.
///
/// bxp-cli calls this signature; the structured diagnostic sink stays
/// null and the historical fail-fast / stderr behavior is preserved.
pub fn load(alloc: std.mem.Allocator, config_path: []const u8) !Config {
    const file = std.fs.cwd().openFile(config_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return Config{
                .brokers = std.StringArrayHashMap(BrokerConfig).init(alloc),
                ._alloc = alloc,
            };
        }
        return err;
    };
    defer file.close();

    const raw = try file.readToEndAlloc(alloc, CONFIG_MAX_FILE_SIZE);
    defer alloc.free(raw);
    return loadFromBytes(alloc, raw, config_path, null);
}

/// Emit a per-template diagnostic to the bag if non-null. The path is
/// always rooted at `conversion_templates.<id>.<field_suffix>`. The
/// message is built with `std.fmt.allocPrint` from the format string +
/// args, mirroring the existing `std.debug.print` text so bxp-cli's
/// stderr stays untouched and bxp-fmt's `$err_*` annotation gets the
/// same human-readable wording.
fn emitTemplateDiag(
    alloc: std.mem.Allocator,
    diag: ?*Diagnostics,
    severity: Severity,
    code: []const u8,
    template_id: []const u8,
    field_suffix: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const d = diag orelse return;
    const path = if (field_suffix.len > 0)
        try std.fmt.allocPrint(alloc, "conversion_templates.{s}.{s}", .{ template_id, field_suffix })
    else
        try std.fmt.allocPrint(alloc, "conversion_templates.{s}", .{template_id});
    const message = try std.fmt.allocPrint(alloc, fmt, args);
    try d.append(.{
        .path = path,
        .severity = severity,
        .code = code,
        .message = message,
    });
}

/// Parse a single-character string config field (`csv_delimiter_in`,
/// `csv_decimal_separator_out`, etc.). Returns the new char on a valid
/// 1-char string; on any other shape (missing, wrong type, wrong
/// length) returns the supplied default and emits a `wrong_type_silent`
/// warning into the diagnostics bag if non-null.
fn parseSingleCharCsvField(
    alloc: std.mem.Allocator,
    diag: ?*Diagnostics,
    bobj: std.json.ObjectMap,
    template_id: []const u8,
    field: []const u8,
    default_value: u8,
) !u8 {
    const v = bobj.get(field) orelse return default_value;
    if (v == .string and v.string.len == 1) return v.string[0];

    if (v == .string) {
        try emitTemplateDiag(alloc, diag, .warning, "config.wrong_type_silent",
            template_id, field,
            "{s} must be a single character, got string of length {d} — value ignored",
            .{ field, v.string.len });
    } else {
        try emitTemplateDiag(alloc, diag, .warning, "config.wrong_type_silent",
            template_id, field,
            "{s} must be a single-character string, got {s} — value ignored",
            .{ field, @tagName(v) });
    }
    return default_value;
}

/// Parse the `csv_text_quote_in` / `csv_text_quote_out` enum field.
/// Accepts `"single"`, `"double"`, and `"none"` per the FieldDoc
/// (`"none" | "single" | "double"`). Any other string surfaces an
/// `invalid_enum` warning and falls back to no-quoting; non-string
/// values are reported as `wrong_type_silent`.
fn parseTextQuoteField(
    alloc: std.mem.Allocator,
    diag: ?*Diagnostics,
    bobj: std.json.ObjectMap,
    template_id: []const u8,
    field: []const u8,
    default_value: u8,
) !u8 {
    const v = bobj.get(field) orelse return default_value;
    if (v != .string) {
        try emitTemplateDiag(alloc, diag, .warning, "config.wrong_type_silent",
            template_id, field,
            "{s} must be a string ('none' | 'single' | 'double'), got {s} — value ignored",
            .{ field, @tagName(v) });
        return default_value;
    }
    if (std.mem.eql(u8, v.string, "single")) return '\'';
    if (std.mem.eql(u8, v.string, "double")) return '"';
    if (std.mem.eql(u8, v.string, "none")) return 0;
    try emitTemplateDiag(alloc, diag, .warning, "config.invalid_enum",
        template_id, field,
        "{s} must be 'none' | 'single' | 'double', got '{s}' — defaulting to none",
        .{ field, v.string });
    return 0;
}

/// Parse the `file_type_in` / `file_type_out` enum field (`"json"` /
/// `"csv"`). Anything else silently defaults to `.csv` today; this
/// helper preserves that behavior but surfaces a warning so users see
/// when a typo (`"jsno"`) silently fell back.
fn parseFileTypeField(
    alloc: std.mem.Allocator,
    diag: ?*Diagnostics,
    bobj: std.json.ObjectMap,
    template_id: []const u8,
    field: []const u8,
    default_value: FileType,
) !FileType {
    const v = bobj.get(field) orelse return default_value;
    if (v != .string) {
        try emitTemplateDiag(alloc, diag, .warning, "config.wrong_type_silent",
            template_id, field,
            "{s} must be a string ('json' or 'csv'), got {s} — value ignored",
            .{ field, @tagName(v) });
        return default_value;
    }
    if (std.mem.eql(u8, v.string, "json")) return .json;
    if (std.mem.eql(u8, v.string, "csv")) return .csv;
    try emitTemplateDiag(alloc, diag, .warning, "config.invalid_enum",
        template_id, field,
        "{s} must be 'json' or 'csv', got '{s}' — defaulting to 'csv'",
        .{ field, v.string });
    return .csv;
}

/// Parse + validate a config from in-memory JSON5 bytes. The path label
/// is only used in diagnostic messages — pass an arbitrary marker
/// (`"<inline>"`, `"test"`, ...) when the source isn't a real file. Carved
/// out of `load()` so `bxp-fmt --config` can avoid double-reading the
/// file (it already has the raw bytes for `preprocessAnnotated`) and so
/// inline tests can exercise the loader without touching disk.
///
/// `diag` is an optional structured diagnostic sink. When non-null,
/// future phases will append path-aware errors / warnings into it
/// alongside the existing `std.debug.print` + `return error` behavior.
/// bxp-cli passes null so its load path is unchanged bit by bit; only
/// bxp-fmt's deep-validation pass passes a non-null sink today.
pub fn loadFromBytes(
    alloc: std.mem.Allocator,
    raw: []const u8,
    config_path: []const u8,
    diag: ?*Diagnostics,
) !Config {
    var config = Config{
        .brokers = std.StringArrayHashMap(BrokerConfig).init(alloc),
        ._alloc = alloc,
    };

    const content = try json5.preprocess(alloc, raw);
    defer alloc.free(content);

    // Detect duplicate object keys before parsing — std.json's parseFromSlice
    // silently takes the *last* value for duplicate keys, which would let a
    // user accidentally overwrite a setting without any feedback. We scan first
    // with our own key-tracking scanner and fail early with a precise location.
    if (diagDuplicateKey(alloc, content, raw, config_path, diag)) {
        return error.InvalidConfig;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch |err| {
        diagJsonError(alloc, content, raw, config_path, err, diag);
        return err;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return config;

    // "ticker_maps": named, reusable ticker maps referenced by templates via string key.
    // Values are kept as raw JSON objects; entries are duped into each referencing template.
    // We hold a reference to the parsed JSON tree's ObjectMap directly (no alloc per entry)
    // because the `parsed` value is deferred-deinitialized at the end of this function —
    // the map entries live long enough for the per-template duplication below.
    var named_ticker_maps = std.StringHashMap(std.json.ObjectMap).init(alloc);
    defer named_ticker_maps.deinit();
    if (root.object.get("ticker_maps")) |tm_root| {
        if (tm_root == .object) {
            var nm_it = tm_root.object.iterator();
            while (nm_it.next()) |e| {
                if (e.value_ptr.* == .object) {
                    try named_ticker_maps.put(e.key_ptr.*, e.value_ptr.object);
                }
            }
        }
    }

    // "conversion_templates": each key is a template ID; value is a broker config object.
    if (root.object.get("conversion_templates")) |brokers_val| {
        if (brokers_val == .object) {
            var b_it = brokers_val.object.iterator();
            while (b_it.next()) |b_entry| {
                // Defaults — overridden by any matching JSON key found below.
                var data_dir: []const u8 = try alloc.dupe(u8, ".");
                errdefer alloc.free(data_dir);
                var file_pattern_in: []const u8 = try alloc.dupe(u8, "");
                errdefer alloc.free(file_pattern_in);
                var file_pattern_out: []const u8 = try alloc.dupe(u8, "");
                errdefer alloc.free(file_pattern_out);
                var xlsx_sheet: ?XlsxSheet = null;
                var ticker_map = std.StringHashMap([]const u8).init(alloc);
                var input_schema = std.StringArrayHashMap([]const u8).init(alloc);
                var date_filter_from_filename: bool = false;
                var combined_output: bool = false;
                var pre_passes = std.StringArrayHashMap(PrePass).init(alloc);
                var row_rules: ?[]RowRule = null;
                var row_rules_debug_missing: bool = false;
                var output_schema: ?std.array_list.Managed(OutputColumn) = null;
                var csv_header_line: u32 = 1;
                var csv_delimiter_in: u8 = ',';
                var csv_delimiter_out: u8 = ',';
                var csv_decimal_separator_in: u8 = '.';
                var csv_decimal_separator_out: u8 = '.';
                var csv_text_quote_in: u8 = '"';
                var csv_text_quote_out: u8 = 0;
                var file_type_in: FileType = .csv;
                var file_type_out: FileType = .csv;

                if (b_entry.value_ptr.* == .object) {
                    const bobj = b_entry.value_ptr.object;

                    if (bobj.get("data_dir")) |v| {
                        if (v == .string) {
                            // Resolve data_dir relative to the config file's directory so that
                            // a config in /home/user/bxp-cli.json with data_dir: "revolut" resolves
                            // to /home/user/revolut regardless of the process's cwd. Allocate
                            // the joined path BEFORE freeing the old default — if join OOMs,
                            // the errdefer above must still see a valid pointer in `data_dir`.
                            const cfg_dir = std.fs.path.dirname(config_path) orelse ".";
                            const new_data_dir = try std.fs.path.join(alloc, &.{ cfg_dir, v.string });
                            alloc.free(data_dir);
                            data_dir = new_data_dir;
                        }
                    }

                    if (bobj.get("file_pattern_in")) |v| {
                        if (v == .string) {
                            const new_pat = try alloc.dupe(u8, v.string);
                            alloc.free(file_pattern_in);
                            file_pattern_in = new_pat;
                        }
                    }

                    if (bobj.get("file_pattern_out")) |v| {
                        if (v == .string) {
                            const new_pat = try alloc.dupe(u8, v.string);
                            alloc.free(file_pattern_out);
                            file_pattern_out = new_pat;
                        }
                    }

                    // xlsx_sheet: object with { name, header_row, output_suffix }.
                    // All three keys are required; a missing/wrong-typed sub-key is
                    // a hard config error (was silent until 4A.1) — silent fallthrough
                    // produced mystery "no .csv files" failures downstream when the
                    // user typed `sheet_name` instead of `name`, or supplied a number
                    // for `header_row` as a string. To intentionally disable xlsx
                    // pre-pass for a template, remove the entire `xlsx_sheet` block.
                    if (bobj.get("xlsx_sheet")) |xs_val| {
                        if (xs_val != .object) {
                            try emitTemplateDiag(alloc, diag, .@"error", "config.wrong_type",
                                b_entry.key_ptr.*, "xlsx_sheet",
                                "xlsx_sheet must be an object, got {s}", .{@tagName(xs_val)});
                            std.debug.print(
                                "---\n# {s}: config error: template '{s}': xlsx_sheet must be an object, got {s}\n",
                                .{ config_path, b_entry.key_ptr.*, @tagName(xs_val) },
                            );
                            return error.InvalidConfig;
                        }
                        const obj = xs_val.object;
                        const name = if (obj.get("name")) |v| switch (v) {
                            .string => |s| try alloc.dupe(u8, s),
                            else => {
                                try emitTemplateDiag(alloc, diag, .@"error", "config.wrong_type",
                                    b_entry.key_ptr.*, "xlsx_sheet.name",
                                    "xlsx_sheet.name must be a string, got {s}", .{@tagName(v)});
                                std.debug.print(
                                    "---\n# {s}: config error: template '{s}': xlsx_sheet.name must be a string, got {s}\n",
                                    .{ config_path, b_entry.key_ptr.*, @tagName(v) },
                                );
                                return error.InvalidConfig;
                            },
                        } else {
                            try emitTemplateDiag(alloc, diag, .@"error", "config.missing_field",
                                b_entry.key_ptr.*, "xlsx_sheet",
                                "xlsx_sheet missing required key 'name'", .{});
                            std.debug.print(
                                "---\n# {s}: config error: template '{s}': xlsx_sheet missing required key 'name'\n",
                                .{ config_path, b_entry.key_ptr.* },
                            );
                            return error.InvalidConfig;
                        };
                        errdefer alloc.free(name);
                        const header_row: u32 = if (obj.get("header_row")) |v| switch (v) {
                            .integer => |n| @intCast(n),
                            else => {
                                try emitTemplateDiag(alloc, diag, .@"error", "config.wrong_type",
                                    b_entry.key_ptr.*, "xlsx_sheet.header_row",
                                    "xlsx_sheet.header_row must be a number, got {s}", .{@tagName(v)});
                                std.debug.print(
                                    "---\n# {s}: config error: template '{s}': xlsx_sheet.header_row must be a number, got {s}\n",
                                    .{ config_path, b_entry.key_ptr.*, @tagName(v) },
                                );
                                return error.InvalidConfig;
                            },
                        } else {
                            try emitTemplateDiag(alloc, diag, .@"error", "config.missing_field",
                                b_entry.key_ptr.*, "xlsx_sheet",
                                "xlsx_sheet missing required key 'header_row'", .{});
                            std.debug.print(
                                "---\n# {s}: config error: template '{s}': xlsx_sheet missing required key 'header_row'\n",
                                .{ config_path, b_entry.key_ptr.* },
                            );
                            return error.InvalidConfig;
                        };
                        const output_suffix = if (obj.get("output_suffix")) |v| switch (v) {
                            .string => |s| try alloc.dupe(u8, s),
                            else => {
                                try emitTemplateDiag(alloc, diag, .@"error", "config.wrong_type",
                                    b_entry.key_ptr.*, "xlsx_sheet.output_suffix",
                                    "xlsx_sheet.output_suffix must be a string, got {s}", .{@tagName(v)});
                                std.debug.print(
                                    "---\n# {s}: config error: template '{s}': xlsx_sheet.output_suffix must be a string, got {s}\n",
                                    .{ config_path, b_entry.key_ptr.*, @tagName(v) },
                                );
                                return error.InvalidConfig;
                            },
                        } else {
                            try emitTemplateDiag(alloc, diag, .@"error", "config.missing_field",
                                b_entry.key_ptr.*, "xlsx_sheet",
                                "xlsx_sheet missing required key 'output_suffix'", .{});
                            std.debug.print(
                                "---\n# {s}: config error: template '{s}': xlsx_sheet missing required key 'output_suffix'\n",
                                .{ config_path, b_entry.key_ptr.* },
                            );
                            return error.InvalidConfig;
                        };
                        xlsx_sheet = XlsxSheet{
                            .name          = name,
                            .header_row    = header_row,
                            .output_suffix = output_suffix,
                        };
                    }

                    if (bobj.get("date_filter_from_filename")) |v| {
                        if (v == .bool) {
                            date_filter_from_filename = v.bool;
                        } else {
                            try emitTemplateDiag(alloc, diag, .warning, "config.wrong_type_silent",
                                b_entry.key_ptr.*, "date_filter_from_filename",
                                "date_filter_from_filename must be a boolean, got {s} — value ignored", .{@tagName(v)});
                        }
                    }

                    if (bobj.get("combined_output")) |v| {
                        if (v == .bool) {
                            combined_output = v.bool;
                        } else {
                            try emitTemplateDiag(alloc, diag, .warning, "config.wrong_type_silent",
                                b_entry.key_ptr.*, "combined_output",
                                "combined_output must be a boolean, got {s} — value ignored", .{@tagName(v)});
                        }
                    }

                    // ticker_map: symbol → Yahoo Finance ticker remapping.
                    // Accepts either an inline object or a string key referencing "ticker_maps".
                    if (bobj.get("ticker_map")) |tm_val| {
                        const src_obj: std.json.ObjectMap = switch (tm_val) {
                            .string => |name| named_ticker_maps.get(name) orelse {
                                try emitTemplateDiag(alloc, diag, .@"error", "config.unknown_named_map",
                                    b_entry.key_ptr.*, "ticker_map",
                                    "ticker_map references unknown named map '{s}'", .{name});
                                std.debug.print(
                                    "error: template '{s}': ticker_map references unknown named map '{s}'\n",
                                    .{ b_entry.key_ptr.*, name },
                                );
                                return error.InvalidConfig;
                            },
                            .object => |obj| obj,
                            // Bad type (number, null, array, ...) — hard error rather than `continue`.
                            // `continue` here would jump out of the broker-construction loop body
                            // and skip `config.brokers.put(...)` below, leaking every string already
                            // duped for this broker (data_dir, file_pattern_in/out, input_schema entries).
                            else => {
                                try emitTemplateDiag(alloc, diag, .@"error", "config.wrong_type",
                                    b_entry.key_ptr.*, "ticker_map",
                                    "ticker_map must be a string (named-map ref) or an object, got {s}", .{@tagName(tm_val)});
                                std.debug.print(
                                    "error: template '{s}': ticker_map must be a string (named-map ref) or an object, got {s}\n",
                                    .{ b_entry.key_ptr.*, @tagName(tm_val) },
                                );
                                return error.InvalidConfig;
                            },
                        };
                        var tm_it = src_obj.iterator();
                        while (tm_it.next()) |te| {
                            if (te.value_ptr.* == .string) {
                                try ticker_map.put(
                                    try alloc.dupe(u8, te.key_ptr.*),
                                    try alloc.dupe(u8, te.value_ptr.string),
                                );
                            }
                        }
                    }

                    // input_schema: @variable → expression string, evaluated per row.
                    if (bobj.get("input_schema")) |is_val| {
                        if (is_val == .object) {
                            var is_it = is_val.object.iterator();
                            while (is_it.next()) |e| {
                                if (e.value_ptr.* == .string) {
                                    try input_schema.put(
                                        try alloc.dupe(u8, e.key_ptr.*),
                                        try alloc.dupe(u8, e.value_ptr.string),
                                    );
                                }
                            }
                        }
                    }

                    if (bobj.get("row_rules_debug_missing")) |v| {
                        if (v == .bool) {
                            row_rules_debug_missing = v.bool;
                        } else {
                            try emitTemplateDiag(alloc, diag, .warning, "config.wrong_type_silent",
                                b_entry.key_ptr.*, "row_rules_debug_missing",
                                "row_rules_debug_missing must be a boolean, got {s} — value ignored", .{@tagName(v)});
                        }
                    }

                    // row_rules: ordered list of conditional routing rules.
                    // Non-object array elements (null, number, etc.) are silently skipped
                    // rather than failing hard — they're almost certainly JSON5 trailing
                    // commas that the preprocessor already stripped, or accidental blank
                    // entries. Missing `when` is treated as empty string ("") so that
                    // BrokerConfig.validate() can produce a helpful error message with
                    // the rule index instead of failing here with a generic parse error.
                    if (bobj.get("row_rules")) |rr_val| {
                        if (rr_val == .array) {
                            var rr_list = std.array_list.Managed(RowRule).init(alloc);
                            for (rr_val.array.items) |rule_val| {
                                if (rule_val != .object) continue;
                                const robj = rule_val.object;
                                const when_str = if (robj.get("when")) |w|
                                    if (w == .string) try alloc.dupe(u8, w.string) else try alloc.dupe(u8, "")
                                else
                                    try alloc.dupe(u8, "");
                                var rows_list = std.array_list.Managed(RowOverride).init(alloc);
                                if (robj.get("rows")) |rows_val| {
                                    if (rows_val == .array) {
                                        for (rows_val.array.items) |row_val| {
                                            if (row_val != .object) continue;
                                            var row_map = RowOverride.init(alloc);
                                            var rv_it = row_val.object.iterator();
                                            while (rv_it.next()) |rv| {
                                                if (rv.value_ptr.* == .string) {
                                                    try row_map.put(
                                                        try alloc.dupe(u8, rv.key_ptr.*),
                                                        try alloc.dupe(u8, rv.value_ptr.string),
                                                    );
                                                }
                                            }
                                            try rows_list.append(row_map);
                                        }
                                    }
                                }
                                try rr_list.append(RowRule{
                                    .when = when_str,
                                    .rows = try rows_list.toOwnedSlice(),
                                });
                            }
                            // Preserve the user's original `row_rules: []` shape — the
                            // distinction between "key absent" (null) and "key present
                            // but empty" (`&.{}`) lets the validator surface the correct
                            // hint (`row_rules is empty or not defined`) without lying
                            // about which case we're in. Both shapes evaluate the same
                            // at runtime via `row_rules orelse &.{}`.
                            row_rules = try rr_list.toOwnedSlice();
                        }
                    }

                    // output_schema: ordered output column header → @variable mappings.
                    // Per-template and required — validated after this block.
                    if (bobj.get("output_schema")) |os_val| {
                        if (os_val == .object) {
                            var os_list = std.array_list.Managed(OutputColumn).init(alloc);
                            var os_it = os_val.object.iterator();
                            while (os_it.next()) |e| {
                                if (e.value_ptr.* == .string) {
                                    try os_list.append(OutputColumn{
                                        .header   = try alloc.dupe(u8, e.key_ptr.*),
                                        .variable = try alloc.dupe(u8, e.value_ptr.string),
                                    });
                                }
                            }
                            output_schema = os_list;
                        }
                    }

                    // pre_pass: optional first-pass lookup table(s) built before main row loop.
                    //
                    // Two accepted shapes:
                    //   Legacy single block — `pre_pass: { when, key, values }`.
                    //     Detected by the presence of the `when` key on the pre_pass object.
                    //     Stored internally under the synthetic name `_default`.
                    //   New named blocks — `pre_pass: { name1: { when, key, values }, ... }`.
                    //     Each child is parsed as its own block; names are validated to be
                    //     non-empty and free of NUL bytes (the composite-key delimiter).
                    //
                    // NUL-byte validation is essential because lookup keys are composite
                    // strings "name\x00key\x00field". A NUL in the block name would make
                    // it impossible to distinguish where the name ends and the key begins.
                    if (bobj.get("pre_pass")) |pp_val| {
                        if (pp_val == .object) {
                            const ppobj = pp_val.object;
                            const is_legacy_form = ppobj.get("when") != null;
                            if (is_legacy_form) {
                                const block = try parsePrePassBlock(alloc, ppobj);
                                try pre_passes.put(try alloc.dupe(u8, "_default"), block);
                            } else {
                                var pp_it = ppobj.iterator();
                                while (pp_it.next()) |pe| {
                                    const name = pe.key_ptr.*;
                                    if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) {
                                        try emitTemplateDiag(alloc, diag, .@"error", "config.invalid_pre_pass_name",
                                            b_entry.key_ptr.*, "pre_pass",
                                            "pre_pass name must be non-empty and free of NUL bytes", .{});
                                        std.debug.print(
                                            "---\n# {s}: config error: template '{s}': pre_pass name must be non-empty and free of NUL bytes\n",
                                            .{ config_path, b_entry.key_ptr.* },
                                        );
                                        return error.InvalidConfig;
                                    }
                                    if (pe.value_ptr.* != .object) continue;
                                    const block = try parsePrePassBlock(alloc, pe.value_ptr.object);
                                    try pre_passes.put(try alloc.dupe(u8, name), block);
                                }
                            }
                        }
                    }
                    // csv_header_line: 1-based header line number (0 = headerless). A JSON number.
                    csv_header_line = if (bobj.get("csv_header_line")) |v| switch (v) {
                        .integer => |n| blk: {
                            if (n < 0 or n > std.math.maxInt(u32)) {
                                try emitTemplateDiag(alloc, diag, .@"error", "config.invalid_value",
                                    b_entry.key_ptr.*, "csv_header_line",
                                    "csv_header_line must be between 0 and {d}, got {d}", .{ std.math.maxInt(u32), n });
                                std.debug.print(
                                    "---\n# {s}: config error: template '{s}': csv_header_line out of range, got {d}\n",
                                    .{ config_path, b_entry.key_ptr.*, n });
                                return error.InvalidConfig;
                            }
                            break :blk @as(u32, @intCast(n));
                        },
                        else => {
                            try emitTemplateDiag(alloc, diag, .@"error", "config.wrong_type",
                                b_entry.key_ptr.*, "csv_header_line",
                                "csv_header_line must be a number, got {s}", .{@tagName(v)});
                            std.debug.print(
                                "---\n# {s}: config error: template '{s}': csv_header_line must be a number, got {s}\n",
                                .{ config_path, b_entry.key_ptr.*, @tagName(v) });
                            return error.InvalidConfig;
                        },
                    } else csv_header_line;
                    // csv_delimiter_in / csv_delimiter_out / csv_decimal_separator_in / csv_decimal_separator_out
                    // Each must be a single-character string; silently ignored if wrong length.
                    csv_delimiter_in = try parseSingleCharCsvField(alloc, diag, bobj, b_entry.key_ptr.*, "csv_delimiter_in", csv_delimiter_in);
                    csv_delimiter_out = try parseSingleCharCsvField(alloc, diag, bobj, b_entry.key_ptr.*, "csv_delimiter_out", csv_delimiter_out);
                    csv_decimal_separator_in = try parseSingleCharCsvField(alloc, diag, bobj, b_entry.key_ptr.*, "csv_decimal_separator_in", csv_decimal_separator_in);
                    csv_decimal_separator_out = try parseSingleCharCsvField(alloc, diag, bobj, b_entry.key_ptr.*, "csv_decimal_separator_out", csv_decimal_separator_out);
                    csv_text_quote_in = try parseTextQuoteField(alloc, diag, bobj, b_entry.key_ptr.*, "csv_text_quote_in", csv_text_quote_in);
                    csv_text_quote_out = try parseTextQuoteField(alloc, diag, bobj, b_entry.key_ptr.*, "csv_text_quote_out", csv_text_quote_out);
                    file_type_in = try parseFileTypeField(alloc, diag, bobj, b_entry.key_ptr.*, "file_type_in", file_type_in);
                    file_type_out = try parseFileTypeField(alloc, diag, bobj, b_entry.key_ptr.*, "file_type_out", file_type_out);
                }

                if (output_schema == null) {
                    try emitTemplateDiag(alloc, diag, .@"error", "config.missing_field",
                        b_entry.key_ptr.*, "output_schema",
                        "output_schema is required", .{});
                    std.debug.print("---\n# {s}: config error: template '{s}': output_schema is required\n", .{ config_path, b_entry.key_ptr.* });
                    return error.MissingOutputSchema;
                }

                // Store the completed broker entry under its ID key.
                try config.brokers.put(
                    try alloc.dupe(u8, b_entry.key_ptr.*),
                    BrokerConfig{
                        .data_dir                  = data_dir,
                        .file_pattern_in           = file_pattern_in,
                        .file_pattern_out          = file_pattern_out,
                        .xlsx_sheet                = xlsx_sheet,
                        .ticker_map                = ticker_map,
                        .input_schema              = input_schema,
                        .date_filter_from_filename = date_filter_from_filename,
                        .combined_output           = combined_output,
                        .pre_passes                = pre_passes,
                        .row_rules                 = row_rules,
                        .row_rules_debug_missing   = row_rules_debug_missing,
                        .output_schema             = output_schema.?,
                        .csv_header_line           = csv_header_line,
                        .csv_delimiter_in          = csv_delimiter_in,
                        .csv_delimiter_out         = csv_delimiter_out,
                        .csv_decimal_separator_in  = csv_decimal_separator_in,
                        .csv_decimal_separator_out = csv_decimal_separator_out,
                        .csv_text_quote_in         = csv_text_quote_in,
                        .csv_text_quote_out        = csv_text_quote_out,
                        .file_type_in              = file_type_in,
                        .file_type_out             = file_type_out,
                    },
                );
            }
        }
    }

    return config;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "levenshteinIgnoreCase: distance, case-insensitivity, long-string shortcut" {
    try testing.expectEqual(@as(usize, 0), levenshteinIgnoreCase("ROUND", "round"));
    try testing.expectEqual(@as(usize, 1), levenshteinIgnoreCase("ROUNT", "ROUND"));
    try testing.expectEqual(@as(usize, 3), levenshteinIgnoreCase("kitten", "sitting"));
    try testing.expectEqual(@as(usize, 5), levenshteinIgnoreCase("", "abcde"));
    // Past the 64-char DP ceiling the helper degrades to a length-delta.
    const long_a = "a" ** 70;
    const long_b = "a" ** 65;
    try testing.expectEqual(@as(usize, 5), levenshteinIgnoreCase(long_a, long_b));
}

test "closestBuiltin: near typo resolves, far string is rejected" {
    // One edit from ROUND → suggested.
    try testing.expectEqualStrings("ROUND", closestBuiltin("ROUNT").?);
    // Case-insensitive match still snaps to the canonical catalog spelling.
    try testing.expectEqualStrings("ABS", closestBuiltin("abx").?);
    // Three+ edits away from every builtin → no suggestion.
    try testing.expect(closestBuiltin("zzzzzzzzzz") == null);
}

test "closestKey: did-you-mean over an explicit candidate list" {
    const candidates = [_][]const u8{ "data_dir", "file_pattern_in", "input_schema" };
    try testing.expectEqualStrings("data_dir", closestKey("data_dur", &candidates).?);
    try testing.expectEqualStrings("input_schema", closestKey("input_schena", &candidates).?);
    try testing.expect(closestKey("totally_unrelated", &candidates) == null);
}

test "suffixOverlap: documented file_pattern_in overlap cases" {
    // Equal or one-is-suffix-of-other → overlap.
    try testing.expect(suffixOverlap(".csv", "_closed.csv"));
    try testing.expect(suffixOverlap("_closed.csv", ".csv"));
    try testing.expect(suffixOverlap(".csv", ".csv"));
    // Two distinct full suffixes → no overlap.
    try testing.expect(!suffixOverlap("_closed.csv", "_cash.csv"));
    // Empty operands never overlap.
    try testing.expect(!suffixOverlap("", ".csv"));
}

test "isAnnotationKey: only the four reserved $-prefixes match" {
    try testing.expect(isAnnotationKey("$err_0"));
    try testing.expect(isAnnotationKey("$warn_12"));
    try testing.expect(isAnnotationKey("$info_3"));
    try testing.expect(isAnnotationKey("$comm_7"));
    // A normal template variable is not an annotation key.
    try testing.expect(!isAnnotationKey("$date"));
    try testing.expect(!isAnnotationKey("data_dir"));
}

test "containsString" {
    const hay = [_][]const u8{ "alpha", "beta", "gamma" };
    try testing.expect(containsString(&hay, "beta"));
    try testing.expect(!containsString(&hay, "delta"));
    try testing.expect(!containsString(&.{}, "anything"));
}

test "extractQuotedName: pulls the first single-quoted token, else null" {
    try testing.expectEqualStrings("Total", extractQuotedName("LOOKUP([x], 'Total')").?);
    try testing.expectEqualStrings("", extractQuotedName("a '' b").?); // empty quotes
    try testing.expect(extractQuotedName("no quotes here") == null);
    try testing.expect(extractQuotedName("'unterminated") == null); // lone quote
}

test "jsonErrorDesc: maps known parse errors, falls back to @errorName" {
    try testing.expectEqualStrings(
        "duplicate key in object — remove or rename the repeated key",
        jsonErrorDesc(error.DuplicateField),
    );
    try testing.expectEqualStrings(
        "number value out of range",
        jsonErrorDesc(error.Overflow),
    );
    // Unmapped error → its name verbatim.
    try testing.expectEqualStrings("OutOfMemory", jsonErrorDesc(error.OutOfMemory));
}

// `loadFromBytes` (and its diagnostic sink) allocate into a caller-owned
// arena in production — bxp-fmt wraps a GPA in an ArenaAllocator before
// calling. Diagnostics.deinit does not free per-message strings, so these
// integration tests mirror that contract with an arena rather than the
// leak-checking testing.allocator.
test "loadFromBytes: csv-punctuation + enum fields parse through their helpers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var diag = Diagnostics.init(a);
    defer diag.deinit();

    const src =
        \\{
        \\  conversion_templates: {
        \\    demo: {
        \\      csv_delimiter_in: ";",
        \\      csv_text_quote_out: "double",
        \\      file_type_out: "json",
        \\      input_schema: { $x: "[1]" },
        \\      output_schema: { col: "$x" },
        \\    },
        \\  },
        \\}
    ;
    var config = try loadFromBytes(a, src, "<test>", &diag);
    defer config.deinit();

    const demo = config.brokers.get("demo").?;
    try testing.expectEqual(@as(u8, ';'), demo.csv_delimiter_in);
    try testing.expectEqual(@as(u8, '"'), demo.csv_text_quote_out);
    try testing.expectEqual(FileType.json, demo.file_type_out);
    // A clean config emits no diagnostics.
    try testing.expectEqual(@as(usize, 0), diag.count());
}

test "loadFromBytes: csv_header_line parses (default 1, headerless 0, preamble N)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var diag = Diagnostics.init(a);
    defer diag.deinit();

    const src =
        \\{
        \\  conversion_templates: {
        \\    deflt:      { input_schema: { $x: "1" }, output_schema: { c: "$x" } },
        \\    headerless: { csv_header_line: 0, input_schema: { $x: "1" }, output_schema: { c: "$x" } },
        \\    preamble:   { csv_header_line: 3, input_schema: { $x: "1" }, output_schema: { c: "$x" } },
        \\  },
        \\}
    ;
    var config = try loadFromBytes(a, src, "<test>", &diag);
    defer config.deinit();

    try testing.expectEqual(@as(u32, 1), config.brokers.get("deflt").?.csv_header_line);
    try testing.expectEqual(@as(u32, 0), config.brokers.get("headerless").?.csv_header_line);
    try testing.expectEqual(@as(u32, 3), config.brokers.get("preamble").?.csv_header_line);
    try testing.expectEqual(@as(usize, 0), diag.count());
}

test "loadFromBytes: invalid enum surfaces a warning but still loads with the default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var diag = Diagnostics.init(a);
    defer diag.deinit();

    const src =
        \\{
        \\  conversion_templates: {
        \\    demo: {
        \\      file_type_out: "jsno",
        \\      csv_text_quote_out: "fancy",
        \\      input_schema: { $x: "[1]" },
        \\      output_schema: { col: "$x" },
        \\    },
        \\  },
        \\}
    ;
    var config = try loadFromBytes(a, src, "<test>", &diag);
    defer config.deinit();

    const demo = config.brokers.get("demo").?;
    // Typos fall back to the documented defaults...
    try testing.expectEqual(FileType.csv, demo.file_type_out);
    try testing.expectEqual(@as(u8, 0), demo.csv_text_quote_out); // "none"
    // ...but the user is warned about each one rather than failing silently.
    try testing.expectEqual(@as(usize, 2), diag.countBySeverity(.warning));
}
