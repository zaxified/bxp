/// xlsx.zig — Convert Excel .xlsx files to CSV.
///
/// .xlsx files are ZIP archives containing XML.  We extract the archive to a
/// temporary directory alongside the output CSV files, parse the minimum set of
/// XML files required, and write CSV output.
///
/// Supported cell types: shared strings (t="s"), inline strings (t="inlineStr"),
/// formula result strings (t="str"), booleans (t="b"), plain numbers, and
/// date/time values detected via styles.xml numFmtId.
///
/// Not supported: encrypted workbooks, LZMA-compressed ZIP entries.
const std = @import("std");
const Allocator = std.mem.Allocator;

const ZIP_READ_BUF_SIZE: usize = 8192;
const CSV_OUT_BUF_SIZE: usize = 65536;
const XLSX_MAX_FILE_SIZE: usize = 10 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Describes one sheet to extract from an xlsx file.
pub const SheetSpec = struct {
    /// Sheet name as it appears in the workbook (e.g. "CASH OPERATION").
    name: []const u8,
    /// 1-based row number that contains the column headers.
    /// Rows before this number are skipped (report titles, blank lines, etc.).
    header_row: u32,
    /// Appended before ".csv" in the output filename (e.g. "_3").
    output_suffix: []const u8,
};

/// Converts selected sheets from an xlsx file to CSV files in out_dir.
///
/// Output files are named "<out_basename><spec.output_suffix>" (output_suffix includes the extension, e.g. "_open.csv").
/// Always re-extracts every requested sheet.
/// Sheets whose name is not found in the workbook are silently skipped.
pub fn xlsxToCsv(
    alloc: Allocator,
    xlsx_file: std.fs.File,
    sheets: []const SheetSpec,
    out_dir: std.fs.Dir,
    out_basename: []const u8,
) !void {

    // Create a temporary directory next to the output files. The name is
    // derived from `out_basename` alone — safe because bxp-cli runs templates
    // serially, so two concurrent calls with the same basename can't collide.
    const tmp_name = try std.fmt.allocPrint(alloc, ".{s}.xlstmp", .{out_basename});
    defer alloc.free(tmp_name);

    // Remove any leftover temp dir from a previous crashed run.
    out_dir.deleteTree(tmp_name) catch {}; // best-effort cleanup — ignore errors

    var tmp_dir = try out_dir.makeOpenPath(tmp_name, .{});
    defer {
        tmp_dir.close();
        out_dir.deleteTree(tmp_name) catch {}; // best-effort cleanup — ignore errors
    }

    // Extract the xlsx (which is a ZIP) to tmp_dir.
    var zip_buf: [ZIP_READ_BUF_SIZE]u8 = undefined;
    var zip_reader = xlsx_file.reader(&zip_buf);
    std.zip.extract(tmp_dir, &zip_reader, .{ .allow_backslashes = true }) catch |err| {
        if (err != error.ZipMismatchVersionNeeded) return err;
        // Some xlsx files (e.g. XTB exports) have version_needed=45 in local
        // file headers but version_needed=20 in the central directory.  Patch
        // all local file headers to use the version required by their
        // compression method and retry.
        const fixed_file = try fixZipLocalVersionNeeded(alloc, xlsx_file, tmp_dir);
        defer fixed_file.close();
        var fixed_buf: [ZIP_READ_BUF_SIZE]u8 = undefined;
        var fixed_reader = fixed_file.reader(&fixed_buf);
        try std.zip.extract(tmp_dir, &fixed_reader, .{ .allow_backslashes = true });
    };

    // sheet name → relative path within xl/ (e.g. "worksheets/sheet3.xml")
    var sheet_paths = try parseWorkbook(alloc, tmp_dir);
    defer {
        var it = sheet_paths.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        sheet_paths.deinit();
    }

    // Shared strings table (may be absent for number-only workbooks).
    var shared_strings = try parseSharedStrings(alloc, tmp_dir);
    defer {
        for (shared_strings.items) |s| alloc.free(s);
        shared_strings.deinit(alloc);
    }

    // Set of 0-based cellXfs indices that map to date/time formats.
    var date_styles = try parseDateStyles(alloc, tmp_dir);
    defer date_styles.deinit();

    for (sheets) |spec| {
        const csv_name = try std.fmt.allocPrint(
            alloc,
            "{s}{s}",
            .{ out_basename, spec.output_suffix },
        );
        defer alloc.free(csv_name);

        // Prefix match: "OPEN POSITION" matches "OPEN POSITION 28022026".
        // Also handles exact names since startsWith("X", "X") == true.
        const rel_path = blk: {
            var sit = sheet_paths.iterator();
            while (sit.next()) |e| {
                if (std.mem.startsWith(u8, e.key_ptr.*, spec.name)) break :blk e.value_ptr.*;
            }
            continue;
        };

        const xml_path = try std.fmt.allocPrint(alloc, "xl/{s}", .{rel_path});
        defer alloc.free(xml_path);

        const out_file = try out_dir.createFile(csv_name, .{});
        defer out_file.close();

        var out_buf: [CSV_OUT_BUF_SIZE]u8 = undefined;
        var out_fw = out_file.writer(&out_buf);

        try parseSheet(
            alloc,
            tmp_dir,
            xml_path,
            spec.header_row,
            shared_strings.items,
            &date_styles,
            &out_fw.interface,
        );
        try out_fw.interface.flush();
    }
}

