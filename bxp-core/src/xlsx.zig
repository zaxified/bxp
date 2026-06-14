/// xlsx.zig — Convert Excel .xlsx files to CSV.
///
/// .xlsx files are ZIP archives containing XML. Every part is parsed by
/// *streaming* its decompressed bytes through `zipstream` (central-directory
/// walk + per-entry inflate) into the `XmlTok` pull-tokenizer — nothing is
/// extracted to a temp directory and no XML part is materialised whole. The
/// memory ceiling for a conversion is therefore O(one inflate window + one XML
/// token window + the shared-strings table + one output row), independent of
/// workbook size; the worksheet itself never lands in RAM.
///
/// Supported cell types: shared strings (t="s"), inline strings (t="inlineStr"),
/// formula result strings (t="str"), booleans (t="b"), plain numbers, and
/// date/time values detected via styles.xml numFmtId.
///
/// Not supported: encrypted workbooks, LZMA-compressed ZIP entries.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Decimal = @import("decimal").Decimal;
const zipstream = @import("zipstream");

const CSV_OUT_BUF_SIZE: usize = 65536;
/// Inflate window handed to each `zipstream.EntryReader` (deflate needs the
/// full 32 KiB history; `max_window_len` is 64 KiB). One buffer, reused across
/// the parts of one workbook.
const ZIP_WINDOW_SIZE: usize = std.compress.flate.max_window_len;
/// Window the `XmlTok` tokenizer scans within. A single token (a tag or a text
/// run) must fit in half of it (the tokenizer guarantees that much contiguous
/// space at each token boundary); 128 KiB ⇒ a 64 KiB token ceiling, far beyond
/// any real worksheet cell. One buffer, reused across parts.
const XML_WINDOW_SIZE: usize = 128 * 1024;
/// Defensive ceiling on the shared-strings table — the one structure that must
/// be fully resident (cells reference it by arbitrary index). A guard against a
/// zip-bomb sharedStrings part, not a feature limit; real workbooks stay far
/// below it. Exceeding it is `error.FileTooBig`.
pub const XLSX_SHARED_STRINGS_CAP: usize = 1024 * 1024 * 1024;

// ---------------------------------------------------------------------------
// XML part access
// ---------------------------------------------------------------------------
//
// Every part is opened with `openPart` below: locate the entry in the streaming
// `zipstream.Archive`, set up a streaming `EntryReader`, and hand the caller an
// `XmlTok` over it. The inflate window and the tokenizer window are owned by
// `xlsxToCsv` and reused across parts (one workbook reads its parts serially).

/// Per-conversion scratch: the streaming archive plus the two reusable windows.
/// One inflate window (deflate history) and one tokenizer window are enough
/// because the parts of a single workbook are read one at a time.
const PartCtx = struct {
    archive: *zipstream.Archive,
    zip_window: []u8, // inflate history (ZIP_WINDOW_SIZE)
    xml_window: []u8, // XmlTok scan window (XML_WINDOW_SIZE)
    entry_reader: zipstream.EntryReader = undefined,

    /// Opens the named part for streaming and returns an `XmlTok` over its
    /// decompressed bytes, or null if the part is absent (optional parts like
    /// sharedStrings.xml / styles.xml may not exist). The returned tokenizer
    /// borrows `self.entry_reader` and the windows, so only one part may be
    /// open at a time.
    fn open(self: *PartCtx, path: []const u8) !?XmlTok {
        const entry = self.archive.find(path) orelse return null;
        try self.entry_reader.init(self.archive, entry, self.zip_window);
        return XmlTok.init(self.entry_reader.reader(), self.xml_window);
    }

    /// Like `open`, but for a path resolved to a concrete worksheet entry that
    /// must exist (the caller already matched the sheet name).
    fn openRequired(self: *PartCtx, path: []const u8) !XmlTok {
        return (try self.open(path)) orelse error.ZipBadFileOffset;
    }
};

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

