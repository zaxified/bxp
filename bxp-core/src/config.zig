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
        },
        .{
            .key = "key",
            .type_name = "expression",
            .required = true,
            .description = "Expression evaluated per row to produce the lookup key string for this named block.",
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
    input_schema: std.StringHashMap([]const u8),
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
        },
        .{
            .key = "file_pattern_out",
            .type_name = "string",
            .required = true,
            .description = "Output filename suffix. Replaces file_pattern_in in the output filename.",
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
        },
        .{
            .key = "date_filter_from_filename",
            .type_name = "boolean",
            .required = false,
            .default = "false",
            .description = "When true, rows whose $date falls outside the date range encoded in the filename (YYYY-MM-DD_YYYY-MM-DD) are silently skipped. Requires $date in input_schema.",
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
        .{
            .key = "pre_pass",
            .type_name = "object",
            .required = false,
            .description = "First-pass lookup table(s) built before the main loop. Two accepted shapes: legacy single block `{ when, key, values }` (detected by the presence of `when`) — accessed via 2-arg `LOOKUP(key, 'field')`; or named blocks `{ name1: { when, key, values }, ... }` — each block is its own namespace, accessed via 3-arg `LOOKUP('name', key, 'field')`.",
            .insert_template = PrePass.scaffold_template,
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
        if (self.row_rules_debug_missing and self.row_rules == null) {
            try writer.print("---\n# {s}: config error: template '{s}': row_rules_debug_missing is true but row_rules is not defined\n", .{ config_path, template_id });
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
        // Every output_schema variable must be in input_schema or set by every row_rules rows entry.
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
        if (self.row_rules_debug_missing and self.row_rules == null)
            try errors.append(alloc, try ValidationError.init(alloc, base, "row_rules_debug_missing", "row_rules_debug_missing is true but row_rules is not defined"));
        if (self.row_rules) |rules| {
            for (rules, 0..) |rule, i| {
                if (rule.when.len == 0) {
                    const field = try std.fmt.allocPrint(alloc, "row_rules.{d}.when", .{i});
                    defer alloc.free(field);
                    try errors.append(alloc, try ValidationError.init(alloc, base, field, "row_rules entry has empty 'when'"));
                }
            }
        }
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
};

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

    // Per-level state: is_object=true → track keys; is_object=false → array (no keys).
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
                        // Found the first duplicate. Emit a structured
                        // diagnostic for bxp-fmt before printing to
                        // stderr (bxp-cli's existing behavior).
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
/// can produce a descriptive error path including the block name.
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

/// Parse + validate a config from in-memory JSON5 bytes. The path label
/// is only used in diagnostic messages — pass an arbitrary marker
/// (`"<inline>"`, `"test"`, …) when the source isn't a real file. Carved
/// out of `load()` so `bxp-fmt --config` can avoid double-reading the
/// file (it already has the raw bytes for `preprocessAnnotated`) and so
/// inline tests can exercise the loader without touching disk.
///
/// `diag` is an optional structured diagnostic sink. When non-null,
/// future phases will append path-aware errors / warnings into it
/// alongside the existing `std.debug.print` + `return error` behavior.
/// bxp-cli passes null so its load path is unchanged bit by bit; only
/// bxp-fmt's deep-validation pass passes a non-null sink today.
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

    // Detect duplicate object keys before parsing — std.json silently uses last value.
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
                var input_schema = std.StringHashMap([]const u8).init(alloc);
                var date_filter_from_filename: bool = false;
                var pre_passes = std.StringArrayHashMap(PrePass).init(alloc);
                var row_rules: ?[]RowRule = null;
                var row_rules_debug_missing: bool = false;
                var output_schema: ?std.array_list.Managed(OutputColumn) = null;
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
                            // Allocate before freeing the old default — if join
                            // OOMs, the errdefer above must still see a valid
                            // pointer in `data_dir`.
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
                        if (v == .bool) date_filter_from_filename = v.bool;
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
                        if (v == .bool) row_rules_debug_missing = v.bool;
                    }

                    // row_rules: ordered list of conditional routing rules.
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
                            if (rr_list.items.len > 0) {
                                row_rules = try rr_list.toOwnedSlice();
                            } else {
                                rr_list.deinit();
                            }
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
                    // csv_delimiter_in / csv_delimiter_out / csv_decimal_separator_in / csv_decimal_separator_out
                    // Each must be a single-character string; silently ignored if wrong length.
                    if (bobj.get("csv_delimiter_in")) |v| {
                        if (v == .string and v.string.len == 1) csv_delimiter_in = v.string[0];
                    }
                    if (bobj.get("csv_delimiter_out")) |v| {
                        if (v == .string and v.string.len == 1) csv_delimiter_out = v.string[0];
                    }
                    if (bobj.get("csv_decimal_separator_in")) |v| {
                        if (v == .string and v.string.len == 1) csv_decimal_separator_in = v.string[0];
                    }
                    if (bobj.get("csv_decimal_separator_out")) |v| {
                        if (v == .string and v.string.len == 1) csv_decimal_separator_out = v.string[0];
                    }
                    if (bobj.get("csv_text_quote_in")) |v| {
                        if (v == .string) {
                            csv_text_quote_in = if (std.mem.eql(u8, v.string, "single")) '\''
                                else if (std.mem.eql(u8, v.string, "double")) '"'
                                else 0;
                        }
                    }
                    if (bobj.get("csv_text_quote_out")) |v| {
                        if (v == .string) {
                            csv_text_quote_out = if (std.mem.eql(u8, v.string, "single")) '\''
                                else if (std.mem.eql(u8, v.string, "double")) '"'
                                else 0;
                        }
                    }
                    if (bobj.get("file_type_in")) |v| {
                        if (v == .string)
                            file_type_in = if (std.mem.eql(u8, v.string, "json")) .json else .csv;
                    }
                    if (bobj.get("file_type_out")) |v| {
                        if (v == .string)
                            file_type_out = if (std.mem.eql(u8, v.string, "json")) .json else .csv;
                    }
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
                        .pre_passes                = pre_passes,
                        .row_rules                 = row_rules,
                        .row_rules_debug_missing   = row_rules_debug_missing,
                        .output_schema             = output_schema.?,
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