// ---------------------------------------------------------------------------
// ZIP local-header version fixup
// ---------------------------------------------------------------------------

/// Some xlsx generators (e.g. XTB) write version_needed=45 (Zip64) in local
/// file headers while the central directory correctly uses version_needed=20
/// (Deflate).  std.zip.extract rejects this mismatch.
///
/// This function reads the whole file, patches every local file header so its
/// version_needed matches what the compression method actually requires
/// (Store→10, Deflate→20), writes the result to ".fixed_input.xlsx" inside
/// tmp_dir, and returns that file opened for reading.
fn fixZipLocalVersionNeeded(
    alloc: Allocator,
    xlsx_file: std.fs.File,
    tmp_dir: std.fs.Dir,
) !std.fs.File {
    try xlsx_file.seekTo(0);
    const data = try xlsx_file.readToEndAlloc(alloc, 64 * 1024 * 1024);
    defer alloc.free(data);

    // Scan for local file header signatures (PK\x03\x04) and patch
    // version_needed (u16 LE at offset +4) to match the compression method
    // (u16 LE at offset +8): 0=Store→10, 8=Deflate→20.
    const local_sig = [4]u8{ 0x50, 0x4b, 0x03, 0x04 };
    var i: usize = 0;
    while (i + 30 <= data.len) : (i += 1) {
        if (!std.mem.eql(u8, data[i..][0..4], &local_sig)) continue;
        const compress = std.mem.readInt(u16, data[i + 8 ..][0..2], .little);
        const version: u16 = switch (compress) {
            0 => 10, // Store
            8 => 20, // Deflate
            else => continue,
        };
        std.mem.writeInt(u16, data[i + 4 ..][0..2], version, .little);
    }

    const fixed = try tmp_dir.createFile(".fixed_input.xlsx", .{ .read = true });
    try fixed.writeAll(data);
    try fixed.seekTo(0);
    return fixed;
}

// ---------------------------------------------------------------------------
// Workbook parser  (xl/workbook.xml + xl/_rels/workbook.xml.rels)
// ---------------------------------------------------------------------------