/// The workbook-global parts shared by every sheet: the sheet name → path
/// map, the shared-strings table, and the date-style index set. Parsed once
/// by `init` and **read-only** afterwards, so a `*const Workbook` is safe to
/// share across threads that each extract a different sheet (the bxp-cli
/// `xlsxPrePass` sheet fan-out relies on this).
pub const Workbook = struct {
    /// sheet name → relative path within xl/ (e.g. "worksheets/sheet3.xml").
    sheet_paths: std.StringHashMap([]const u8),
    /// Shared strings table (may be empty for number-only workbooks). This is
    /// the one part that must be fully resident — cells index into it.
    shared_strings: std.ArrayList([]u8),
    /// Set of 0-based cellXfs indices that map to date/time formats.
    date_styles: std.AutoHashMap(u32, void),

    /// Walk the archive's central directory once and parse the workbook,
    /// shared-strings and styles parts. A self-contained archive + windows
    /// are opened and freed inside; the returned structures own their memory
    /// (`alloc`) and outlive the file handle.
    pub fn init(alloc: Allocator, xlsx_file: std.fs.File) !Workbook {
        var archive: zipstream.Archive = undefined;
        try archive.init(alloc, xlsx_file);
        defer archive.deinit();

        const zip_window = try alloc.alloc(u8, ZIP_WINDOW_SIZE);
        defer alloc.free(zip_window);
        const xml_window = try alloc.alloc(u8, XML_WINDOW_SIZE);
        defer alloc.free(xml_window);

        var ctx: PartCtx = .{ .archive = &archive, .zip_window = zip_window, .xml_window = xml_window };

        var sheet_paths = try parseWorkbook(alloc, &ctx);
        errdefer {
            var it = sheet_paths.iterator();
            while (it.next()) |e| {
                alloc.free(e.key_ptr.*);
                alloc.free(e.value_ptr.*);
            }
            sheet_paths.deinit();
        }
        var shared_strings = try parseSharedStrings(alloc, &ctx);
        errdefer {
            for (shared_strings.items) |s| alloc.free(s);
            shared_strings.deinit(alloc);
        }
        const date_styles = try parseDateStyles(alloc, &ctx);
        return .{ .sheet_paths = sheet_paths, .shared_strings = shared_strings, .date_styles = date_styles };
    }

    pub fn deinit(self: *Workbook, alloc: Allocator) void {
        var it = self.sheet_paths.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        self.sheet_paths.deinit();
        for (self.shared_strings.items) |s| alloc.free(s);
        self.shared_strings.deinit(alloc);
        self.date_styles.deinit();
    }
};

/// Extract one sheet to `<out_basename><spec.output_suffix>` in `out_dir`,
/// using a `ctx` whose archive is already open on the xlsx file. A sheet whose
/// name is not found (prefix match) is silently skipped (no output), matching
/// the historical behaviour. `wb` is read-only.
fn extractSheetWithCtx(
    alloc: Allocator,
    ctx: *PartCtx,
    wb: *const Workbook,
    spec: SheetSpec,
    out_dir: std.fs.Dir,
    out_basename: []const u8,
) !void {
    // Prefix match: "OPEN POSITION" matches "OPEN POSITION 28022026".
    // Also handles exact names since startsWith("X", "X") == true.
    const rel_path = blk: {
        var sit = wb.sheet_paths.iterator();
        while (sit.next()) |e| {
            if (std.mem.startsWith(u8, e.key_ptr.*, spec.name)) break :blk e.value_ptr.*;
        }
        return; // sheet not found → skip (no output)
    };

    const csv_name = try std.fmt.allocPrint(alloc, "{s}{s}", .{ out_basename, spec.output_suffix });
    defer alloc.free(csv_name);
    const xml_path = try std.fmt.allocPrint(alloc, "xl/{s}", .{rel_path});
    defer alloc.free(xml_path);

    const out_file = try out_dir.createFile(csv_name, .{});
    defer out_file.close();

    var out_buf: [CSV_OUT_BUF_SIZE]u8 = undefined;
    var out_fw = out_file.writer(&out_buf);

    try parseSheet(
        alloc,
        ctx,
        xml_path,
        spec.header_row,
        wb.shared_strings.items,
        &wb.date_styles,
        &out_fw.interface,
    );
    try out_fw.interface.flush();
}

/// Extract one sheet, opening its OWN archive + windows on `xlsx_file`. Because
/// it drives an independent file cursor (zipstream is single-cursor per
/// archive), this is safe to call concurrently from multiple threads as long
/// as each call is given its own `xlsx_file` handle; `wb` is shared read-only.
/// This is the unit of the bxp-cli sheet fan-out (mirrors `zipPrePass`).
pub fn extractSheet(
    alloc: Allocator,
    xlsx_file: std.fs.File,
    wb: *const Workbook,
    spec: SheetSpec,
    out_dir: std.fs.Dir,
    out_basename: []const u8,
) !void {
    var archive: zipstream.Archive = undefined;
    try archive.init(alloc, xlsx_file);
    defer archive.deinit();

    const zip_window = try alloc.alloc(u8, ZIP_WINDOW_SIZE);
    defer alloc.free(zip_window);
    const xml_window = try alloc.alloc(u8, XML_WINDOW_SIZE);
    defer alloc.free(xml_window);

    var ctx: PartCtx = .{ .archive = &archive, .zip_window = zip_window, .xml_window = xml_window };
    try extractSheetWithCtx(alloc, &ctx, wb, spec, out_dir, out_basename);
}

