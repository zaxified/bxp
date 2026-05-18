//! Binary trace stream — compact metadata emitted by `bxp-cli --trace=bin`.
//!
//! Replaces the NDJSON `--trace=json` stream for GUI consumers. Frames carry
//! only metadata (per-output-row pointers into source CSV, error list,
//! pre_pass dump, aggregate stats); per-row drill-down (vars, rules, output
//! cell values) is recomputed on-demand by `bxp-fmt` seeking to a row's
//! `source_locator` byte offset.
//!
//! Layout:
//!
//!   ┌─────────────────────────────────────────┐
//!   │ magic      u32  little = 0x42585442     │  "BXTB"
//!   │ schema_ver u32  little                  │
//!   ├─────────────────────────────────────────┤
//!   │ ── frame ─────────────                  │
//!   │ type       u8                           │
//!   │ chunk_id   u16  little                  │  reserved for future multicore
//!   │ pay_len    u32  little                  │  bytes following this header
//!   │ ── payload ───────────                  │  variable, per FrameType
//!   ├─────────────────────────────────────────┤
//!   │ ── frame ─────────────                  │
//!   │ ...                                     │
//!
//! `pay_len` lets a reader skip unknown frame types — forward compatibility.
//!
//! Variable-length strings use a length-prefix (lp): `u32 len + bytes`.

const std = @import("std");

pub const FRAME_MAGIC: u32 = 0x42545842; // "BXTB" read little-endian
pub const SCHEMA_VERSION: u32 = 1;

pub const FrameType = enum(u8) {
    file_start = 0x01,
    file_end = 0x02,
    output_row = 0x03,
    filtered_row = 0x04,
    error_row = 0x05,
    prepass_entry = 0x06,
    done = 0x07,
    _, // non-exhaustive — unknown types are skipped via `pay_len`
};

pub const InputFormat = enum(u8) {
    csv = 0,
    json = 1,
    xlsx_intermediate_csv = 2,
};

// ────────────────────────────────────────────────────────────────────────────
// Writer
// ────────────────────────────────────────────────────────────────────────────