/// Returns a StringHashMap: sheet_name → relative path within xl/.
/// Caller owns map and its key/value strings; use the deinit pattern below:
///   var it = map.iterator(); while (it.next()) |e| { free key, free value }
///   map.deinit();
fn parseWorkbook(alloc: Allocator, tmp_dir: std.fs.Dir) !std.StringHashMap([]const u8) {
    // Use an arena for the intermediate name→rId and rId→path maps so that we
    // don't have to individually free every entry on the happy path.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var name_to_rid = std.StringHashMap([]const u8).init(aa);
    var rid_to_path = std.StringHashMap([]const u8).init(aa);

    // xl/_rels/workbook.xml.rels  →  rId → worksheet target path
    if (readFile(aa, tmp_dir, "xl/_rels/workbook.xml.rels")) |rels_xml| {
        var tok = XmlTok.init(rels_xml);
        while (tok.next()) |token| {
            switch (token) {
                .open => |t| {
                    if (!std.mem.eql(u8, stripNs(t.name), "Relationship")) continue;
                    const rel_type = getAttr(t.attrs, "Type") orelse continue;
                    if (!std.mem.endsWith(u8, rel_type, "/worksheet")) continue;
                    const id = getAttr(t.attrs, "Id") orelse continue;
                    const target = getAttr(t.attrs, "Target") orelse continue;
                    try rid_to_path.put(try aa.dupe(u8, id), try aa.dupe(u8, target));
                },
                else => {},
            }
        }
    } else |_| {}

    // xl/workbook.xml  →  sheet name → rId
    if (readFile(aa, tmp_dir, "xl/workbook.xml")) |wb_xml| {
        var tok = XmlTok.init(wb_xml);
        while (tok.next()) |token| {
            switch (token) {
                .open => |t| {
                    if (!std.mem.eql(u8, stripNs(t.name), "sheet")) continue;
                    const name = getAttr(t.attrs, "name") orelse continue;
                    // The attribute is "r:id" — getAttr matches any *:id prefix.
                    const rid = getAttr(t.attrs, "id") orelse continue;
                    try name_to_rid.put(try aa.dupe(u8, name), try aa.dupe(u8, rid));
                },
                else => {},
            }
        }
    } else |_| return std.StringHashMap([]const u8).init(alloc);

    // Build result: name → path, allocated with the caller's allocator.
    var result = std.StringHashMap([]const u8).init(alloc);
    errdefer {
        var it = result.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        result.deinit();
    }

    var it = name_to_rid.iterator();
    while (it.next()) |e| {
        const path = rid_to_path.get(e.value_ptr.*) orelse continue;
        try result.put(try alloc.dupe(u8, e.key_ptr.*), try alloc.dupe(u8, path));
    }
    return result;
}

// ---------------------------------------------------------------------------
// Shared strings parser  (xl/sharedStrings.xml)
// ---------------------------------------------------------------------------

/// Returns an ArrayList of owned strings, one per <si> element (index = cell value index).
fn parseSharedStrings(alloc: Allocator, tmp_dir: std.fs.Dir) !std.ArrayList([]u8) {
    var strings: std.ArrayList([]u8) = .empty;

    const xml = readFile(alloc, tmp_dir, "xl/sharedStrings.xml") catch return strings;
    defer alloc.free(xml);

    var tok = XmlTok.init(xml);
    var in_si = false;
    var in_t = false;
    // Accumulator for the current <si> text (multiple <t> runs are concatenated).
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(alloc);

    while (tok.next()) |token| {
        switch (token) {
            .open => |t| {
                const tag = stripNs(t.name);
                if (std.mem.eql(u8, tag, "si")) {
                    in_si = true;
                    current.clearRetainingCapacity();
                } else if (in_si and std.mem.eql(u8, tag, "t")) {
                    in_t = true;
                }
            },
            .close => |name| {
                const tag = stripNs(name);
                if (std.mem.eql(u8, tag, "si")) {
                    in_si = false;
                    in_t = false;
                    try strings.append(alloc, try current.toOwnedSlice(alloc));
                } else if (std.mem.eql(u8, tag, "t")) {
                    in_t = false;
                }
            },
            .text => |raw| {
                if (in_t) try decodeEntities(raw, &current, alloc);
            },
        }
    }
    return strings;
}

// ---------------------------------------------------------------------------
// Date style parser  (xl/styles.xml)
// ---------------------------------------------------------------------------

/// Returns a set of 0-based cellXfs indices that correspond to date/time formats.
fn parseDateStyles(alloc: Allocator, tmp_dir: std.fs.Dir) !std.AutoHashMap(u32, void) {
    var date_xf: std.AutoHashMap(u32, void) = std.AutoHashMap(u32, void).init(alloc);

    const xml = readFile(alloc, tmp_dir, "xl/styles.xml") catch return date_xf;
    defer alloc.free(xml);

    // First pass: collect custom numFmtIds that represent date/time formats.
    var custom_date_fmts = std.AutoHashMap(u32, void).init(alloc);
    defer custom_date_fmts.deinit();
    {
        var tok = XmlTok.init(xml);
        while (tok.next()) |token| {
            switch (token) {
                .open => |t| {
                    if (!std.mem.eql(u8, stripNs(t.name), "numFmt")) continue;
                    const id_str = getAttr(t.attrs, "numFmtId") orelse continue;
                    const fmt_code = getAttr(t.attrs, "formatCode") orelse continue;
                    const id = std.fmt.parseInt(u32, id_str, 10) catch continue;
                    if (isDateFormatCode(fmt_code)) try custom_date_fmts.put(id, {});
                },
                else => {},
            }
        }
    }

    // Second pass: find cellXfs entries and record which ones have date numFmtIds.
    {
        var tok = XmlTok.init(xml);
        var in_cell_xfs = false;
        var xf_idx: u32 = 0;

        while (tok.next()) |token| {
            switch (token) {
                .open => |t| {
                    const tag = stripNs(t.name);
                    if (std.mem.eql(u8, tag, "cellXfs")) {
                        in_cell_xfs = true;
                    } else if (in_cell_xfs and std.mem.eql(u8, tag, "xf")) {
                        defer xf_idx += 1;
                        const id_str = getAttr(t.attrs, "numFmtId") orelse continue;
                        const id = std.fmt.parseInt(u32, id_str, 10) catch continue;
                        if (isBuiltinDateFmt(id) or custom_date_fmts.contains(id)) {
                            try date_xf.put(xf_idx, {});
                        }
                    }
                },
                .close => |name| {
                    if (std.mem.eql(u8, stripNs(name), "cellXfs")) {
                        in_cell_xfs = false;
                        xf_idx = 0;
                    }
                },
                else => {},
            }
        }
    }

    return date_xf;
}