/// Converts selected sheets from an xlsx file to CSV files in out_dir.
///
/// Output files are named "<out_basename><spec.output_suffix>" (output_suffix includes the extension, e.g. "_open.csv").
/// Always re-extracts every requested sheet. Sheets whose name is not found in
/// the workbook are silently skipped. Serial loop — bxp-cli's `xlsxPrePass`
/// fans the per-sheet extraction out across threads via `Workbook` +
/// `extractSheet` instead; this entry point keeps the simple single-threaded
/// path for direct callers and tests.
pub fn xlsxToCsv(
    alloc: Allocator,
    xlsx_file: std.fs.File,
    sheets: []const SheetSpec,
    out_dir: std.fs.Dir,
    out_basename: []const u8,
) !void {
    var wb = try Workbook.init(alloc, xlsx_file);
    defer wb.deinit(alloc);

    // A second archive drives the sheet streaming (the one in `Workbook.init`
    // is already closed). The two windows are reused across all sheets.
    var archive: zipstream.Archive = undefined;
    try archive.init(alloc, xlsx_file);
    defer archive.deinit();

    const zip_window = try alloc.alloc(u8, ZIP_WINDOW_SIZE);
    defer alloc.free(zip_window);
    const xml_window = try alloc.alloc(u8, XML_WINDOW_SIZE);
    defer alloc.free(xml_window);

    var ctx: PartCtx = .{ .archive = &archive, .zip_window = zip_window, .xml_window = xml_window };
    for (sheets) |spec| {
        try extractSheetWithCtx(alloc, &ctx, &wb, spec, out_dir, out_basename);
    }
}

// ---------------------------------------------------------------------------
// Workbook parser  (xl/workbook.xml + xl/_rels/workbook.xml.rels)
// ---------------------------------------------------------------------------