/// Emits binary frames to an `std.Io.Writer`. Always writes magic + version
/// header on `init`. Caller must call `flush` on the underlying writer when
/// done (this writer does not flush — that's the parent's job, same pattern
/// as `Output.event` in bxp-cli).
pub const Writer = struct {
    w: *std.Io.Writer,
    chunk_id: u16,

    pub fn init(w: *std.Io.Writer) !Writer {
        try w.writeInt(u32, FRAME_MAGIC, .little);
        try w.writeInt(u32, SCHEMA_VERSION, .little);
        return .{ .w = w, .chunk_id = 0 };
    }

    fn writeHeader(self: *Writer, t: FrameType, payload_len: u32) !void {
        try self.w.writeByte(@intFromEnum(t));
        try self.w.writeInt(u16, self.chunk_id, .little);
        try self.w.writeInt(u32, payload_len, .little);
    }

    fn writeLp(self: *Writer, s: []const u8) !void {
        try self.w.writeInt(u32, @intCast(s.len), .little);
        try self.w.writeAll(s);
    }

    inline fn lpSize(s: []const u8) usize {
        return 4 + s.len;
    }

    pub fn writeFileStart(
        self: *Writer,
        input_format: InputFormat,
        template: []const u8,
        path: []const u8,
        headers: []const []const u8,
        out_headers: []const []const u8,
    ) !void {
        var payload_len: usize = 1 + lpSize(template) + lpSize(path) + 2 + 2;
        for (headers) |h| payload_len += lpSize(h);
        for (out_headers) |h| payload_len += lpSize(h);

        try self.writeHeader(.file_start, @intCast(payload_len));
        try self.w.writeByte(@intFromEnum(input_format));
        try self.writeLp(template);
        try self.writeLp(path);
        try self.w.writeInt(u16, @intCast(headers.len), .little);
        for (headers) |h| try self.writeLp(h);
        try self.w.writeInt(u16, @intCast(out_headers.len), .little);
        for (out_headers) |h| try self.writeLp(h);
    }

    pub fn writeFileEnd(
        self: *Writer,
        source_rows: u64,
        written_rows: u64,
        errors: u32,
        warnings: u32,
    ) !void {
        try self.writeHeader(.file_end, 24);
        try self.w.writeInt(u64, source_rows, .little);
        try self.w.writeInt(u64, written_rows, .little);
        try self.w.writeInt(u32, errors, .little);
        try self.w.writeInt(u32, warnings, .little);
    }

    pub fn writeOutputRow(
        self: *Writer,
        source_locator: u64,
        output_idx: u64,
        rule_idx: i32,
        action_idx: u16,
    ) !void {
        try self.writeHeader(.output_row, 22);
        try self.w.writeInt(u64, source_locator, .little);
        try self.w.writeInt(u64, output_idx, .little);
        try self.w.writeInt(i32, rule_idx, .little);
        try self.w.writeInt(u16, action_idx, .little);
    }

    pub fn writeFilteredRow(self: *Writer, source_locator: u64, reason_idx: u16) !void {
        try self.writeHeader(.filtered_row, 10);
        try self.w.writeInt(u64, source_locator, .little);
        try self.w.writeInt(u16, reason_idx, .little);
    }

    pub fn writeErrorRow(
        self: *Writer,
        source_locator: u64,
        var_name: []const u8,
        error_kind: []const u8,
        detail: []const u8,
        origin_idx: u8,
    ) !void {
        const payload_len = 8 + lpSize(var_name) + lpSize(error_kind) + lpSize(detail) + 1;
        try self.writeHeader(.error_row, @intCast(payload_len));
        try self.w.writeInt(u64, source_locator, .little);
        try self.writeLp(var_name);
        try self.writeLp(error_kind);
        try self.writeLp(detail);
        try self.w.writeByte(origin_idx);
    }

    pub fn writePrepassEntry(
        self: *Writer,
        name: []const u8,
        key: []const u8,
        field: []const u8,
        value: []const u8,
    ) !void {
        const payload_len = lpSize(name) + lpSize(key) + lpSize(field) + lpSize(value);
        try self.writeHeader(.prepass_entry, @intCast(payload_len));
        try self.writeLp(name);
        try self.writeLp(key);
        try self.writeLp(field);
        try self.writeLp(value);
    }

    pub fn writeDone(self: *Writer, exit_code: i32) !void {
        try self.writeHeader(.done, 4);
        try self.w.writeInt(i32, exit_code, .little);
    }
};

// ────────────────────────────────────────────────────────────────────────────
// Reader
// ────────────────────────────────────────────────────────────────────────────

pub const Frame = union(enum) {
    file_start: FileStart,
    file_end: FileEnd,
    output_row: OutputRow,
    filtered_row: FilteredRow,
    error_row: ErrorRow,
    prepass_entry: PrepassEntry,
    done: Done,
};

pub const FileStart = struct {
    chunk_id: u16,
    input_format: InputFormat,
    template: []const u8,
    path: []const u8,
    headers: []const []const u8,
    out_headers: []const []const u8,
};

pub const FileEnd = struct {
    chunk_id: u16,
    source_rows: u64,
    written_rows: u64,
    errors: u32,
    warnings: u32,
};

pub const OutputRow = struct {
    chunk_id: u16,
    source_locator: u64,
    output_idx: u64,
    rule_idx: i32,
    action_idx: u16,
};

pub const FilteredRow = struct {
    chunk_id: u16,
    source_locator: u64,
    reason_idx: u16,
};

pub const ErrorRow = struct {
    chunk_id: u16,
    source_locator: u64,
    var_name: []const u8,
    error_kind: []const u8,
    detail: []const u8,
    origin_idx: u8,
};

pub const PrepassEntry = struct {
    chunk_id: u16,
    name: []const u8,
    key: []const u8,
    field: []const u8,
    value: []const u8,
};

pub const Done = struct {
    chunk_id: u16,
    exit_code: i32,
};