/// Returns true if numFmtId is a built-in Excel date/time format.
/// Built-in date format IDs: 14–22 (date/time variants) and 45–47 (time variants).
fn isBuiltinDateFmt(id: u32) bool {
    return (id >= 14 and id <= 22) or (id >= 45 and id <= 47);
}

/// Returns true if the Excel format code describes a date or time value.
/// Scans for d/y/h/m tokens outside quoted strings and bracket expressions.
fn isDateFormatCode(code: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(code, "general")) return false;
    var i: usize = 0;
    var in_str: bool = false;
    var str_char: u8 = 0;
    while (i < code.len) : (i += 1) {
        const c = code[i];
        if (in_str) {
            if (c == str_char) in_str = false;
            continue;
        }
        switch (c) {
            '"', '\'' => {
                in_str = true;
                str_char = c;
            },
            '[' => {
                while (i < code.len and code[i] != ']') i += 1;
            },
            'd', 'D', 'y', 'Y', 'h', 'H', 'm', 'M' => return true,
            else => {},
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Sheet parser  (xl/worksheets/sheetN.xml)
// ---------------------------------------------------------------------------

/// Parses a worksheet XML and writes CSV rows to out.
/// Rows before header_row are silently skipped.
/// Row header_row becomes the CSV header; subsequent rows become data rows.
fn parseSheet(
    alloc: Allocator,
    tmp_dir: std.fs.Dir,
    xml_path: []const u8,
    header_row: u32,
    shared_strings: []const []u8,
    date_styles: *const std.AutoHashMap(u32, void),
    out: *std.Io.Writer,
) !void {
    const xml = try readFile(alloc, tmp_dir, xml_path);
    defer alloc.free(xml);

    // Cells in the current row: index = 0-based column, value = owned string.
    var row_cells: std.ArrayList([]u8) = .empty;
    defer {
        for (row_cells.items) |s| alloc.free(s);
        row_cells.deinit(alloc);
    }

    // Accumulates the raw <v> or <t> text for the current cell.
    var cell_val_buf: std.ArrayList(u8) = .empty;
    defer cell_val_buf.deinit(alloc);

    var col_count: u32 = 0; // set from header row; used to pad/truncate data rows
    var skip_cols: u32 = 0; // leading empty columns stripped from header (e.g. xlsx column A)
    var current_row: u32 = 0;
    var in_row: bool = false;
    var in_cell: bool = false;
    var in_value: bool = false; // inside <v>
    var in_inline_t: bool = false; // inside <is><t>
    var cell_col: u32 = 0;
    var cell_type: []const u8 = "";
    var cell_style: u32 = 0;

    var tok = XmlTok.init(xml);
    while (tok.next()) |token| {
        switch (token) {
            .open => |t| {
                const tag = stripNs(t.name);

                if (std.mem.eql(u8, tag, "row")) {
                    in_row = true;
                    const r_str = getAttr(t.attrs, "r") orelse "0";
                    current_row = std.fmt.parseInt(u32, r_str, 10) catch 0;
                    // Clear row_cells for the new row.
                    for (row_cells.items) |s| alloc.free(s);
                    row_cells.clearRetainingCapacity();
                } else if (in_row and std.mem.eql(u8, tag, "c")) {
                    in_cell = true;
                    cell_val_buf.clearRetainingCapacity();
                    cell_type = getAttr(t.attrs, "t") orelse "";
                    const s_str = getAttr(t.attrs, "s") orelse "0";
                    cell_style = std.fmt.parseInt(u32, s_str, 10) catch 0;
                    const r_str = getAttr(t.attrs, "r") orelse "";
                    cell_col = colRefToIndex(r_str);
                } else if (in_cell and std.mem.eql(u8, tag, "v")) {
                    in_value = true;
                } else if (in_cell and std.mem.eql(u8, tag, "is")) {
                    // Inline string — text will arrive via nested <t>.
                } else if (in_cell and std.mem.eql(u8, tag, "t")) {
                    in_inline_t = true;
                }
            },

            .close => |name| {
                const tag = stripNs(name);

                if (std.mem.eql(u8, tag, "v")) {
                    in_value = false;
                } else if (std.mem.eql(u8, tag, "t")) {
                    in_inline_t = false;
                } else if (std.mem.eql(u8, tag, "c")) {
                    in_cell = false;
                    in_value = false;
                    in_inline_t = false;

                    if (current_row >= header_row) {
                        const resolved = try resolveCellValue(
                            alloc,
                            cell_val_buf.items,
                            cell_type,
                            cell_style,
                            shared_strings,
                            date_styles,
                        );
                        // Ensure the row_cells slice is large enough, padding with "".
                        while (row_cells.items.len <= cell_col) {
                            try row_cells.append(alloc, try alloc.dupe(u8, ""));
                        }
                        alloc.free(row_cells.items[cell_col]);
                        row_cells.items[cell_col] = resolved;
                    }
                } else if (std.mem.eql(u8, tag, "row")) {
                    in_row = false;

                    if (current_row == header_row) {
                        // Count and skip leading empty header columns (e.g. blank column A).
                        var sc: u32 = 0;
                        while (sc < row_cells.items.len and row_cells.items[sc].len == 0) sc += 1;
                        skip_cols = sc;
                        const header_slice = row_cells.items[skip_cols..];
                        col_count = @intCast(header_slice.len);
                        try writeRowCsv(header_slice, out);
                    } else if (current_row > header_row and col_count > 0) {
                        const data_start = @min(skip_cols, @as(u32, @intCast(row_cells.items.len)));
                        try writeRowCsvFixed(row_cells.items[data_start..], col_count, out);
                    }
                    // Rows before header_row are silently skipped.
                }
            },

            .text => |raw| {
                if (in_value or in_inline_t) {
                    try decodeEntities(raw, &cell_val_buf, alloc);
                }
            },
        }
    }
}

/// Normalizes a numeric string:
/// - Strips trailing zeros after the decimal point: "518.740000" → "518.74", "1.0000" → "1".
/// - Converts scientific notation to decimal when the value is a whole number:
///   "2.087960758E9" → "2087960758".
/// - Leaves other forms unchanged.
fn normalizeNumber(alloc: Allocator, raw: []const u8) ![]u8 {
    // Scientific notation — parse and reformat as integer if the value is whole.
    if (std.mem.indexOfAny(u8, raw, "Ee")) |_| {
        const f = std.fmt.parseFloat(f64, raw) catch return alloc.dupe(u8, raw);
        const rounded = @round(f);
        if (f == rounded and @abs(f) < 1e15) {
            const i: i64 = @intFromFloat(rounded);
            return std.fmt.allocPrint(alloc, "{d}", .{i});
        }
        return alloc.dupe(u8, raw);
    }
    // Decimal — strip trailing zeros.
    const dot = std.mem.indexOfScalar(u8, raw, '.') orelse return alloc.dupe(u8, raw);
    var end = raw.len;
    while (end > dot + 1 and raw[end - 1] == '0') end -= 1;
    if (end == dot + 1) end = dot; // remove decimal point when all decimals stripped
    return alloc.dupe(u8, raw[0..end]);
}

/// Resolves a raw xlsx cell value to an owned string.
fn resolveCellValue(
    alloc: Allocator,
    raw: []const u8,
    cell_type: []const u8,
    cell_style: u32,
    shared_strings: []const []u8,
    date_styles: *const std.AutoHashMap(u32, void),
) ![]u8 {
    // Shared string: raw is an index into the shared strings table.
    if (std.mem.eql(u8, cell_type, "s")) {
        const idx = std.fmt.parseInt(usize, raw, 10) catch return alloc.dupe(u8, "");
        if (idx < shared_strings.len) return alloc.dupe(u8, shared_strings[idx]);
        return alloc.dupe(u8, "");
    }
    // Inline string or formula result: raw is the string value.
    if (std.mem.eql(u8, cell_type, "inlineStr") or
        std.mem.eql(u8, cell_type, "str"))
    {
        return alloc.dupe(u8, raw);
    }
    // Boolean.
    if (std.mem.eql(u8, cell_type, "b")) {
        return alloc.dupe(u8, if (std.mem.eql(u8, raw, "1")) "TRUE" else "FALSE");
    }
    // Error or empty.
    if (std.mem.eql(u8, cell_type, "e") or raw.len == 0) return alloc.dupe(u8, "");

    // Numeric — check if this style index maps to a date/time format.
    if (date_styles.contains(cell_style)) {
        const serial = std.fmt.parseFloat(f64, raw) catch return alloc.dupe(u8, raw);
        var dt_buf: [19]u8 = undefined;
        const dt = excelSerialToDatetime(serial, &dt_buf);
        return alloc.dupe(u8, dt);
    }

    // Plain number — strip trailing zeros (e.g. "1.0000" → "1", "518.740000" → "518.74").
    return normalizeNumber(alloc, raw);
}

// ---------------------------------------------------------------------------
// CSV output helpers
// ---------------------------------------------------------------------------

/// Writes one worksheet row as a RFC 4180 CSV line (comma-delimited, CRLF-safe quoting).
fn writeRowCsv(cells: []const []u8, out: *std.Io.Writer) !void {
    for (cells, 0..) |cell, i| {
        if (i > 0) try out.writeAll(",");
        try writeCsvField(out, cell);
    }
    try out.writeAll("\n");
}

/// Like writeRowCsv but always emits exactly col_count fields, padding with empty
/// fields or truncating if cells has fewer or more entries than col_count.
fn writeRowCsvFixed(cells: []const []u8, col_count: u32, out: *std.Io.Writer) !void {
    var col: u32 = 0;
    while (col < col_count) : (col += 1) {
        if (col > 0) try out.writeAll(",");
        const val: []const u8 = if (col < cells.len) cells[col] else "";
        try writeCsvField(out, val);
    }
    try out.writeAll("\n");
}

/// Writes one CSV field with RFC 4180 quoting: wraps value in double quotes and
/// doubles any embedded quote characters when the value contains , " \n or \r.
fn writeCsvField(out: *std.Io.Writer, value: []const u8) !void {
    if (std.mem.indexOfAny(u8, value, ",\"\n\r") == null) {
        try out.writeAll(value);
        return;
    }
    try out.writeByte('"');
    for (value) |c| {
        if (c == '"') try out.writeByte('"'); // RFC 4180: double the quote
        try out.writeByte(c);
    }
    try out.writeByte('"');
}

// ---------------------------------------------------------------------------
// Cell reference helpers
// ---------------------------------------------------------------------------

/// Converts a cell reference like "A1" or "BC23" to a 0-based column index.
fn colRefToIndex(ref: []const u8) u32 {
    var col: u32 = 0;
    for (ref) |c| {
        if (!std.ascii.isAlphabetic(c)) break;
        col = col * 26 + (std.ascii.toUpper(c) - 'A' + 1);
    }
    return if (col > 0) col - 1 else 0;
}

// ---------------------------------------------------------------------------
// Excel serial → datetime
// ---------------------------------------------------------------------------

/// Converts an Excel serial number to a "YYYY-MM-DD HH:MM:SS" string.
///
/// Excel epoch: December 30, 1899 (accounting for the Lotus 1-2-3 1900 leap
/// year bug).  Serial 25569 equals the Unix epoch 1970-01-01 00:00:00.
fn excelSerialToDatetime(serial: f64, buf: *[19]u8) []u8 {
    const EXCEL_UNIX_EPOCH: f64 = 25569.0;
    const unix_days: i64 = @intFromFloat(@floor(serial - EXCEL_UNIX_EPOCH));
    const frac: f64 = serial - @floor(serial);
    const total_secs: u32 = @intFromFloat(@floor(frac * 86400.0));
    const hh: u32 = total_secs / 3600;
    const mm: u32 = (total_secs % 3600) / 60;
    const ss: u32 = total_secs % 60;

    const ymd = unixDayToYMD(unix_days);
    // Cast year to u32: safe for all dates in our range (post-1900).
    const y: u32 = @intCast(ymd.y);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        y, @as(u32, ymd.m), @as(u32, ymd.d), hh, mm, ss,
    }) catch buf[0..19];
}

