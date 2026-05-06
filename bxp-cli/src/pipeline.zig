/// Processing pipeline for bxp-cli: per-template file conversion and xlsx pre-pass.
///
/// Owns the core data-processing logic: reading input files, evaluating expressions,
/// applying row rules, and writing output.  CLI argument parsing and config loading
/// live in main.zig; all types that main.zig needs are exported as pub.

const std = @import("std");
const csv = @import("csv");
const config_mod = @import("config");
const expr_mod = @import("expr");
const xlsx_mod = @import("xlsx");
const json_mod = @import("json");

const MAX_FILE_SIZE_BYTES: usize = 16 * 1024 * 1024;
const MAX_COLUMNS: usize = 64;
const OUT_FILE_BUF_SIZE: usize = 65536;
const VAL_BUF_SIZE: usize = 64;
/// Runtime key for the date variable in the merged vars map (JSON5 converts @date → $date).
const VAR_DATE: []const u8 = "$date";

pub const Stdout = std.Io.Writer;

/// Accumulated warnings and errors for one processing section (xlsx preprocessing,
/// per-template processing, or overall).
pub const SectionStats = struct {
    warnings: u32 = 0,
    has_fatal: bool = false,
    /// Wall-clock nanoseconds elapsed during this section (set by the owning function).
    time_ns: u64 = 0,

    pub fn merge(self: *SectionStats, other: SectionStats) void {
        self.warnings += other.warnings;
        if (other.has_fatal) self.has_fatal = true;
        self.time_ns += other.time_ns;
    }
};

/// Output wrapper that suppresses all writes when --quiet or --trace is active.
/// All methods silently drop write errors (same pattern as existing debug prints).
/// When --trace is active, human-readable lines are suppressed so that stdout
/// contains only newline-delimited JSON (NDJSON) trace events.
pub const Output = struct {
    writer: *Stdout,
    quiet: bool,
    debug: bool,
    trace: bool = false,
    dry_run: bool = false,

    /// Print an informational line. Suppressed in --quiet or --trace mode.
    pub fn info(self: Output, comptime fmt: []const u8, args: anytype) void {
        if (self.quiet or self.trace) return;
        self.writer.print(fmt, args) catch {};
        self.writer.flush() catch {};
    }

    /// Print a warning line. Suppressed in --quiet or --trace mode.
    pub fn warning(self: Output, comptime fmt: []const u8, args: anytype) void {
        if (self.quiet or self.trace) return;
        self.writer.print(fmt, args) catch {};
        self.writer.flush() catch {};
    }

    /// Print a fatal-error line. Suppressed in --quiet or --trace mode.
    pub fn fatal(self: Output, comptime fmt: []const u8, args: anytype) void {
        if (self.quiet or self.trace) return;
        self.writer.print(fmt, args) catch {};
        self.writer.flush() catch {};
    }

    /// Print a per-section summary line. Suppressed in --quiet or --trace mode.
    pub fn summary(self: Output, stats: SectionStats) void {
        if (self.quiet or self.trace) return;
        const errors: u32 = if (stats.has_fatal) 1 else 0;
        const secs = stats.time_ns / 1_000_000_000;
        const ms = (stats.time_ns % 1_000_000_000) / 1_000_000;
        self.writer.print("summary: errors:{d} warnings:{d} time:{d}.{d:0>3}s\n", .{ errors, stats.warnings, secs, ms }) catch {};
        self.writer.flush() catch {};
    }

    /// Print the overall summary line (no leading "summary:" label).
    /// Suppressed in --quiet or --trace mode.
    pub fn overallLine(self: Output, stats: SectionStats) void {
        if (self.quiet or self.trace) return;
        const errors: u32 = if (stats.has_fatal) 1 else 0;
        const secs = stats.time_ns / 1_000_000_000;
        const ms = (stats.time_ns % 1_000_000_000) / 1_000_000;
        self.writer.print("errors:{d} warnings:{d} time:{d}.{d:0>3}s\n", .{ errors, stats.warnings, secs, ms }) catch {};
        self.writer.flush() catch {};
    }

    /// Emit one NDJSON event on stdout. No-op unless --trace is active.
    /// The caller provides an anonymous struct whose fields are merged into the event
    /// object alongside `"t": t_name`. `std.json.Stringify` handles string escaping.
    /// Errors are swallowed (same pattern as info/warning/fatal).
    pub fn event(self: Output, comptime t_name: []const u8, args: anytype) void {
        if (!self.trace) return;
        var jw: std.json.Stringify = .{ .writer = self.writer, .options = .{} };
        jw.beginObject() catch return;
        jw.objectField("t") catch return;
        jw.write(t_name) catch return;
        inline for (std.meta.fields(@TypeOf(args))) |field| {
            jw.objectField(field.name) catch return;
            jw.write(@field(args, field.name)) catch return;
        }
        jw.endObject() catch return;
        self.writer.writeByte('\n') catch return;
        self.writer.flush() catch return;
    }
};