/// Read-side counterpart to `Writer`. Pass an allocator (ideally arena);
/// returned variable-length strings inside frames are owned by it.
/// Use `nextFrame` in a loop until it returns `null` at EOF.
pub const Reader = struct {
    r: *std.Io.Reader,
    alloc: std.mem.Allocator,

    pub fn init(r: *std.Io.Reader, alloc: std.mem.Allocator) !Reader {
        const magic = try r.takeInt(u32, .little);
        if (magic != FRAME_MAGIC) return error.InvalidMagic;
        const version = try r.takeInt(u32, .little);
        if (version != SCHEMA_VERSION) return error.UnsupportedVersion;
        return .{ .r = r, .alloc = alloc };
    }

    fn readLp(self: *Reader) ![]const u8 {
        const len = try self.r.takeInt(u32, .little);
        const src = try self.r.take(len);
        const owned = try self.alloc.alloc(u8, len);
        @memcpy(owned, src);
        return owned;
    }

    /// Returns next frame, or `null` at EOF. Unknown frame types are silently
    /// skipped via `pay_len` (forward compat).
    pub fn nextFrame(self: *Reader) !?Frame {
        while (true) {
            const type_byte = self.r.takeByte() catch |err| switch (err) {
                error.EndOfStream => return null,
                else => return err,
            };
            const chunk_id = try self.r.takeInt(u16, .little);
            const pay_len = try self.r.takeInt(u32, .little);
            const ft: FrameType = @enumFromInt(type_byte);
            switch (ft) {
                .file_start => {
                    const input_format: InputFormat = @enumFromInt(try self.r.takeByte());
                    const template = try self.readLp();
                    const path = try self.readLp();
                    const headers_count = try self.r.takeInt(u16, .little);
                    const headers = try self.alloc.alloc([]const u8, headers_count);
                    for (0..headers_count) |i| headers[i] = try self.readLp();
                    const out_count = try self.r.takeInt(u16, .little);
                    const out_headers = try self.alloc.alloc([]const u8, out_count);
                    for (0..out_count) |i| out_headers[i] = try self.readLp();
                    return Frame{ .file_start = .{
                        .chunk_id = chunk_id,
                        .input_format = input_format,
                        .template = template,
                        .path = path,
                        .headers = headers,
                        .out_headers = out_headers,
                    } };
                },
                .file_end => return Frame{ .file_end = .{
                    .chunk_id = chunk_id,
                    .source_rows = try self.r.takeInt(u64, .little),
                    .written_rows = try self.r.takeInt(u64, .little),
                    .errors = try self.r.takeInt(u32, .little),
                    .warnings = try self.r.takeInt(u32, .little),
                } },
                .output_row => return Frame{ .output_row = .{
                    .chunk_id = chunk_id,
                    .source_locator = try self.r.takeInt(u64, .little),
                    .output_idx = try self.r.takeInt(u64, .little),
                    .rule_idx = try self.r.takeInt(i32, .little),
                    .action_idx = try self.r.takeInt(u16, .little),
                } },
                .filtered_row => return Frame{ .filtered_row = .{
                    .chunk_id = chunk_id,
                    .source_locator = try self.r.takeInt(u64, .little),
                    .reason_idx = try self.r.takeInt(u16, .little),
                } },
                .error_row => {
                    const source_locator = try self.r.takeInt(u64, .little);
                    const var_name = try self.readLp();
                    const error_kind = try self.readLp();
                    const detail = try self.readLp();
                    const origin_idx = try self.r.takeByte();
                    return Frame{ .error_row = .{
                        .chunk_id = chunk_id,
                        .source_locator = source_locator,
                        .var_name = var_name,
                        .error_kind = error_kind,
                        .detail = detail,
                        .origin_idx = origin_idx,
                    } };
                },
                .prepass_entry => return Frame{ .prepass_entry = .{
                    .chunk_id = chunk_id,
                    .name = try self.readLp(),
                    .key = try self.readLp(),
                    .field = try self.readLp(),
                    .value = try self.readLp(),
                } },
                .done => return Frame{ .done = .{
                    .chunk_id = chunk_id,
                    .exit_code = try self.r.takeInt(i32, .little),
                } },
                _ => {
                    // Forward compat: skip unknown frame via pay_len.
                    try self.r.discardAll(pay_len);
                },
            }
        }
    }
};