const YMD = struct { y: i32, m: u8, d: u8 };

/// Converts a Unix day count (days since 1970-01-01) to a Y/M/D triple.
/// Uses Howard Hinnant's civil-from-days algorithm.
/// Reference: https://howardhinnant.github.io/date_algorithms.html
fn unixDayToYMD(day: i64) YMD {
    const z: i64 = day + 719468;
    const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y_era: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const d: u8 = @intCast(doy - (153 * mp + 2) / 5 + 1);
    const m: u8 = if (mp < 10) @intCast(mp + 3) else @intCast(mp - 9);
    const y: i32 = if (m <= 2) @intCast(y_era + 1) else @intCast(y_era);
    return .{ .y = y, .m = m, .d = d };
}

// ---------------------------------------------------------------------------
// Minimal XML tokenizer
// ---------------------------------------------------------------------------

const XmlToken = union(enum) {
    /// Opening tag including any self-closing tags.
    open: struct {
        name: []const u8, // tag name (slice into source; may include namespace prefix)
        attrs: []const u8, // raw attribute string between tag name and '>' or '/>'
        self_close: bool,
    },
    /// Closing tag </name>.
    close: []const u8, // tag name (slice into source)
    /// Raw text content between tags (may contain XML entities).
    text: []const u8,
};