/// Returns true if s looks like a valid YYYY-MM-DD date string.
fn isDate(s: []const u8) bool {
    if (s.len != 10) return false;
    if (s[4] != '-' or s[7] != '-') return false;
    for (s[0..4]) |c| if (!std.ascii.isDigit(c)) return false;
    for (s[5..7]) |c| if (!std.ascii.isDigit(c)) return false;
    for (s[8..10]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

const DateRange = struct { min: []const u8, max: []const u8 };

/// Searches for "YYYY-MM-DD_YYYY-MM-DD" anywhere in the file stem (without extension).
/// Returns slices into stem — no allocation.
fn extractDateRange(stem: []const u8) ?DateRange {
    if (stem.len < 21) return null;
    var i: usize = 0;
    while (i + 21 <= stem.len) : (i += 1) {
        const s = stem[i..];
        if (isDate(s[0..10]) and s[10] == '_' and isDate(s[11..21])) {
            return .{ .min = s[0..10], .max = s[11..21] };
        }
    }
    return null;
}

/// Returns true when s is a plain decimal number: optional '-', digits,
/// optional '.' followed by more digits — nothing else.
fn isNumericValue(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[i] == '-') i += 1;
    if (i >= s.len or !std.ascii.isDigit(s[i])) return false;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    }
    return i == s.len;
}

/// Writes value to out.
///
/// When quote_out != 0 and the value contains the output delimiter, the quote
/// character, \r, or \n, the value is wrapped in quote_out characters and any
/// internal occurrences of quote_out are doubled (RFC 4180 §2.5–2.7).
///
/// When no quoting is applied: values starting with a spreadsheet formula
/// character ('=', '+', '-', '@') get a leading single-quote to neutralise
/// injection; embedded \n is replaced with the literal two-char sequence \n;
/// \r bytes are dropped.
///
/// When decimal_sep_out != '.', numeric values have their '.' replaced with
/// decimal_sep_out before writing.
fn writeSafeValue(out: *Stdout, value: []const u8, delimiter_out: u8, decimal_sep_out: u8, quote_out: u8, buf: []u8) !void {
    // Apply decimal separator conversion for numeric output values.
    const s = blk: {
        if (decimal_sep_out != '.' and value.len <= buf.len and isNumericValue(value)) {
            @memcpy(buf[0..value.len], value);
            std.mem.replaceScalar(u8, buf[0..value.len], '.', decimal_sep_out);
            break :blk buf[0..value.len];
        }
        break :blk value;
    };
    // RFC 4180 output quoting: wrap when value contains the delimiter, the
    // quote character, CR, or LF.  Internal quote chars are doubled.
    // Pre-quoted pass-through: a value that already starts and ends with quote_out
    // (produced by ''' expressions) is written with its outer quotes preserved and
    // any internal occurrences of quote_out doubled (RFC 4180 §2.5).
    if (quote_out != 0 and s.len >= 2 and s[0] == quote_out and s[s.len - 1] == quote_out) {
        try out.writeByte(quote_out);
        for (s[1 .. s.len - 1]) |ch| {
            if (ch == quote_out) try out.writeByte(quote_out);
            try out.writeByte(ch);
        }
        try out.writeByte(quote_out);
        return;
    }
    if (quote_out != 0) {
        var needs_quote = false;
        for (s) |ch| {
            if (ch == delimiter_out or ch == quote_out or ch == '\r' or ch == '\n') {
                needs_quote = true;
                break;
            }
        }
        if (needs_quote) {
            try out.writeByte(quote_out);
            for (s) |ch| {
                if (ch == quote_out) try out.writeByte(quote_out); // escape: double it
                try out.writeByte(ch);
            }
            try out.writeByte(quote_out);
            return;
        }
    }
    // No quoting applied: formula-injection prefix + \n→\n literal replacement.
    if (s.len > 0) {
        switch (s[0]) {
            '=', '+', '@' => try out.writeByte('\''),
            '-' => {
                const next_is_numeric = s.len > 1 and
                    (std.ascii.isDigit(s[1]) or s[1] == decimal_sep_out);
                if (!next_is_numeric) try out.writeByte('\'');
            },
            else => {},
        }
    }
    for (s) |ch| {
        switch (ch) {
            '\n' => try out.writeAll("\\n"),
            '\r' => {},
            else => try out.writeByte(ch),
        }
    }
}