// ────────────────────────────────────────────────────────────────────────────
// Inline tests — write → read back → assert equality.
// ────────────────────────────────────────────────────────────────────────────

test "magic + version emitted on init" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try Writer.init(&w);
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 8), out.len);
    var rdr: std.Io.Reader = .fixed(out);
    try std.testing.expectEqual(FRAME_MAGIC, try rdr.takeInt(u32, .little));
    try std.testing.expectEqual(SCHEMA_VERSION, try rdr.takeInt(u32, .little));
}

test "Reader rejects wrong magic" {
    const buf = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x00, 0x00, 0x00 };
    var rdr: std.Io.Reader = .fixed(&buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidMagic, Reader.init(&rdr, arena.allocator()));
}

test "Reader rejects unsupported version" {
    var hdr: [8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&hdr);
    try w.writeInt(u32, FRAME_MAGIC, .little);
    try w.writeInt(u32, 9999, .little);
    var rdr: std.Io.Reader = .fixed(&hdr);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnsupportedVersion, Reader.init(&rdr, arena.allocator()));
}

test "roundtrip file_start" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw = try Writer.init(&w);
    const headers = [_][]const u8{ "Date", "Type", "Amount" };
    const out_headers = [_][]const u8{ "date", "activity" };
    try bw.writeFileStart(.csv, "anycoin_to_wealthfolio", "/tmp/foo.csv", &headers, &out_headers);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());
    const f = (try br.nextFrame()).?;
    try std.testing.expectEqual(@as(std.meta.Tag(Frame), .file_start), std.meta.activeTag(f));
    const fs = f.file_start;
    try std.testing.expectEqual(InputFormat.csv, fs.input_format);
    try std.testing.expectEqualStrings("anycoin_to_wealthfolio", fs.template);
    try std.testing.expectEqualStrings("/tmp/foo.csv", fs.path);
    try std.testing.expectEqual(@as(usize, 3), fs.headers.len);
    try std.testing.expectEqualStrings("Date", fs.headers[0]);
    try std.testing.expectEqualStrings("Amount", fs.headers[2]);
    try std.testing.expectEqualStrings("activity", fs.out_headers[1]);
}

test "roundtrip file_end" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw = try Writer.init(&w);
    try bw.writeFileEnd(100_000, 25_000, 7, 3);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());
    const f = (try br.nextFrame()).?;
    const fe = f.file_end;
    try std.testing.expectEqual(@as(u64, 100_000), fe.source_rows);
    try std.testing.expectEqual(@as(u64, 25_000), fe.written_rows);
    try std.testing.expectEqual(@as(u32, 7), fe.errors);
    try std.testing.expectEqual(@as(u32, 3), fe.warnings);
}

test "roundtrip output_row including negative rule_idx" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw = try Writer.init(&w);
    try bw.writeOutputRow(0xDEADBEEF, 42, -1, 5);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());
    const f = (try br.nextFrame()).?;
    const orow = f.output_row;
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), orow.source_locator);
    try std.testing.expectEqual(@as(u64, 42), orow.output_idx);
    try std.testing.expectEqual(@as(i32, -1), orow.rule_idx);
    try std.testing.expectEqual(@as(u16, 5), orow.action_idx);
}

test "roundtrip filtered_row" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw = try Writer.init(&w);
    try bw.writeFilteredRow(123_456, 1);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());
    const f = (try br.nextFrame()).?;
    const fr = f.filtered_row;
    try std.testing.expectEqual(@as(u64, 123_456), fr.source_locator);
    try std.testing.expectEqual(@as(u16, 1), fr.reason_idx);
}