const XmlTok = struct {
    src: []const u8,
    pos: usize,

    fn init(src: []const u8) XmlTok {
        return .{ .src = src, .pos = 0 };
    }

    fn next(self: *XmlTok) ?XmlToken {
        while (self.pos < self.src.len) {
            if (self.src[self.pos] != '<') {
                // Text content up to the next '<'.
                const start = self.pos;
                while (self.pos < self.src.len and self.src[self.pos] != '<') self.pos += 1;
                const text = self.src[start..self.pos];
                if (text.len > 0) return .{ .text = text };
                continue;
            }

            // We are at '<'.
            if (self.pos + 1 >= self.src.len) {
                self.pos += 1;
                continue;
            }
            const nc = self.src[self.pos + 1];

            // Processing instruction <?...?>
            if (nc == '?') {
                self.skipPast("?>");
                continue;
            }

            // Comment <!--...--> or declaration <!...>
            if (nc == '!') {
                if (self.pos + 3 < self.src.len and
                    std.mem.eql(u8, self.src[self.pos + 1 .. self.pos + 4], "!--"))
                {
                    self.pos += 4;
                    self.skipPast("-->");
                } else {
                    self.skipPast(">");
                }
                continue;
            }

            // End tag </name>
            if (nc == '/') {
                self.pos += 2;
                const start = self.pos;
                while (self.pos < self.src.len and self.src[self.pos] != '>') self.pos += 1;
                const name = std.mem.trimRight(u8, self.src[start..self.pos], " \t\r\n");
                if (self.pos < self.src.len) self.pos += 1;
                return .{ .close = name };
            }

            // Start tag (possibly self-closing).
            self.pos += 1; // skip '<'
            const name_start = self.pos;
            while (self.pos < self.src.len and
                self.src[self.pos] != '>' and
                self.src[self.pos] != '/' and
                !isWs(self.src[self.pos])) self.pos += 1;
            const name = self.src[name_start..self.pos];

            while (self.pos < self.src.len and isWs(self.src[self.pos])) self.pos += 1;

            // Collect raw attribute text until '>' or '/>'.
            const attrs_start = self.pos;
            var q: u8 = 0;
            while (self.pos < self.src.len) {
                const c = self.src[self.pos];
                if (q != 0) {
                    if (c == q) q = 0;
                } else if (c == '"' or c == '\'') {
                    q = c;
                } else if (c == '>' or c == '/') {
                    break;
                }
                self.pos += 1;
            }
            const attrs = std.mem.trimRight(u8, self.src[attrs_start..self.pos], " \t\r\n");

            var self_close = false;
            if (self.pos < self.src.len and self.src[self.pos] == '/') {
                self_close = true;
                self.pos += 1;
            }
            if (self.pos < self.src.len and self.src[self.pos] == '>') self.pos += 1;

            if (name.len == 0) continue;
            return .{ .open = .{ .name = name, .attrs = attrs, .self_close = self_close } };
        }
        return null;
    }

    fn skipPast(self: *XmlTok, needle: []const u8) void {
        if (std.mem.indexOf(u8, self.src[self.pos..], needle)) |idx| {
            self.pos += idx + needle.len;
        } else {
            self.pos = self.src.len;
        }
    }
};