/// Writes a JSON object row to out.
/// Format: {"col1":"val1","col2":"val2",...}
/// All values are emitted as JSON strings.  Special characters are escaped.
fn writeJsonRow(
    out: *Stdout,
    columns: []const config_mod.OutputColumn,
    vars: *const std.StringHashMap([]const u8),
) !void {
    try out.writeByte('{');
    for (columns, 0..) |col, ci| {
        if (ci > 0) try out.writeByte(',');
        try out.writeByte('"');
        try writeJsonString(out, col.header);
        try out.writeAll("\":\"");
        try writeJsonString(out, vars.get(col.variable) orelse "");
        try out.writeByte('"');
    }
    try out.writeByte('}');
}

/// Writes s to out with JSON string escaping (RFC 8259 §7).
fn writeJsonString(out: *Stdout, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            // Other C0 control characters (excluding \n=0x0a, \r=0x0d, \t=0x09):
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var buf: [6]u8 = undefined;
                const esc = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{@as(u32, ch)}) catch unreachable; // buf is [6]u8; "\uXXXX" is always 6 bytes
                try out.writeAll(esc);
            },
            else => try out.writeByte(ch),
        }
    }
}

/// Evaluates all input_schema expressions for the current row into a variable map.
/// Keys are variable names (owned by config); values are allocated with ctx.alloc.
/// On expression error the variable is stored as empty string.
/// In debug mode, every error is printed before being suppressed.
/// Saves and restores ctx.error_detail so the caller's detail buffer is unaffected.
fn evalAllVars(
    schema: std.StringHashMap([]const u8),
    ctx: *expr_mod.Context,
    out: Output,
) !std.StringHashMap([]const u8) {
    var vars = std.StringHashMap([]const u8).init(ctx.alloc);
    var detail: []const u8 = "";
    const saved_detail = ctx.error_detail;
    ctx.error_detail = &detail;
    defer ctx.error_detail = saved_detail;
    var it = schema.iterator();
    while (it.next()) |e| {
        detail = "";
        const val = expr_mod.evalString(e.value_ptr.*, ctx) catch |err| blk: {
            if (out.debug) {
                if (detail.len > 0) {
                    out.writer.print("[expr error] {s} = \"{s}\": {s} ({s})\n  fields:", .{ e.key_ptr.*, e.value_ptr.*, @errorName(err), detail }) catch {};
                } else {
                    out.writer.print("[expr error] {s} = \"{s}\": {s}\n  fields:", .{ e.key_ptr.*, e.value_ptr.*, @errorName(err) }) catch {};
                }
                for (ctx.fields) |f| {
                    out.writer.print(" \"{s}\"", .{f}) catch {};
                }
                out.writer.print("\n", .{}) catch {};
                out.writer.flush() catch {};
            }
            out.event("var_error", .{ .name = e.key_ptr.*, .expr = e.value_ptr.*, .@"error" = @errorName(err), .detail = detail });
            break :blk "";
        };
        out.event("var_eval", .{ .name = e.key_ptr.*, .expr = e.value_ptr.*, .value = val });
        try vars.put(e.key_ptr.*, val);
    }
    return vars;
}

