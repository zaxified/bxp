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

const CONFIG_MAX_FILE_SIZE: usize = 1024 * 1024;

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
    /// Optional first-pass lookup table.  Null when not defined in bxp-cli.json.
    pre_pass: ?PrePass,
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
        if (self.pre_pass) |pp| {
            if (pp.when.len == 0) {
                try writer.print("---\n# {s}: config error: template '{s}': pre_pass.when must not be empty\n", .{ config_path, template_id });
                return error.InvalidConfig;
            }
            if (pp.key.len == 0) {
                try writer.print("---\n# {s}: config error: template '{s}': pre_pass.key must not be empty\n", .{ config_path, template_id });
                return error.InvalidConfig;
            }
            if (pp.values.count() == 0) {
                try writer.print("---\n# {s}: config error: template '{s}': pre_pass.values must not be empty\n", .{ config_path, template_id });
                return error.InvalidConfig;
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

            // Free pre_pass strings and values map.
            if (entry.value_ptr.pre_pass) |*pp| {
                self._alloc.free(pp.when);
                self._alloc.free(pp.key);
                var pp_it = pp.values.iterator();
                while (pp_it.next()) |e| {
                    self._alloc.free(e.key_ptr.*);
                    self._alloc.free(e.value_ptr.*);
                }
                pp.values.deinit();
            }

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
fn diagDuplicateKey(
    alloc: std.mem.Allocator,
    content: []const u8,
    raw: []const u8,
    config_path: []const u8,
) bool {
    var scanner = std.json.Scanner.initCompleteInput(alloc, content);
    defer scanner.deinit();
    var diag: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);

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
                    // This string token is an object key.
                    // diag position is after the closing '"'; adjust back to the opening '"'.
                    const col_end = diag.getColumn();
                    const ln      = diag.getLine();
                    const caret_col: u64 = if (col_end >= s.len + 2) col_end - s.len - 2 else 1;

                    if (top.keys.contains(s)) {
                        // Found the first duplicate.
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
fn diagJsonError(
    alloc: std.mem.Allocator,
    content: []const u8,
    raw: []const u8,
    config_path: []const u8,
    err: anyerror,
) void {
    std.debug.print("---\n", .{});
    var scanner = std.json.Scanner.initCompleteInput(alloc, content);
    defer scanner.deinit();
    var diag: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);
    var found_pos = false;
    while (true) {
        const tok = scanner.next() catch |scan_err| {
            found_pos = true;
            const ln = diag.getLine();    // 1-based
            const col = diag.getColumn(); // 1-based
            // Use the scanner's own error for the description — it matches the shown position.
            // The `err` from parseFromSlice is only used in the no-position fallback below.
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
            if (!diagDuplicateKey(alloc, content, raw, config_path)) {
                // Fallback if duplicate scan fails (should not happen).
                std.debug.print("# {s}: JSON error — {s}\n", .{ config_path, jsonErrorDesc(err) });
            }
        } else {
            std.debug.print("# {s}: JSON error — {s}\n", .{ config_path, jsonErrorDesc(err) });
        }
    }
}

/// Reads the config file at `config_path` (relative to cwd) and returns a fully
/// populated Config.  All strings are duplicated into alloc so the caller
/// owns the memory — release with Config.deinit().
///
/// Missing file → returns an empty Config (no error).
/// Malformed JSON5 → returns an error.
pub fn load(alloc: std.mem.Allocator, config_path: []const u8) !Config {
    var config = Config{
        .brokers = std.StringArrayHashMap(BrokerConfig).init(alloc),
        ._alloc = alloc,
    };

    const file = std.fs.cwd().openFile(config_path, .{}) catch |err| {
        if (err == error.FileNotFound) return config;
        return err;
    };
    defer file.close();

    const raw = try file.readToEndAlloc(alloc, CONFIG_MAX_FILE_SIZE);
    defer alloc.free(raw);
    const content = try json5.preprocess(alloc, raw);
    defer alloc.free(content);

    // Detect duplicate object keys before parsing — std.json silently uses last value.
    if (diagDuplicateKey(alloc, content, raw, config_path)) {
        return error.InvalidConfig;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch |err| {
        diagJsonError(alloc, content, raw, config_path, err);
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
                var file_pattern_in: []const u8 = try alloc.dupe(u8, "");
                var file_pattern_out: []const u8 = try alloc.dupe(u8, "");
                var xlsx_sheet: ?XlsxSheet = null;
                var ticker_map = std.StringHashMap([]const u8).init(alloc);
                var input_schema = std.StringHashMap([]const u8).init(alloc);
                var date_filter_from_filename: bool = false;
                var pre_pass: ?PrePass = null;
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
                            alloc.free(data_dir);
                            // Resolve data_dir relative to the config file's directory.
                            const cfg_dir = std.fs.path.dirname(config_path) orelse ".";
                            data_dir = try std.fs.path.join(alloc, &.{ cfg_dir, v.string });
                        }
                    }

                    if (bobj.get("file_pattern_in")) |v| {
                        if (v == .string) {
                            alloc.free(file_pattern_in);
                            file_pattern_in = try alloc.dupe(u8, v.string);
                        }
                    }

                    if (bobj.get("file_pattern_out")) |v| {
                        if (v == .string) {
                            alloc.free(file_pattern_out);
                            file_pattern_out = try alloc.dupe(u8, v.string);
                        }
                    }

                    // xlsx_sheet: object with { name, header_row, output_suffix }
                    if (bobj.get("xlsx_sheet")) |xs_val| parse_sheet: {
                        if (xs_val != .object) break :parse_sheet;
                        const obj = xs_val.object;
                        const name = if (obj.get("name")) |v|
                            if (v == .string) try alloc.dupe(u8, v.string) else break :parse_sheet
                        else break :parse_sheet;
                        const header_row: u32 = if (obj.get("header_row")) |v|
                            switch (v) {
                                .integer => |n| @intCast(n),
                                else => break :parse_sheet,
                            }
                        else break :parse_sheet;
                        const output_suffix = if (obj.get("output_suffix")) |v|
                            if (v == .string) try alloc.dupe(u8, v.string) else break :parse_sheet
                        else break :parse_sheet;
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
                                std.debug.print(
                                    "error: template '{s}': ticker_map references unknown named map '{s}'\n",
                                    .{ b_entry.key_ptr.*, name },
                                );
                                return error.InvalidConfig;
                            },
                            .object => |obj| obj,
                            else => continue,
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

                    // pre_pass: optional first-pass lookup table built before main row loop.
                    if (bobj.get("pre_pass")) |pp_val| {
                        if (pp_val == .object) {
                            const ppobj = pp_val.object;
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
                            pre_pass = PrePass{
                                .when = when,
                                .key = pp_key,
                                .values = pp_values,
                            };
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
                        .pre_pass                  = pre_pass,
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