/// Returns true for ASCII whitespace characters: space, tab, CR, LF.
fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

// ---------------------------------------------------------------------------
// XML attribute extraction
// ---------------------------------------------------------------------------

/// Searches attrs_raw for an attribute matching name.
/// Returns a slice into attrs_raw (no allocation) or null if not found.
/// Handles namespaced attributes: searching for "id" also matches "r:id",
/// "x:id", etc.  Searching for "r:id" only matches "r:id" exactly.
fn getAttr(attrs_raw: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < attrs_raw.len) {
        while (pos < attrs_raw.len and isWs(attrs_raw[pos])) pos += 1;
        if (pos >= attrs_raw.len) break;

        const eq_idx = std.mem.indexOfScalarPos(u8, attrs_raw, pos, '=') orelse break;
        const raw_name = std.mem.trim(u8, attrs_raw[pos..eq_idx], " \t\r\n");
        pos = eq_idx + 1;
        if (pos >= attrs_raw.len) break;

        const q = attrs_raw[pos];
        if (q != '"' and q != '\'') {
            while (pos < attrs_raw.len and !isWs(attrs_raw[pos])) pos += 1;
            continue;
        }
        pos += 1;
        const val_start = pos;
        while (pos < attrs_raw.len and attrs_raw[pos] != q) pos += 1;
        const val = attrs_raw[val_start..pos];
        if (pos < attrs_raw.len) pos += 1;

        // Exact match OR namespace-prefixed match (any_prefix:name).
        const exact = std.mem.eql(u8, raw_name, name);
        const ns_match = !std.mem.containsAtLeast(u8, name, 1, ":") and
            std.mem.endsWith(u8, raw_name, name) and
            raw_name.len > name.len and
            raw_name[raw_name.len - name.len - 1] == ':';
        if (exact or ns_match) return val;
    }
    return null;
}