test "roundtrip error_row" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw = try Writer.init(&w);
    try bw.writeErrorRow(500, "$date", "DateConvertError", "format mismatch: 'DD.MM.YYYY'", 0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());
    const f = (try br.nextFrame()).?;
    const er = f.error_row;
    try std.testing.expectEqual(@as(u64, 500), er.source_locator);
    try std.testing.expectEqualStrings("$date", er.var_name);
    try std.testing.expectEqualStrings("DateConvertError", er.error_kind);
    try std.testing.expectEqualStrings("format mismatch: 'DD.MM.YYYY'", er.detail);
    try std.testing.expectEqual(@as(u8, 0), er.origin_idx);
}

test "roundtrip prepass_entry" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw = try Writer.init(&w);
    try bw.writePrepassEntry("orders", "ORDER-123", "filled_price", "150.25");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());
    const f = (try br.nextFrame()).?;
    const pe = f.prepass_entry;
    try std.testing.expectEqualStrings("orders", pe.name);
    try std.testing.expectEqualStrings("ORDER-123", pe.key);
    try std.testing.expectEqualStrings("filled_price", pe.field);
    try std.testing.expectEqualStrings("150.25", pe.value);
}

test "roundtrip done" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw = try Writer.init(&w);
    try bw.writeDone(2);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());
    const f = (try br.nextFrame()).?;
    try std.testing.expectEqual(@as(i32, 2), f.done.exit_code);
}

test "UTF-8 multibyte in lp string" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw = try Writer.init(&w);
    try bw.writeErrorRow(0, "$ticker", "MapError", "česká koruna ✓", 1);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());
    const f = (try br.nextFrame()).?;
    try std.testing.expectEqualStrings("česká koruna ✓", f.error_row.detail);
}

test "empty lp string" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw = try Writer.init(&w);
    try bw.writePrepassEntry("", "", "", "");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());
    const f = (try br.nextFrame()).?;
    try std.testing.expectEqual(@as(usize, 0), f.prepass_entry.name.len);
    try std.testing.expectEqual(@as(usize, 0), f.prepass_entry.value.len);
}

test "multiple frames in sequence" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw = try Writer.init(&w);
    try bw.writeOutputRow(10, 0, 0, 1);
    try bw.writeOutputRow(20, 1, 1, 2);
    try bw.writeFilteredRow(30, 0);
    try bw.writeDone(0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());
    try std.testing.expectEqual(@as(u64, 10), (try br.nextFrame()).?.output_row.source_locator);
    try std.testing.expectEqual(@as(u64, 20), (try br.nextFrame()).?.output_row.source_locator);
    try std.testing.expectEqual(@as(u64, 30), (try br.nextFrame()).?.filtered_row.source_locator);
    try std.testing.expectEqual(@as(i32, 0), (try br.nextFrame()).?.done.exit_code);
    try std.testing.expect((try br.nextFrame()) == null);
}

test "EOF returns null" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try Writer.init(&w);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());
    try std.testing.expect((try br.nextFrame()) == null);
}

test "forward compat: unknown frame type skipped via pay_len" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // Magic + version manually.
    try w.writeInt(u32, FRAME_MAGIC, .little);
    try w.writeInt(u32, SCHEMA_VERSION, .little);
    // Unknown frame: type 0xFE, chunk_id 0, pay_len 5, payload "hello".
    try w.writeByte(0xFE);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u32, 5, .little);
    try w.writeAll("hello");
    // Real done frame after.
    var bw_after: Writer = .{ .w = &w, .chunk_id = 0 };
    try bw_after.writeDone(42);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());
    const f = (try br.nextFrame()).?;
    try std.testing.expectEqual(@as(i32, 42), f.done.exit_code);
}

test "chunk_id round-trips when set on writer" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw = try Writer.init(&w);
    bw.chunk_id = 7;
    try bw.writeOutputRow(99, 0, 0, 0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());
    const f = (try br.nextFrame()).?;
    try std.testing.expectEqual(@as(u16, 7), f.output_row.chunk_id);
}