/// Processes all matching input files in dir_path for the given template.
/// For each file:
///   1. Extracts optional date range from the filename.
///   2. Reads and parses input (CSV or JSON); builds col_index from the header/keys.
///   3. Builds pre_pass lookup table if configured.
///   4. Evaluates input_schema expressions per row and writes output (CSV or JSON).
/// Returns accumulated SectionStats for this template.
pub fn processBroker(
    bid: []const u8,
    dir_path: []const u8,
    bc: *const config_mod.BrokerConfig,
    fresh: bool,
    out: Output,
    alloc: std.mem.Allocator,
) !SectionStats {
    var stats = SectionStats{};
    var timer = try std.time.Timer.start();

    out.info("\n=== template: {s} ===\n", .{bid});

    // Open the data directory; print a clean message if it doesn't exist.
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            out.fatal("error: directory not found: '{s}'\n", .{dir_path});
            stats.has_fatal = true;
            stats.time_ns = timer.read();
            return stats;
        }
        return err;
    };
    defer dir.close();

    // Collect matching .csv filenames first to avoid iterator/create conflicts.
    const csv_suffix: []const u8 = bc.file_pattern_in;
    var names = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit();
    }
    {
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!std.mem.endsWith(u8, entry.name, csv_suffix)) continue;
            try names.append(try alloc.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    if (names.items.len == 0) {
        out.info("No input files for template '{s}' in '{s}'\n", .{ bid, dir_path });
        stats.time_ns = timer.read();
        return stats;
    }

    for (names.items) |filename| {
        // Per-file arena: owns file content, parsed lines, prepare context, output filename.
        // Freed automatically at the end of each file iteration.
        var file_arena = std.heap.ArenaAllocator.init(alloc);
        defer file_arena.deinit();
        const file_alloc = file_arena.allocator();

        // Extract date range from filename when date_filter_from_filename is enabled.
        // Strip file_pattern_in from the filename to get the stem for date extraction.
        // Empty strings = no filtering.
        const stem = if (filename.len > bc.file_pattern_in.len)
            filename[0 .. filename.len - bc.file_pattern_in.len]
        else
            filename;
        const dr = if (bc.date_filter_from_filename) extractDateRange(stem) else null;
        const date_min: []const u8 = if (dr) |r| r.min else "";
        const date_max: []const u8 = if (dr) |r| r.max else "";
        if (dr) |r| {
            out.info("processing '{s}' with date range from {s} to {s}\n", .{ filename, r.min, r.max });
        } else {
            out.info("processing '{s}'\n", .{filename});
        }

        // Read entire input file into memory (max 16 MB).
        const in_file = try dir.openFile(filename, .{});
        defer in_file.close();
        const content_raw = try in_file.readToEndAlloc(file_alloc, MAX_FILE_SIZE_BYTES);
        // Strip UTF-8 BOM (EF BB BF) if present — common in Windows/Excel exports.
        const content = if (std.mem.startsWith(u8, content_raw, "\xEF\xBB\xBF"))
            content_raw[3..]
        else
            content_raw;
        // Warn if the file is not valid UTF-8 — processing continues but field
        // values with non-ASCII bytes may be garbled (e.g. Windows-1250 exports).
        if (!std.unicode.utf8ValidateSlice(content)) {
            stats.warnings += 1;
            out.warning("warning: '{s}' is not valid UTF-8; non-ASCII characters may be garbled\n", .{filename});
        }

        // Parse input into a unified row representation: all_rows is a list of field
        // string arrays.  col_index and col_names are built from the header / object keys.
        // CSV: splitRecords() + splitFields() into file_alloc so rows survive the loop.
        // JSON: json_mod.readJsonRecords() converts objects to string arrays.
        var col_index = std.StringHashMap(usize).init(file_alloc);
        var col_names = std.array_list.Managed([]const u8).init(file_alloc);
        var all_rows = std.array_list.Managed([][]const u8).init(file_alloc);

        if (bc.file_type_in == .json) {
            try json_mod.readJsonRecords(file_alloc, content, &col_names, &all_rows);
            for (col_names.items, 0..) |name, idx| try col_index.put(name, idx);
        } else {
            // CSV: split into records, parse header, pre-allocate all field arrays into
            // file_alloc so they persist for the full file lifetime (pre_pass + main loop).
            const all_records = try csv.splitRecords(content, bc.csv_text_quote_in, file_alloc);
            if (all_records.items.len > 0) {
                const hdr_buf = try file_alloc.alloc([]const u8, MAX_COLUMNS);
                const header_fields = try csv.splitFields(
                    all_records.items[0],
                    hdr_buf,
                    bc.csv_delimiter_in,
                    bc.csv_text_quote_in,
                    file_alloc,
                );
                if (header_fields.len == hdr_buf.len) {
                    stats.warnings += 1;
                    out.warning("warning: '{s}' has {d}+ columns; extra columns beyond {d} are ignored\n", .{ filename, MAX_COLUMNS, MAX_COLUMNS });
                }
                for (header_fields, 0..) |name, idx| {
                    // Intentional RFC 4180 deviation: trim spaces from column header
                    // names so that [ColumnName] references work regardless of padding.
                    const trimmed = std.mem.trim(u8, name, " ");
                    try col_index.put(trimmed, idx);
                    try col_names.append(trimmed);
                }
                for (all_records.items[1..]) |line| {
                    const row_buf = try file_alloc.alloc([]const u8, MAX_COLUMNS);
                    const fields = try csv.splitFields(
                        line,
                        row_buf,
                        bc.csv_delimiter_in,
                        bc.csv_text_quote_in,
                        file_alloc,
                    );
                    try all_rows.append(fields);
                }
            }
        }

        // Warn if the file has no data rows (detail printed only in --debug mode).
        if (all_rows.items.len == 0) {
            stats.warnings += 1;
            if (out.debug) {
                out.writer.print("warning: no rows in '{s}' (template: {s}, file: {s}/{s})\n", .{ filename, bid, dir_path, filename }) catch {};
                out.writer.flush() catch {};
            }
        }

        const full_path = try std.fs.path.join(file_alloc, &.{ dir_path, filename });
        var out_header_names = std.array_list.Managed([]const u8).init(file_alloc);
        for (bc.output_schema.items) |col| {
            try out_header_names.append(col.header);
        }
        out.event("file_start", .{
            .template = bid,
            .path = full_path,
            .rows = all_rows.items.len,
            .headers = col_names.items,
            .output_headers = out_header_names.items,
        });

        // Build pre_pass lookup table if configured.
        // Iterates all rows, evaluates when, and stores values under
        // composite keys "key\x00field_name" for use by LOOKUP() in input_schema.
        var lookup_table = std.StringHashMap([]const u8).init(file_alloc);
        if (bc.pre_pass) |pp| {
            for (all_rows.items) |fields| {
                const pre_ctx = expr_mod.Context{
                    .fields = fields,
                    .col_index = &col_index,
                    .quote_out = bc.csv_text_quote_out,
                    .ticker_map = &bc.ticker_map,
                    .lookup_table = null, // no self-reference during pre_pass
                    .alloc = file_alloc,
                    .decimal_sep_in = bc.csv_decimal_separator_in,
                };
                // Collect only rows where when evaluates to true.
                const when = expr_mod.eval(pp.when, &pre_ctx) catch |err| {
                    if (out.debug) {
                        out.writer.print("[pre_pass error] when = \"{s}\": {s}\n", .{ pp.when, @errorName(err) }) catch {};
                        out.writer.flush() catch {};
                    }
                    continue;
                };
                if (!when.toBool()) continue;
                // Evaluate key expression for this row.
                const key_val = expr_mod.evalString(pp.key, &pre_ctx) catch |err| {
                    if (out.debug) {
                        out.writer.print("[pre_pass error] key = \"{s}\": {s}\n", .{ pp.key, @errorName(err) }) catch {};
                        out.writer.flush() catch {};
                    }
                    continue;
                };
                if (key_val.len == 0) continue;
                // Store each value expression under "key\x00field_name".
                var v_it = pp.values.iterator();
                while (v_it.next()) |ve| {
                    const val = expr_mod.evalString(ve.value_ptr.*, &pre_ctx) catch |err| {
                        if (out.debug) {
                            out.writer.print("[pre_pass error] values.{s} = \"{s}\": {s}\n", .{ ve.key_ptr.*, ve.value_ptr.*, @errorName(err) }) catch {};
                            out.writer.flush() catch {};
                        }
                        continue;
                    };
                    const composite = try std.mem.concat(file_alloc, u8, &.{ key_val, "\x00", ve.key_ptr.* });
                    try lookup_table.put(composite, val);
                    out.event("prepass_set", .{ .key = key_val, .field = ve.key_ptr.*, .value = val });
                }
            }
        }
        const lookup_table_ptr: ?*const std.StringHashMap([]const u8) =
            if (bc.pre_pass != null) &lookup_table else null;

        // Open output file and write the output header (CSV) or opening bracket (JSON).
        // When file_pattern_out is set, strip file_pattern_in from the input filename
        // and replace it with file_pattern_out; otherwise append "x" (foo.csv → foo.csvx).
        const out_name = if (bc.file_pattern_out.len > 0 and
            std.mem.endsWith(u8, filename, bc.file_pattern_in))
            try std.mem.concat(file_alloc, u8, &.{
                filename[0 .. filename.len - bc.file_pattern_in.len],
                bc.file_pattern_out,
            })
        else
            try std.mem.concat(file_alloc, u8, &.{ filename, "x" });
        // --fresh: skip this file if the output already exists.
        if (fresh) {
            const exists = blk: {
                dir.access(out_name, .{}) catch |e| {
                    if (e == error.FileNotFound) break :blk false;
                    return e;
                };
                break :blk true;
            };
            if (exists) {
                out.info("  skipping '{s}' (output exists)\n", .{filename});
                continue;
            }
        }

        // Output sink: real file, or Discarding writer under --dry-run.
        var out_file: std.fs.File = undefined;
        var out_file_buf: [OUT_FILE_BUF_SIZE]u8 = undefined;
        var out_fw: std.fs.File.Writer = undefined;
        var discarding: std.Io.Writer.Discarding = undefined;
        const fout: *std.Io.Writer = if (out.dry_run) blk: {
            discarding = .init(&out_file_buf);
            break :blk &discarding.writer;
        } else blk: {
            out_file = try dir.createFile(out_name, .{});
            out_fw = out_file.writer(&out_file_buf);
            break :blk &out_fw.interface;
        };
        defer if (!out.dry_run) out_file.close();
        const delim_out = &[_]u8{bc.csv_delimiter_out};
        if (bc.file_type_out == .json) {
            try fout.writeAll("[\n");
        } else {
            for (bc.output_schema.items, 0..) |col, ci| {
                if (ci > 0) try fout.writeAll(delim_out);
                try fout.writeAll(col.header);
            }
            try fout.writeAll("\n");
        }

        // Per-row arena: reset each iteration to reclaim expr evaluation allocations.
        var line_arena = std.heap.ArenaAllocator.init(alloc);
        defer line_arena.deinit();
        const line_alloc = line_arena.allocator();

        var json_first_row = true;
        var file_rows_written: usize = 0;
        for (all_rows.items, 0..) |fields, row_idx| {
            _ = line_arena.reset(.retain_capacity);
            out.event("row_start", .{ .file_row = row_idx + 1, .fields = fields });

            var row_detail: []const u8 = "";
            var row_ctx = expr_mod.Context{
                .fields = fields,
                .col_index = &col_index,
                .quote_out = bc.csv_text_quote_out,
                .ticker_map = &bc.ticker_map,
                .lookup_table = lookup_table_ptr,
                .alloc = line_alloc,
                .decimal_sep_in = bc.csv_decimal_separator_in,
                .error_detail = &row_detail,
            };

            // Evaluate all input_schema variables for this row.
            var vars = try evalAllVars(bc.input_schema, &row_ctx, out);

            // Row rules: first matching rule determines what to emit.
            const rules = bc.row_rules orelse &.{};
            var rule_matched = false;
            var matched_rule_index: usize = 0;
            for (rules, 0..) |rule, rule_index| {
                row_detail = "";
                const when_val = expr_mod.eval(rule.when, &row_ctx) catch |err| {
                    if (out.debug) {
                        if (row_detail.len > 0) {
                            out.writer.print("[row_rules when error] \"{s}\": {s} ({s})\n", .{ rule.when, @errorName(err), row_detail }) catch {};
                        } else {
                            out.writer.print("[row_rules when error] \"{s}\": {s}\n", .{ rule.when, @errorName(err) }) catch {};
                        }
                        out.writer.flush() catch {};
                    }
                    out.event("rule_no_match", .{ .rule_index = rule_index, .when = rule.when, .@"error" = @errorName(err) });
                    continue;
                };
                if (!when_val.toBool()) {
                    out.event("rule_no_match", .{ .rule_index = rule_index, .when = rule.when });
                    continue;
                }
                rule_matched = true;
                matched_rule_index = rule_index;
                if (out.trace) emit_rule_match: {
                    var jw: std.json.Stringify = .{ .writer = out.writer, .options = .{} };
                    jw.beginObject() catch break :emit_rule_match;
                    jw.objectField("t") catch break :emit_rule_match;
                    jw.write("rule_match") catch break :emit_rule_match;
                    jw.objectField("rule_index") catch break :emit_rule_match;
                    jw.write(rule_index) catch break :emit_rule_match;
                    jw.objectField("when") catch break :emit_rule_match;
                    jw.write(rule.when) catch break :emit_rule_match;
                    jw.objectField("rows") catch break :emit_rule_match;
                    jw.beginArray() catch break :emit_rule_match;
                    for (rule.rows) |row_override| {
                        jw.beginObject() catch break :emit_rule_match;
                        var it = row_override.iterator();
                        while (it.next()) |entry| {
                            jw.objectField(entry.key_ptr.*) catch break :emit_rule_match;
                            jw.write(entry.value_ptr.*) catch break :emit_rule_match;
                        }
                        jw.endObject() catch break :emit_rule_match;
                    }
                    jw.endArray() catch break :emit_rule_match;
                    jw.endObject() catch break :emit_rule_match;
                    out.writer.writeByte('\n') catch break :emit_rule_match;
                    out.writer.flush() catch break :emit_rule_match;
                }
                // Empty rows slice = silent skip.
                for (rule.rows) |row_override| {
                    // Start from base vars, then apply per-row overrides.
                    var merged = std.StringHashMap([]const u8).init(line_alloc);
                    var base_it = vars.iterator();
                    while (base_it.next()) |e| try merged.put(e.key_ptr.*, e.value_ptr.*);
                    var ov_it = row_override.iterator();
                    while (ov_it.next()) |e| {
                        row_detail = "";
                        const val = expr_mod.evalString(e.value_ptr.*, &row_ctx) catch |err| blk: {
                            if (out.debug) {
                                if (row_detail.len > 0) {
                                    out.writer.print("[row_rules error] {s} = \"{s}\": {s} ({s})\n", .{ e.key_ptr.*, e.value_ptr.*, @errorName(err), row_detail }) catch {};
                                } else {
                                    out.writer.print("[row_rules error] {s} = \"{s}\": {s}\n", .{ e.key_ptr.*, e.value_ptr.*, @errorName(err) }) catch {};
                                }
                                out.writer.flush() catch {};
                            }
                            out.event("var_error", .{ .name = e.key_ptr.*, .expr = e.value_ptr.*, .@"error" = @errorName(err), .detail = row_detail });
                            break :blk "";
                        };
                        out.event("var_eval", .{ .name = e.key_ptr.*, .expr = e.value_ptr.*, .value = val });
                        try merged.put(e.key_ptr.*, val);
                    }
                    // Date range filter.
                    const date_str = merged.get(VAR_DATE) orelse "";
                    if (date_min.len > 0 and date_str.len >= 10 and
                        std.mem.order(u8, date_str[0..10], date_min) == .lt) {
                        out.event("row_filtered", .{ .reason = "date_filter_from_filename" });
                        continue;
                    }
                    if (date_max.len > 0 and date_str.len >= 10 and
                        std.mem.order(u8, date_str[0..10], date_max) == .gt) {
                        out.event("row_filtered", .{ .reason = "date_filter_from_filename" });
                        continue;
                    }
                    // Collect output values for trace emission.
                    var out_values: std.ArrayList([]const u8) = .empty;
                    for (bc.output_schema.items) |col| {
                        try out_values.append(line_alloc, merged.get(col.variable) orelse "");
                    }
                    if (bc.file_type_out == .json) {
                        if (!json_first_row) try fout.writeAll(",\n");
                        json_first_row = false;
                        try writeJsonRow(fout, bc.output_schema.items, &merged);
                    } else {
                        var val_buf: [VAL_BUF_SIZE]u8 = undefined;
                        for (bc.output_schema.items, 0..) |col, ci| {
                            if (ci > 0) try fout.writeAll(delim_out);
                            try writeSafeValue(fout, merged.get(col.variable) orelse "", bc.csv_delimiter_out, bc.csv_decimal_separator_out, bc.csv_text_quote_out, &val_buf);
                        }
                        try fout.writeAll("\n");
                    }
                    out.event("row_output", .{ .values = out_values.items });
                    file_rows_written += 1;
                }
                break; // first matching rule wins
            }
            // Emit rule_no_match for rules that were never evaluated (after the match).
            if (rule_matched) {
                for (rules[matched_rule_index + 1 ..], matched_rule_index + 1 ..) |rule, ri| {
                    out.event("rule_no_match", .{ .rule_index = ri, .when = rule.when });
                }
            }
            if (!rule_matched) {
                // No rule matched — show as debug record if configured.
                if (bc.row_rules_debug_missing and out.debug) {
                    out.writer.print("[{s}] unmatched row (no row_rules entry):\n{{\n", .{bid}) catch {};
                    for (col_names.items, 0..) |col_name, ci| {
                        const val = if (ci < fields.len) fields[ci] else "";
                        const sep: []const u8 = if (ci + 1 < col_names.items.len) "," else "";
                        out.writer.print("  \"{s}\": \"{s}\"{s}\n", .{ col_name, val, sep }) catch {};
                    }
                    out.writer.print("}}\n", .{}) catch {};
                    out.writer.flush() catch {};
                }
            }
            out.event("row_end", .{});
        }

        if (bc.file_type_out == .json) try fout.writeAll("\n]\n");
        try fout.flush();

        out.event("file_end", .{
            .template = bid,
            .path = full_path,
            .stats = .{
                .rows = all_rows.items.len,
                .written = file_rows_written,
                .errors = @as(u32, 0),
                .warnings = @as(u32, 0),
            },
        });
    }

    stats.time_ns = timer.read();
    return stats;
}