/// Returns the local name, stripping any namespace prefix ("r:id" → "id").
fn stripNs(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, ':')) |colon| return name[colon + 1 ..];
    return name;
}

// ---------------------------------------------------------------------------
// XML entity decoder
// ---------------------------------------------------------------------------

/// Decodes XML character and entity references in src, appending to out.
fn decodeEntities(src: []const u8, out: *std.ArrayList(u8), alloc: Allocator) !void {
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] != '&') {
            try out.append(alloc, src[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, src, i + 1, ';') orelse {
            try out.append(alloc, src[i]);
            i += 1;
            continue;
        };
        const entity = src[i + 1 .. semi];
        i = semi + 1;
        if (std.mem.eql(u8, entity, "amp")) {
            try out.append(alloc, '&');
        } else if (std.mem.eql(u8, entity, "lt")) {
            try out.append(alloc, '<');
        } else if (std.mem.eql(u8, entity, "gt")) {
            try out.append(alloc, '>');
        } else if (std.mem.eql(u8, entity, "quot")) {
            try out.append(alloc, '"');
        } else if (std.mem.eql(u8, entity, "apos")) {
            try out.append(alloc, '\'');
        } else if (entity.len > 1 and entity[0] == '#') {
            const cp: u21 = if (entity.len > 2 and entity[1] == 'x')
                std.fmt.parseInt(u21, entity[2..], 16) catch 0xFFFD
            else
                std.fmt.parseInt(u21, entity[1..], 10) catch 0xFFFD;
            var utf8_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &utf8_buf) catch 1;
            try out.appendSlice(alloc, utf8_buf[0..len]);
        } else {
            // Unknown entity — pass through unchanged.
            try out.append(alloc, '&');
            try out.appendSlice(alloc, entity);
            try out.append(alloc, ';');
        }
    }
}

// ---------------------------------------------------------------------------
// File helper
// ---------------------------------------------------------------------------

/// Reads an entire file into a caller-owned slice (Arena allocator is fine).
/// Returns error.FileTooBig if the file exceeds XLSX_MAX_FILE_SIZE.
fn readFile(alloc: Allocator, dir: std.fs.Dir, path: []const u8) ![]u8 {
    const file = try dir.openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(alloc, XLSX_MAX_FILE_SIZE);
}