/// Returns a StringHashMap: sheet_name → relative path within xl/.
/// Caller owns map and its key/value strings; use the deinit pattern below:
///   var it = map.iterator(); while (it.next()) |e| { free key, free value }
///   map.deinit();
///
/// The workbook XML and relationships file are parsed separately because the
/// name→rId mapping and the rId→path mapping live in different XML files:
///   xl/workbook.xml            → sheet name and relationship ID (r:id)
///   xl/_rels/workbook.xml.rels → relationship ID and target worksheet path
/// Two-phase join is required to get name→path.
fn parseWorkbook(alloc: Allocator, ctx: *PartCtx) !std.StringHashMap([]const u8) {
    // Use an arena for the intermediate name→rId and rId→path maps so that we
    // don't have to individually free every entry on the happy path.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var name_to_rid = std.StringHashMap([]const u8).init(aa);
    var rid_to_path = std.StringHashMap([]const u8).init(aa);

    // xl/_rels/workbook.xml.rels  →  rId → worksheet target path
    if (try ctx.open("xl/_rels/workbook.xml.rels")) |rels_tok| {
        var tok = rels_tok;
        while (try tok.next()) |token| {
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
    }

    // xl/workbook.xml  →  sheet name → rId
    if (try ctx.open("xl/workbook.xml")) |wb_tok| {
        var tok = wb_tok;
        while (try tok.next()) |token| {
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
    } else return std.StringHashMap([]const u8).init(alloc);

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
///
/// An <si> (shared string item) can contain multiple <t> (text run) children,
/// for example when parts of the string have different formatting. We
/// concatenate all <t> runs into a single string per <si> because bxp-cli
/// only cares about the plain text content, not the per-run formatting.
/// The result is indexed by the integer value stored in the 's' cell attribute.
fn parseSharedStrings(alloc: Allocator, ctx: *PartCtx) !std.ArrayList([]u8) {
    var strings: std.ArrayList([]u8) = .empty;
    // Streamed-but-resident: the table itself must persist (cells index into it),
    // so free what we built if we error out part-way (e.g. the zip-bomb cap).
    errdefer {
        for (strings.items) |s| alloc.free(s);
        strings.deinit(alloc);
    }

    var tok = (try ctx.open("xl/sharedStrings.xml")) orelse return strings;
    if (try tok.peekUtf16Bom()) return error.Utf16XmlUnsupported;

    var in_si = false;
    var in_t = false;
    var total: usize = 0; // running table size — guarded by XLSX_SHARED_STRINGS_CAP
    // Accumulator for the current <si> text (multiple <t> runs are concatenated).
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(alloc);

    while (try tok.next()) |token| {
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
                    const s = try current.toOwnedSlice(alloc);
                    total +|= s.len;
                    if (total > XLSX_SHARED_STRINGS_CAP) {
                        alloc.free(s);
                        return error.FileTooBig;
                    }
                    try strings.append(alloc, s);
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
fn parseDateStyles(alloc: Allocator, ctx: *PartCtx) !std.AutoHashMap(u32, void) {
    var date_xf: std.AutoHashMap(u32, void) = std.AutoHashMap(u32, void).init(alloc);
    errdefer date_xf.deinit();

    // First pass: collect custom numFmtIds that represent date/time formats.
    // Excel defines built-in numFmtIds 14–22 and 45–47 as date/time; any id
    // ≥ 164 is user-defined. We examine the formatCode string to decide
    // whether a custom format is a date (contains d/y/h/m outside quoted runs).
    // styles.xml is small; the two passes stream it twice (a fresh entry reader)
    // rather than buffering — cheaper than materialising and re-scanning.
    var custom_date_fmts = std.AutoHashMap(u32, void).init(alloc);
    defer custom_date_fmts.deinit();
    if (try ctx.open("xl/styles.xml")) |styles_tok| {
        var tok = styles_tok;
        while (try tok.next()) |token| {
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
    } else return date_xf; // no styles.xml → nothing is date-formatted

    // Second pass: find cellXfs entries and record which ones have date numFmtIds.
    // cellXfs is an ordered list of cell format records; the 0-based index into
    // this list is the value stored in the 's' attribute of each <c> cell element.
    // We build a set of indices so that resolveCellValue can do an O(1) lookup.
    if (try ctx.open("xl/styles.xml")) |styles_tok2| {
        var tok = styles_tok2;
        var in_cell_xfs = false;
        var xf_idx: u32 = 0;

        while (try tok.next()) |token| {
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
/// IDs 0–13 are non-date built-ins (general, number, currency, etc.).
/// IDs ≥ 164 are user-defined and tested separately via isDateFormatCode.
fn isBuiltinDateFmt(id: u32) bool {
    return (id >= 14 and id <= 22) or (id >= 45 and id <= 47);
}

/// Returns true if the Excel format code describes a date or time value.
/// Scans for d/y/h/m tokens outside quoted strings and bracket expressions.
///
/// Excel format codes use square brackets for locale or elapsed-time markers
/// (e.g. [h] for elapsed hours, [$USD-409] for a currency locale). These must
/// be skipped so that the 'h' in [h] doesn't trigger a false positive.
/// Quoted substrings (both " and ' delimited) are also skipped because they
/// contain literal text, not format tokens.
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
                // Skip bracket expression (locale, elapsed-time marker, etc.)
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
    ctx: *PartCtx,
    xml_path: []const u8,
    header_row: u32,
    shared_strings: []const []u8,
    date_styles: *const std.AutoHashMap(u32, void),
    out: *std.Io.Writer,
) !void {
    var tok = try ctx.openRequired(xml_path);
    if (try tok.peekUtf16Bom()) return error.Utf16XmlUnsupported;

    // Cells in the current row: index = 0-based column, value = owned string.
    var row_cells: std.ArrayList([]u8) = .empty;
    defer {
        for (row_cells.items) |s| alloc.free(s);
        row_cells.deinit(alloc);
    }

    // Accumulates the raw <v> or <t> text for the current cell.
    var cell_val_buf: std.ArrayList(u8) = .empty;
    defer cell_val_buf.deinit(alloc);

    // col_count and skip_cols are derived from the header row and then held
    // constant for all subsequent data rows, ensuring every output row has
    // the same number of columns regardless of how many cells Excel wrote.
    // skip_cols handles workbooks where column A is intentionally left blank
    // as a visual margin — the blank leading columns are stripped from both
    // the header row and every data row so the CSV aligns correctly.
    var col_count: u32 = 0; // set from header row; used to pad/truncate data rows
    var skip_cols: u32 = 0; // leading empty columns stripped from header (e.g. xlsx column A)
    var current_row: u32 = 0;
    var in_row: bool = false;
    var in_cell: bool = false;
    var in_value: bool = false; // inside <v>
    var in_inline_t: bool = false; // inside <is><t>
    var cell_col: u32 = 0;
    // cell_type is read at the `<c>` open but consumed at the matching `</c>`
    // close, several `next()` calls (and window compactions) later — so it is
    // COPIED out of the tokenizer window into this small backing buffer rather
    // than aliasing the window. Known types are short ("s"/"b"/"str"/"inlineStr").
    var cell_type_buf: [16]u8 = undefined;
    var cell_type: []const u8 = "";
    var cell_style: u32 = 0;

    while (try tok.next()) |token| {
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
                    // Copy out of the window — see cell_type_buf declaration.
                    const t_attr = getAttr(t.attrs, "t") orelse "";
                    const tn = @min(t_attr.len, cell_type_buf.len);
                    @memcpy(cell_type_buf[0..tn], t_attr[0..tn]);
                    cell_type = cell_type_buf[0..tn];
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
                        // Excel only emits <c> elements for non-empty cells, so sparse
                        // rows need explicit gap-filling. We always alloc.free the
                        // existing slot before storing the resolved value — the slot
                        // may hold a padding "" that was allocated above, or a value
                        // from a previous iteration if two cells share the same column
                        // index (which shouldn't happen in valid xlsx, but is harmless).
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
/// - Expands scientific notation to plain decimal: "2.087960758E9" →
///   "2087960758", "1.5E-3" → "0.0015".
/// - Leaves other forms unchanged.
///
/// Excel stores numeric values at full f64 precision in the XML (e.g. ISIN
/// quantity "1000" may appear as "1000.0" or share counts as "2.087960758E9").
/// Downstream bxp-cli expressions expect clean integers or minimal decimals,
/// so normalization here prevents noise in rule comparisons and output values.
///
/// Scientific notation expands through the shared fixed-point `Decimal` core
/// (exact across the full i128 range, no float round-trip), the same numeric
/// core json.zig and expr.zig use — so the xlsx, JSON and CSV input paths all
/// turn an identical numeric string into an identical value.
fn normalizeNumber(alloc: Allocator, raw: []const u8) ![]u8 {
    // Scientific notation — expand through the shared fixed-point decimal core
    // (exact to i128, float-free), the same numeric core json.zig and expr.zig
    // use. Replaces the former f64 round-trip + `@abs(f) < 1e15` guard: Decimal
    // is exact across the full i128 range, and canonicalises fractional values
    // too ("1.5E-3" → "0.0015"), not only whole ones. Overflow / unparseable
    // falls back to the raw token. `@constCast` is sound — toString returns a
    // freshly allocated, single-owner buffer that this function owns.
    if (std.mem.indexOfAny(u8, raw, "Ee")) |_| {
        if (Decimal.parse(raw)) |d| return @constCast(try d.toString(alloc));
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
///
/// Excel column letters use a bijective base-26 encoding: A=1, Z=26, AA=27.
/// This differs from ordinary base-26 in that there is no zero digit — "A" is
/// 1, not 0. The loop accumulates the 1-based column number and the final
/// `col - 1` converts to 0-based for use as a slice index.
/// The numeric row part of the reference (e.g. "23" in "BC23") is skipped
/// because isAlphabetic returns false at the first digit character.
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
/// year bug — Lotus incorrectly treated 1900 as a leap year, so Excel's epoch
/// is shifted one day earlier than a naive Jan 1 1900 origin would produce).
/// Serial 25569 equals the Unix epoch 1970-01-01 00:00:00.
///
/// The fractional part of the serial encodes time: 0.5 = noon, 0.75 = 18:00.
/// We split floor(serial) for the date and (serial - floor) for the time so
/// that floating-point rounding of large serials doesn't bleed into the time
/// component.
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
///
/// The algorithm works in 400-year "eras" to avoid per-year leap-year
/// conditional chains. Key invariants:
///   z   = days since the proleptic Gregorian epoch Mar 1, 0000
///   era = 400-year era number
///   doe = day-of-era (0..146096 inclusive)
///   yoe = year-of-era (0..399 inclusive)
///   doy = day-of-year starting from March 1 (0..365)
///   mp  = month position within the March-based year (0=Mar, 1=Apr, ..., 11=Feb)
/// The month and year adjustment at the end converts from the March-1 base
/// back to January-1 so that January and February belong to the correct year.
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

/// Streaming pull-tokenizer for the xlsx XML parts. Reads from a
/// `*std.Io.Reader` (a ZIP entry's decompressed byte stream) through a
/// caller-provided window buffer, so no XML part is ever fully materialised —
/// the caller loops `next()` until it returns null.
///
/// Token slices (`name` / `attrs` / `text`) point into the window and are valid
/// only until the *next* `next()` call, which compacts the window. A consumer
/// that must keep a value across calls copies it (the worksheet parser copies
/// the tiny cell-type attribute — the only value it carries from a `<c>` open
/// to the matching close).
///
/// A single token — one tag, or one text run between tags — must fit in the
/// window; a longer one is `error.XmlTokenTooLong`. The default window
/// (`XML_WINDOW_SIZE`) comfortably holds any worksheet cell, tag, or
/// shared-string item.
///
/// Same minimal contract as before: no XML validation, no CDATA, entities left
/// to `decodeEntities`, no DOM. `skipPast` matches the `<?…?>` / `<!--…-->` /
/// `<!…>` terminators with a naive scan — correct for OOXML, whose comments
/// never contain the closing delimiter early.
const XmlTok = struct {
    src: *std.Io.Reader,
    buf: []u8,
    pos: usize = 0, // scan cursor within buf[0..end]
    end: usize = 0, // valid bytes: buf[0..end]
    eof: bool = false,

    const TokError = error{ XmlTokenTooLong, ReadFailed };

    fn init(src: *std.Io.Reader, buf: []u8) XmlTok {
        return .{ .src = src, .buf = buf };
    }

    /// Drop consumed bytes (buf[0..pos]) to the front, freeing tail room and
    /// invalidating any slice previously returned. Called only at a token
    /// boundary (before any slice of the next token is taken) and only when the
    /// cursor has passed the half-way mark — see `next`. Reclaiming lazily, in
    /// bulk, keeps the tokenizer O(n): compacting on every `next()` would memmove
    /// the whole window per token (O(n × window)).
    fn compact(self: *XmlTok) void {
        if (self.pos == 0) return;
        const keep = self.end - self.pos;
        std.mem.copyForwards(u8, self.buf[0..keep], self.buf[self.pos..self.end]);
        self.pos = 0;
        self.end = keep;
    }

    /// Make `buf[idx]` a valid byte, reading more from the stream if needed.
    /// Only ever grows `end` (never moves data), so slices already taken from
    /// `buf[0..end]` stay valid for the rest of this `next()`. Returns false
    /// once `idx` is past the stream's end.
    fn ensure(self: *XmlTok, idx: usize) TokError!bool {
        while (idx >= self.end) {
            if (self.eof) return false;
            if (self.end == self.buf.len) return error.XmlTokenTooLong;
            const n = self.src.readSliceShort(self.buf[self.end..]) catch return error.ReadFailed;
            if (n == 0) {
                self.eof = true;
                return idx < self.end;
            }
            self.end += n;
        }
        return true;
    }

    /// Peek the stream's first bytes for a UTF-16 BOM. Call once before the
    /// token loop; it does not consume.
    fn peekUtf16Bom(self: *XmlTok) TokError!bool {
        _ = try self.ensure(1);
        return hasUtf16Bom(self.buf[0..@min(self.end, 2)]);
    }

    fn next(self: *XmlTok) TokError!?XmlToken {
        // Reclaim the consumed prefix only once the cursor has passed the
        // window's half-way mark. This both bounds compaction to O(n) total and
        // guarantees ≥ half a window of contiguous space ahead of `pos`, so a
        // token up to that size is scanned without `ensure` ever hitting a full
        // buffer mid-token (which would invalidate the start offsets it caches).
        if (self.pos > self.buf.len / 2) self.compact();

        while (try self.ensure(self.pos)) {
            if (self.buf[self.pos] != '<') {
                // Text content up to the next '<'.
                const start = self.pos;
                while ((try self.ensure(self.pos)) and self.buf[self.pos] != '<') self.pos += 1;
                if (self.pos > start) return .{ .text = self.buf[start..self.pos] };
                continue;
            }

            // At '<' — need the following byte to classify.
            if (!try self.ensure(self.pos + 1)) {
                self.pos += 1;
                continue;
            }
            const nc = self.buf[self.pos + 1];

            // Processing instruction <?...?>
            if (nc == '?') {
                self.pos += 2;
                try self.skipPast("?>");
                continue;
            }

            // Comment <!--...--> or declaration <!...>
            if (nc == '!') {
                if ((try self.ensure(self.pos + 3)) and
                    std.mem.eql(u8, self.buf[self.pos + 1 .. self.pos + 4], "!--"))
                {
                    self.pos += 4;
                    try self.skipPast("-->");
                } else {
                    self.pos += 1;
                    try self.skipPast(">");
                }
                continue;
            }

            // End tag </name>
            if (nc == '/') {
                self.pos += 2;
                const start = self.pos;
                while ((try self.ensure(self.pos)) and self.buf[self.pos] != '>') self.pos += 1;
                const name = std.mem.trimRight(u8, self.buf[start..self.pos], " \t\r\n");
                if (self.pos < self.end) self.pos += 1; // consume '>'
                return .{ .close = name };
            }

            // Start tag (possibly self-closing).
            self.pos += 1; // skip '<'
            const name_start = self.pos;
            while ((try self.ensure(self.pos)) and
                self.buf[self.pos] != '>' and
                self.buf[self.pos] != '/' and
                !isWs(self.buf[self.pos])) self.pos += 1;
            const name = self.buf[name_start..self.pos];

            while ((try self.ensure(self.pos)) and isWs(self.buf[self.pos])) self.pos += 1;

            // Collect raw attribute text until an unquoted '>' or '/'.
            const attrs_start = self.pos;
            var q: u8 = 0;
            while (try self.ensure(self.pos)) {
                const c = self.buf[self.pos];
                if (q != 0) {
                    if (c == q) q = 0;
                } else if (c == '"' or c == '\'') {
                    q = c;
                } else if (c == '>' or c == '/') {
                    break;
                }
                self.pos += 1;
            }
            const attrs = std.mem.trimRight(u8, self.buf[attrs_start..self.pos], " \t\r\n");

            var self_close = false;
            if ((try self.ensure(self.pos)) and self.buf[self.pos] == '/') {
                self_close = true;
                self.pos += 1;
            }
            if ((try self.ensure(self.pos)) and self.buf[self.pos] == '>') self.pos += 1;

            if (name.len == 0) continue;
            return .{ .open = .{ .name = name, .attrs = attrs, .self_close = self_close } };
        }
        return null;
    }

    /// Consume bytes through the first occurrence of `needle` (or to EOF).
    /// Returns nothing, so it may reclaim buffer space as it scans — an
    /// arbitrarily long skipped region never overflows the window.
    fn skipPast(self: *XmlTok, needle: []const u8) TokError!void {
        var matched: usize = 0;
        while (true) {
            if (self.pos >= self.end) {
                self.compact(); // reclaim; safe — no live slice during a skip
                if (!try self.ensure(self.pos)) return; // EOF before a match
            }
            const c = self.buf[self.pos];
            self.pos += 1;
            if (c == needle[matched]) {
                matched += 1;
                if (matched == needle.len) return;
            } else {
                matched = if (c == needle[0]) 1 else 0;
            }
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
///
/// The namespace-agnostic matching lets callers ask for "id" and get the
/// value regardless of which XML namespace prefix (r:, x:, etc.) the
/// generator used. The workbook.xml sheet element uses "r:id" while the
/// relationships file uses plain "Id" — both resolve to the same rId value
/// through this logic.
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
        // Attributes without quotes (technically invalid XML but tolerated) are
        // skipped rather than attempted to parse, avoiding misaligned reads.
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
///
/// Handles the five predefined XML entities (&amp; &lt; &gt; &quot; &apos;)
/// and numeric character references in both decimal (&#N;) and hexadecimal
/// (&#xN;) forms. Unknown named entities are passed through unchanged so that
/// cell text is preserved even when the workbook uses vendor-specific entities.
/// An unterminated '&' (no ';' found) is treated as a literal ampersand.
/// Invalid Unicode code points in &#N; fall back to the replacement character
/// U+FFFD rather than returning an error, matching browser-like lenient
/// decoding behavior.
fn decodeEntities(src: []const u8, out: *std.ArrayList(u8), alloc: Allocator) !void {
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] != '&') {
            try out.append(alloc, src[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, src, i + 1, ';') orelse {
            // No closing ';' — treat '&' as literal and advance past it.
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
            // Numeric character reference: &#N; (decimal) or &#xN; (hex).
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

/// Detects a UTF-16 byte-order mark (LE `FF FE` / BE `FE FF`) at the start of
/// an XML part. OOXML (ECMA-376) permits UTF-8 or UTF-16, but Excel always
/// writes UTF-8 and this parser only handles UTF-8; a UTF-16 part would
/// otherwise be silently garbled (every other byte a NUL). Callers turn a true
/// here into `error.Utf16XmlUnsupported` so the pipeline can warn-and-skip
/// rather than emit garbage. (A UTF-8 BOM `EF BB BF` is harmless and not
/// flagged — the XML tokenizer skips leading bytes before the first `<`.)
fn hasUtf16Bom(bytes: []const u8) bool {
    return bytes.len >= 2 and
        ((bytes[0] == 0xFF and bytes[1] == 0xFE) or
        (bytes[0] == 0xFE and bytes[1] == 0xFF));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "hasUtf16Bom: detects LE/BE BOM, ignores UTF-8 and short input" {
    try testing.expect(hasUtf16Bom("\xff\xfe<")); // UTF-16 LE
    try testing.expect(hasUtf16Bom("\xfe\xff\x00<")); // UTF-16 BE
    try testing.expect(!hasUtf16Bom("\xef\xbb\xbf<?xml")); // UTF-8 BOM is fine
    try testing.expect(!hasUtf16Bom("<?xml version=\"1.0\"?>")); // plain UTF-8
    try testing.expect(!hasUtf16Bom("\xff")); // too short to decide
    try testing.expect(!hasUtf16Bom("")); // empty
}

// The ZIP central-directory walk + store/deflate read path is unit-tested in
// zipstream.zig; the real XTB version_needed mismatch is covered end-to-end on
// real workbooks by the xtb* datasets (test-02).

test "colRefToIndex: bijective base-26, row digits ignored, case-insensitive" {
    try testing.expectEqual(@as(u32, 0), colRefToIndex("A1"));
    try testing.expectEqual(@as(u32, 1), colRefToIndex("B"));
    try testing.expectEqual(@as(u32, 25), colRefToIndex("Z1"));
    try testing.expectEqual(@as(u32, 26), colRefToIndex("AA1")); // first two-letter col
    try testing.expectEqual(@as(u32, 54), colRefToIndex("BC23")); // 2*26+3-1
    try testing.expectEqual(@as(u32, 0), colRefToIndex("a1")); // lowercase tolerated
    try testing.expectEqual(@as(u32, 0), colRefToIndex("")); // empty → 0, never underflows
    try testing.expectEqual(@as(u32, 0), colRefToIndex("7")); // no letters → 0
}

test "normalizeNumber: trailing-zero strip + decimal-core scientific expansion" {
    const a = testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "1.0000", .want = "1" }, // all decimals stripped → drop point
        .{ .in = "518.740000", .want = "518.74" },
        .{ .in = "42", .want = "42" }, // no dot → verbatim
        .{ .in = "1.5", .want = "1.5" },
        .{ .in = "1E5", .want = "100000" }, // whole-valued sci → integer
        .{ .in = "1.5E2", .want = "150" },
        .{ .in = "1.5E-3", .want = "0.0015" }, // fractional sci now expands too
        // Decimal core is exact across the full i128 range — no 1e15 guard.
        .{ .in = "1e20", .want = "100000000000000000000" },
        // Genuinely out of i128 range → raw token preserved (passthrough).
        .{ .in = "1e40", .want = "1e40" },
    };
    for (cases) |c| {
        const got = try normalizeNumber(a, c.in);
        defer a.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "excelSerialToDatetime: epoch anchor + fractional time" {
    var buf: [19]u8 = undefined;
    // Serial 25569 is the documented Unix-epoch anchor.
    try testing.expectEqualStrings("1970-01-01 00:00:00", excelSerialToDatetime(25569.0, &buf));
    // 0.5 of a day → noon; the date part stays put.
    try testing.expectEqualStrings("1970-01-01 12:00:00", excelSerialToDatetime(25569.5, &buf));
    // 0.75 → 18:00.
    try testing.expectEqualStrings("1970-01-01 18:00:00", excelSerialToDatetime(25569.75, &buf));
}

test "unixDayToYMD: Hinnant civil-from-days anchors" {
    try testing.expectEqual(YMD{ .y = 1970, .m = 1, .d = 1 }, unixDayToYMD(0));
    try testing.expectEqual(YMD{ .y = 1969, .m = 12, .d = 31 }, unixDayToYMD(-1));
    try testing.expectEqual(YMD{ .y = 2000, .m = 2, .d = 29 }, unixDayToYMD(11016)); // leap day
}

test "decodeEntities: named, numeric, passthrough, and bare ampersand" {
    const a = testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "a&amp;b", .want = "a&b" },
        .{ .in = "&lt;tag&gt;", .want = "<tag>" },
        .{ .in = "&quot;x&apos;y", .want = "\"x'y" },
        .{ .in = "&#65;&#x41;", .want = "AA" }, // decimal + hex → 'A'
        .{ .in = "&unknown;", .want = "&unknown;" }, // unknown entity preserved
        .{ .in = "Q&A", .want = "Q&A" }, // bare '&' with no ';' is literal
    };
    for (cases) |c| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try decodeEntities(c.in, &out, a);
        try testing.expectEqualStrings(c.want, out.items);
    }
}

test "isDateFormatCode: tokens vs literals, brackets, and General" {
    try testing.expect(isDateFormatCode("yyyy-mm-dd"));
    try testing.expect(isDateFormatCode("h:mm:ss"));
    try testing.expect(!isDateFormatCode("General"));
    try testing.expect(!isDateFormatCode("0.00")); // pure numeric format
    // 'h' lives only inside an elapsed-time bracket → not a date token.
    try testing.expect(!isDateFormatCode("[Red]0"));
    // A real token after a quoted literal still counts.
    try testing.expect(isDateFormatCode("\"day \"d"));
}

test "isBuiltinDateFmt: documented builtin numFmtId ranges" {
    try testing.expect(isBuiltinDateFmt(14)); // m/d/yy
    try testing.expect(isBuiltinDateFmt(22)); // m/d/yy h:mm
    try testing.expect(isBuiltinDateFmt(45)); // mm:ss
    try testing.expect(isBuiltinDateFmt(47)); // mmss.0
    try testing.expect(!isBuiltinDateFmt(0)); // General
    try testing.expect(!isBuiltinDateFmt(23)); // gap between the two ranges
    try testing.expect(!isBuiltinDateFmt(48));
}

test "getAttr: exact + namespace-prefixed match, quote styles, missing" {
    try testing.expectEqualStrings("5", getAttr("r=\"5\" t=\"s\"", "r").?);
    try testing.expectEqualStrings("s", getAttr("r=\"5\" t=\"s\"", "t").?);
    try testing.expectEqualStrings("rId1", getAttr("r:id='rId1'", "id").?); // ns + single quotes
    try testing.expect(getAttr("r=\"5\"", "missing") == null);
}

test "stripNs: drops the namespace prefix" {
    try testing.expectEqualStrings("id", stripNs("r:id"));
    try testing.expectEqualStrings("id", stripNs("id"));
    try testing.expectEqualStrings("b:t", stripNs("a:b:t")); // splits on the first colon only
}

test "writeCsvField: RFC 4180 quoting" {
    var buf: [64]u8 = undefined;
    const Check = struct {
        fn run(b: []u8, value: []const u8, want: []const u8) !void {
            var w = std.Io.Writer.fixed(b);
            try writeCsvField(&w, value);
            try testing.expectEqualStrings(want, w.buffered());
        }
    };
    try Check.run(&buf, "plain", "plain"); // no special chars → verbatim
    try Check.run(&buf, "a,b", "\"a,b\""); // delimiter → wrap
    try Check.run(&buf, "say \"hi\"", "\"say \"\"hi\"\"\""); // quote → wrap + double
    try Check.run(&buf, "line\nbreak", "\"line\nbreak\""); // newline → wrap
}