/// Converts xlsx files to intermediate CSV before the main processing loop.
///
/// Groups SheetSpecs by data_dir so each xlsx file is extracted only once,
/// even when multiple templates share the same directory.
/// Prints its own section header and summary when any xlsx files were found.
/// Returns accumulated SectionStats for this pre-pass.
pub fn xlsxPrePass(
    cfg: *const config_mod.Config,
    alloc: std.mem.Allocator,
    out: Output,
    fresh: bool,
    template_id: ?[]const u8,
    dir_path_arg: ?[]const u8,
) !SectionStats {
    var xlsx_stats = SectionStats{};
    var timer = try std.time.Timer.start();

    var dir_specs = std.StringArrayHashMap(std.array_list.Managed(xlsx_mod.SheetSpec)).init(alloc);
    defer {
        var ds_it = dir_specs.iterator();
        while (ds_it.next()) |e| e.value_ptr.deinit();
        dir_specs.deinit();
    }

    // Collect SheetSpecs per data_dir across all active templates.
    var bc_it = cfg.brokers.iterator();
    while (bc_it.next()) |entry| {
        const bc = entry.value_ptr;
        const sheet = bc.xlsx_sheet orelse continue;

        // Resolve effective data_dir: the dir_path_arg override applies only
        // to the selected template when --template is used.
        const dir_path: []const u8 = if (template_id) |tid| blk: {
            if (!std.mem.eql(u8, tid, entry.key_ptr.*)) continue;
            break :blk dir_path_arg orelse bc.data_dir;
        } else bc.data_dir;

        const gop = try dir_specs.getOrPut(dir_path);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.array_list.Managed(xlsx_mod.SheetSpec).init(alloc);
        }
        try gop.value_ptr.append(.{
            .name = sheet.name,
            .header_row = sheet.header_row,
            .output_suffix = sheet.output_suffix,
        });
    }

    if (dir_specs.count() == 0) return xlsx_stats;

    out.info("\n=== preparing work environment ===\n", .{});

    var ds_it = dir_specs.iterator();
    while (ds_it.next()) |e| {
        const dir_path = e.key_ptr.*;
        const specs = e.value_ptr.items;

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                out.fatal("error: directory not found: '{s}'\n", .{dir_path});
                xlsx_stats.has_fatal = true;
                continue;
            }
            return err;
        };
        defer dir.close();

        var xlsx_names = std.array_list.Managed([]u8).init(alloc);
        defer {
            for (xlsx_names.items) |n| alloc.free(n);
            xlsx_names.deinit();
        }
        {
            var fit = dir.iterate();
            while (try fit.next()) |entry| {
                if (entry.kind != .file and entry.kind != .sym_link) continue;
                if (!std.mem.endsWith(u8, entry.name, ".xlsx")) continue;
                try xlsx_names.append(try alloc.dupe(u8, entry.name));
            }
        }
        std.mem.sort([]u8, xlsx_names.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (xlsx_names.items) |xlsx_name| {
            const stem = xlsx_name[0 .. xlsx_name.len - 5];

            // --fresh: skip xlsx conversion if all expected csvx outputs already exist.
            if (fresh) {
                var all_exist = true;
                for (specs) |spec| {
                    const csvx_name = try std.mem.concat(alloc, u8, &.{ stem, spec.output_suffix, "x" });
                    defer alloc.free(csvx_name);
                    dir.access(csvx_name, .{}) catch {
                        all_exist = false;
                        break;
                    };
                }
                if (all_exist) {
                    out.info("  skipping '{s}' (output exists)\n", .{xlsx_name});
                    continue;
                }
            }

            const xlsx_file = try dir.openFile(xlsx_name, .{});
            defer xlsx_file.close();

            out.info("converting '{s}'\n", .{xlsx_name});
            xlsx_mod.xlsxToCsv(alloc, xlsx_file, specs, dir, stem) catch |err| {
                out.fatal("fatal error: xlsx conversion failed for '{s}': {s}\n", .{ xlsx_name, @errorName(err) });
                xlsx_stats.has_fatal = true;
                xlsx_stats.time_ns = timer.read();
                out.summary(xlsx_stats);
                return error.Fatal;
            };
        }
    }

    xlsx_stats.time_ns = timer.read();
    out.summary(xlsx_stats);
    return xlsx_stats;
}
