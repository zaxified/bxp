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
/// Schema v3 (2026-05-22): per-row detail frames (`row_start_fields`,
/// `var_eval`, `rule_match`, `rule_no_match`, `row_output`) are NO LONGER
/// emitted by the bxp-cli producer in the default path. The GUI reconstructs
/// drill-down data on demand via `bxp-fmt --expr-batch` (re-eval of one row's
/// input_schema + row_rules against config + source CSV) plus direct mmap
/// reads of source.csv / output.csvx at the `source_locator` / `output_idx`
/// addresses carried by `output_row`. Setting env var `BXP_EMIT_FULL_TRACE=1`
/// at runtime opts back into v2-style emission for debug / regression work;
/// the schema number on the wire stays 3 either way (frame layout did not
/// change, only emit policy).
/// Schema v2 (2026-05-21): symbol pools in `file_start` for expr / var_name /
/// rule.when so detail frames reference them by u16 index instead of repeating
/// the full string per row.
pub const SCHEMA_VERSION: u32 = 3;

pub const FrameType = enum(u8) {
    file_start = 0x01,
    file_end = 0x02,
    output_row = 0x03,
    filtered_row = 0x04,
    error_row = 0x05,
    prepass_entry = 0x06,
    done = 0x07,
    // ── per-row drill-down frames (added experiment phase) ────────────────
    row_start_fields = 0x08,
    var_eval = 0x09,
    rule_match = 0x0A,
    rule_no_match = 0x0B,
    row_output = 0x0C,
    _, // non-exhaustive — unknown types are skipped via `pay_len`
};

pub const InputFormat = enum(u8) {
    csv = 0,
    json = 1,
    xlsx_intermediate_csv = 2,
};

/// Origin tag for `var_eval` frames — matches the NDJSON `origin` string.
pub const VarOrigin = enum(u8) {
    input_schema = 0,
    row_rules = 1,
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
        expr_pool: []const []const u8,
        var_name_pool: []const []const u8,
        rule_when_pool: []const []const u8,
    ) !void {
        var payload_len: usize = 1 + lpSize(template) + lpSize(path) + 2 + 2 + 2 + 2 + 2;
        for (headers) |h| payload_len += lpSize(h);
        for (out_headers) |h| payload_len += lpSize(h);
        for (expr_pool) |s| payload_len += lpSize(s);
        for (var_name_pool) |s| payload_len += lpSize(s);
        for (rule_when_pool) |s| payload_len += lpSize(s);

        try self.writeHeader(.file_start, @intCast(payload_len));
        try self.w.writeByte(@intFromEnum(input_format));
        try self.writeLp(template);
        try self.writeLp(path);
        try self.w.writeInt(u16, @intCast(headers.len), .little);
        for (headers) |h| try self.writeLp(h);
        try self.w.writeInt(u16, @intCast(out_headers.len), .little);
        for (out_headers) |h| try self.writeLp(h);
        try self.w.writeInt(u16, @intCast(expr_pool.len), .little);
        for (expr_pool) |s| try self.writeLp(s);
        try self.w.writeInt(u16, @intCast(var_name_pool.len), .little);
        for (var_name_pool) |s| try self.writeLp(s);
        try self.w.writeInt(u16, @intCast(rule_when_pool.len), .little);
        for (rule_when_pool) |s| try self.writeLp(s);
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
        action: []const u8,
    ) !void {
        const payload_len = 8 + 8 + 4 + lpSize(action);
        try self.writeHeader(.output_row, @intCast(payload_len));
        try self.w.writeInt(u64, source_locator, .little);
        try self.w.writeInt(u64, output_idx, .little);
        try self.w.writeInt(i32, rule_idx, .little);
        try self.writeLp(action);
    }

    pub fn writeFilteredRow(self: *Writer, source_locator: u64, reason: []const u8) !void {
        const payload_len = 8 + lpSize(reason);
        try self.writeHeader(.filtered_row, @intCast(payload_len));
        try self.w.writeInt(u64, source_locator, .little);
        try self.writeLp(reason);
    }

    pub fn writeErrorRow(
        self: *Writer,
        source_locator: u64,
        var_name: []const u8,
        error_kind: []const u8,
        detail: []const u8,
        origin: []const u8,
    ) !void {
        const payload_len = 8 + lpSize(var_name) + lpSize(error_kind) + lpSize(detail) + lpSize(origin);
        try self.writeHeader(.error_row, @intCast(payload_len));
        try self.w.writeInt(u64, source_locator, .little);
        try self.writeLp(var_name);
        try self.writeLp(error_kind);
        try self.writeLp(detail);
        try self.writeLp(origin);
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

    // ── per-row drill-down frame writers ─────────────────────────────────
    // Mirror the NDJSON events emitted by pipeline.zig in `--trace=json`
    // mode. Enabled only when caller has bin_emit_detail = true (see
    // bxp-cli `Output` struct). Field count uses u16 to match file_start
    // headers (MAX_COLUMNS = 1024 fits comfortably).

    pub fn writeRowStartFields(
        self: *Writer,
        source_locator: u64,
        file_row: u64,
        fields: []const []const u8,
    ) !void {
        var payload_len: usize = 8 + 8 + 2;
        for (fields) |f| payload_len += lpSize(f);

        try self.writeHeader(.row_start_fields, @intCast(payload_len));
        try self.w.writeInt(u64, source_locator, .little);
        try self.w.writeInt(u64, file_row, .little);
        try self.w.writeInt(u16, @intCast(fields.len), .little);
        for (fields) |f| try self.writeLp(f);
    }

    pub fn writeVarEval(
        self: *Writer,
        source_locator: u64,
        var_name_idx: u16,
        expr_idx: u16,
        value: []const u8,
        origin: VarOrigin,
        rule_idx: i32,
        output_row_idx: i32,
    ) !void {
        const payload_len = 8 + 2 + 2 + lpSize(value) + 1 + 4 + 4;
        try self.writeHeader(.var_eval, @intCast(payload_len));
        try self.w.writeInt(u64, source_locator, .little);
        try self.w.writeInt(u16, var_name_idx, .little);
        try self.w.writeInt(u16, expr_idx, .little);
        try self.writeLp(value);
        try self.w.writeByte(@intFromEnum(origin));
        try self.w.writeInt(i32, rule_idx, .little);
        try self.w.writeInt(i32, output_row_idx, .little);
    }

    pub fn writeRuleMatch(
        self: *Writer,
        source_locator: u64,
        rule_idx: u32,
        when_idx: u16,
    ) !void {
        const payload_len = 8 + 4 + 2;
        try self.writeHeader(.rule_match, @intCast(payload_len));
        try self.w.writeInt(u64, source_locator, .little);
        try self.w.writeInt(u32, rule_idx, .little);
        try self.w.writeInt(u16, when_idx, .little);
    }

    pub fn writeRuleNoMatch(
        self: *Writer,
        source_locator: u64,
        rule_idx: u32,
        when_idx: u16,
        error_kind: []const u8,
    ) !void {
        const payload_len = 8 + 4 + 2 + lpSize(error_kind);
        try self.writeHeader(.rule_no_match, @intCast(payload_len));
        try self.w.writeInt(u64, source_locator, .little);
        try self.w.writeInt(u32, rule_idx, .little);
        try self.w.writeInt(u16, when_idx, .little);
        try self.writeLp(error_kind);
    }

    pub fn writeRowOutput(
        self: *Writer,
        source_locator: u64,
        output_idx: u64,
        values: []const []const u8,
    ) !void {
        var payload_len: usize = 8 + 8 + 2;
        for (values) |v| payload_len += lpSize(v);

        try self.writeHeader(.row_output, @intCast(payload_len));
        try self.w.writeInt(u64, source_locator, .little);
        try self.w.writeInt(u64, output_idx, .little);
        try self.w.writeInt(u16, @intCast(values.len), .little);
        for (values) |v| try self.writeLp(v);
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
    row_start_fields: RowStartFields,
    var_eval: VarEval,
    rule_match: RuleMatch,
    rule_no_match: RuleNoMatch,
    row_output: RowOutput,
};

pub const FileStart = struct {
    chunk_id: u16,
    input_format: InputFormat,
    template: []const u8,
    path: []const u8,
    headers: []const []const u8,
    out_headers: []const []const u8,
    expr_pool: []const []const u8,
    var_name_pool: []const []const u8,
    rule_when_pool: []const []const u8,
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
    action: []const u8,
};

pub const FilteredRow = struct {
    chunk_id: u16,
    source_locator: u64,
    reason: []const u8,
};

pub const ErrorRow = struct {
    chunk_id: u16,
    source_locator: u64,
    var_name: []const u8,
    error_kind: []const u8,
    detail: []const u8,
    origin: []const u8,
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

pub const RowStartFields = struct {
    chunk_id: u16,
    source_locator: u64,
    file_row: u64,
    fields: []const []const u8,
};

pub const VarEval = struct {
    chunk_id: u16,
    source_locator: u64,
    var_name_idx: u16,
    expr_idx: u16,
    value: []const u8,
    origin: VarOrigin,
    rule_idx: i32,
    output_row_idx: i32,
};

pub const RuleMatch = struct {
    chunk_id: u16,
    source_locator: u64,
    rule_idx: u32,
    when_idx: u16,
};

pub const RuleNoMatch = struct {
    chunk_id: u16,
    source_locator: u64,
    rule_idx: u32,
    when_idx: u16,
    error_kind: []const u8,
};

pub const RowOutput = struct {
    chunk_id: u16,
    source_locator: u64,
    output_idx: u64,
    values: []const []const u8,
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
        // Frame layout is identical across v2 and v3 — v3 only changes the
        // emit policy on the producer side (no detail by default). Accept
        // both so older traces still parse and the schema bump is a soft
        // boundary instead of a hard breakage for in-flight files.
        if (version != SCHEMA_VERSION and version != 2) return error.UnsupportedVersion;
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
                    const expr_pool_count = try self.r.takeInt(u16, .little);
                    const expr_pool = try self.alloc.alloc([]const u8, expr_pool_count);
                    for (0..expr_pool_count) |i| expr_pool[i] = try self.readLp();
                    const var_name_pool_count = try self.r.takeInt(u16, .little);
                    const var_name_pool = try self.alloc.alloc([]const u8, var_name_pool_count);
                    for (0..var_name_pool_count) |i| var_name_pool[i] = try self.readLp();
                    const rule_when_pool_count = try self.r.takeInt(u16, .little);
                    const rule_when_pool = try self.alloc.alloc([]const u8, rule_when_pool_count);
                    for (0..rule_when_pool_count) |i| rule_when_pool[i] = try self.readLp();
                    return Frame{ .file_start = .{
                        .chunk_id = chunk_id,
                        .input_format = input_format,
                        .template = template,
                        .path = path,
                        .headers = headers,
                        .out_headers = out_headers,
                        .expr_pool = expr_pool,
                        .var_name_pool = var_name_pool,
                        .rule_when_pool = rule_when_pool,
                    } };
                },
                .file_end => return Frame{ .file_end = .{
                    .chunk_id = chunk_id,
                    .source_rows = try self.r.takeInt(u64, .little),
                    .written_rows = try self.r.takeInt(u64, .little),
                    .errors = try self.r.takeInt(u32, .little),
                    .warnings = try self.r.takeInt(u32, .little),
                } },
                .output_row => {
                    const source_locator = try self.r.takeInt(u64, .little);
                    const output_idx = try self.r.takeInt(u64, .little);
                    const rule_idx = try self.r.takeInt(i32, .little);
                    const action = try self.readLp();
                    return Frame{ .output_row = .{
                        .chunk_id = chunk_id,
                        .source_locator = source_locator,
                        .output_idx = output_idx,
                        .rule_idx = rule_idx,
                        .action = action,
                    } };
                },
                .filtered_row => {
                    const source_locator = try self.r.takeInt(u64, .little);
                    const reason = try self.readLp();
                    return Frame{ .filtered_row = .{
                        .chunk_id = chunk_id,
                        .source_locator = source_locator,
                        .reason = reason,
                    } };
                },
                .error_row => {
                    const source_locator = try self.r.takeInt(u64, .little);
                    const var_name = try self.readLp();
                    const error_kind = try self.readLp();
                    const detail = try self.readLp();
                    const origin = try self.readLp();
                    return Frame{ .error_row = .{
                        .chunk_id = chunk_id,
                        .source_locator = source_locator,
                        .var_name = var_name,
                        .error_kind = error_kind,
                        .detail = detail,
                        .origin = origin,
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
                .row_start_fields => {
                    const source_locator = try self.r.takeInt(u64, .little);
                    const file_row = try self.r.takeInt(u64, .little);
                    const fields_count = try self.r.takeInt(u16, .little);
                    const fields = try self.alloc.alloc([]const u8, fields_count);
                    for (0..fields_count) |i| fields[i] = try self.readLp();
                    return Frame{ .row_start_fields = .{
                        .chunk_id = chunk_id,
                        .source_locator = source_locator,
                        .file_row = file_row,
                        .fields = fields,
                    } };
                },
                .var_eval => {
                    const source_locator = try self.r.takeInt(u64, .little);
                    const var_name_idx = try self.r.takeInt(u16, .little);
                    const expr_idx = try self.r.takeInt(u16, .little);
                    const value = try self.readLp();
                    const origin: VarOrigin = @enumFromInt(try self.r.takeByte());
                    const rule_idx = try self.r.takeInt(i32, .little);
                    const output_row_idx = try self.r.takeInt(i32, .little);
                    return Frame{ .var_eval = .{
                        .chunk_id = chunk_id,
                        .source_locator = source_locator,
                        .var_name_idx = var_name_idx,
                        .expr_idx = expr_idx,
                        .value = value,
                        .origin = origin,
                        .rule_idx = rule_idx,
                        .output_row_idx = output_row_idx,
                    } };
                },
                .rule_match => {
                    const source_locator = try self.r.takeInt(u64, .little);
                    const rule_idx = try self.r.takeInt(u32, .little);
                    const when_idx = try self.r.takeInt(u16, .little);
                    return Frame{ .rule_match = .{
                        .chunk_id = chunk_id,
                        .source_locator = source_locator,
                        .rule_idx = rule_idx,
                        .when_idx = when_idx,
                    } };
                },
                .rule_no_match => {
                    const source_locator = try self.r.takeInt(u64, .little);
                    const rule_idx = try self.r.takeInt(u32, .little);
                    const when_idx = try self.r.takeInt(u16, .little);
                    const error_kind = try self.readLp();
                    return Frame{ .rule_no_match = .{
                        .chunk_id = chunk_id,
                        .source_locator = source_locator,
                        .rule_idx = rule_idx,
                        .when_idx = when_idx,
                        .error_kind = error_kind,
                    } };
                },
                .row_output => {
                    const source_locator = try self.r.takeInt(u64, .little);
                    const output_idx = try self.r.takeInt(u64, .little);
                    const values_count = try self.r.takeInt(u16, .little);
                    const values = try self.alloc.alloc([]const u8, values_count);
                    for (0..values_count) |i| values[i] = try self.readLp();
                    return Frame{ .row_output = .{
                        .chunk_id = chunk_id,
                        .source_locator = source_locator,
                        .output_idx = output_idx,
                        .values = values,
                    } };
                },
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
    const expr_pool = [_][]const u8{ "TICKER([Symbol])", "DATE_CONVERT([Date], 'X', 'Y')" };
    const var_name_pool = [_][]const u8{ "$ticker", "$date" };
    const rule_when_pool = [_][]const u8{ "[Type] = 'BUY'" };
    try bw.writeFileStart(.csv, "anycoin_to_wealthfolio", "/tmp/foo.csv", &headers, &out_headers, &expr_pool, &var_name_pool, &rule_when_pool);

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
    try std.testing.expectEqual(@as(usize, 2), fs.expr_pool.len);
    try std.testing.expectEqualStrings("TICKER([Symbol])", fs.expr_pool[0]);
    try std.testing.expectEqualStrings("$date", fs.var_name_pool[1]);
    try std.testing.expectEqualStrings("[Type] = 'BUY'", fs.rule_when_pool[0]);
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
    try bw.writeOutputRow(0xDEADBEEF, 42, -1, "BUY");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());
    const f = (try br.nextFrame()).?;
    const orow = f.output_row;
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), orow.source_locator);
    try std.testing.expectEqual(@as(u64, 42), orow.output_idx);
    try std.testing.expectEqual(@as(i32, -1), orow.rule_idx);
    try std.testing.expectEqualStrings("BUY", orow.action);
}

test "roundtrip filtered_row" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw = try Writer.init(&w);
    try bw.writeFilteredRow(123_456, "date_filter_from_filename");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());
    const f = (try br.nextFrame()).?;
    const fr = f.filtered_row;
    try std.testing.expectEqual(@as(u64, 123_456), fr.source_locator);
    try std.testing.expectEqualStrings("date_filter_from_filename", fr.reason);
}

test "roundtrip error_row" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw = try Writer.init(&w);
    try bw.writeErrorRow(500, "$date", "DateConvertError", "format mismatch: 'DD.MM.YYYY'", "input_schema");

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
    try std.testing.expectEqualStrings("input_schema", er.origin);
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
    try bw.writeErrorRow(0, "$ticker", "MapError", "česká koruna ✓", "row_rules");

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
    try bw.writeOutputRow(10, 0, 0, "BUY");
    try bw.writeOutputRow(20, 1, 1, "SELL");
    try bw.writeFilteredRow(30, "date_filter_from_filename");
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

test "roundtrip row_start_fields" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw = try Writer.init(&w);
    const fields = [_][]const u8{ "EUR", "USD", "100.50", "" };
    try bw.writeRowStartFields(0xDEADBEEF, 42, &fields);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());
    const f = (try br.nextFrame()).?;
    const rsf = f.row_start_fields;
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), rsf.source_locator);
    try std.testing.expectEqual(@as(u64, 42), rsf.file_row);
    try std.testing.expectEqual(@as(usize, 4), rsf.fields.len);
    try std.testing.expectEqualStrings("EUR", rsf.fields[0]);
    try std.testing.expectEqualStrings("USD", rsf.fields[1]);
    try std.testing.expectEqualStrings("100.50", rsf.fields[2]);
    try std.testing.expectEqualStrings("", rsf.fields[3]);
}

test "roundtrip var_eval input_schema origin" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw = try Writer.init(&w);
    try bw.writeVarEval(123, 7, 42, "BTC-USD", .input_schema, -1, -1);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());
    const f = (try br.nextFrame()).?;
    const ve = f.var_eval;
    try std.testing.expectEqual(@as(u64, 123), ve.source_locator);
    try std.testing.expectEqual(@as(u16, 7), ve.var_name_idx);
    try std.testing.expectEqual(@as(u16, 42), ve.expr_idx);
    try std.testing.expectEqualStrings("BTC-USD", ve.value);
    try std.testing.expectEqual(VarOrigin.input_schema, ve.origin);
    try std.testing.expectEqual(@as(i32, -1), ve.rule_idx);
    try std.testing.expectEqual(@as(i32, -1), ve.output_row_idx);
}

test "roundtrip var_eval row_rules origin with indices" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw = try Writer.init(&w);
    try bw.writeVarEval(999, 3, 11, "BUY", .row_rules, 2, 0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());
    const f = (try br.nextFrame()).?;
    const ve = f.var_eval;
    try std.testing.expectEqual(VarOrigin.row_rules, ve.origin);
    try std.testing.expectEqual(@as(i32, 2), ve.rule_idx);
    try std.testing.expectEqual(@as(i32, 0), ve.output_row_idx);
    try std.testing.expectEqual(@as(u16, 3), ve.var_name_idx);
}

test "roundtrip rule_match and rule_no_match" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw = try Writer.init(&w);
    try bw.writeRuleMatch(100, 0, 5);
    try bw.writeRuleNoMatch(200, 1, 6, "");
    try bw.writeRuleNoMatch(300, 2, 7, "TypeMismatch");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());

    const f1 = (try br.nextFrame()).?;
    try std.testing.expectEqual(@as(u32, 0), f1.rule_match.rule_idx);
    try std.testing.expectEqual(@as(u16, 5), f1.rule_match.when_idx);

    const f2 = (try br.nextFrame()).?;
    try std.testing.expectEqual(@as(u32, 1), f2.rule_no_match.rule_idx);
    try std.testing.expectEqual(@as(u16, 6), f2.rule_no_match.when_idx);
    try std.testing.expectEqualStrings("", f2.rule_no_match.error_kind);

    const f3 = (try br.nextFrame()).?;
    try std.testing.expectEqual(@as(u32, 2), f3.rule_no_match.rule_idx);
    try std.testing.expectEqual(@as(u16, 7), f3.rule_no_match.when_idx);
    try std.testing.expectEqualStrings("TypeMismatch", f3.rule_no_match.error_kind);
}

test "roundtrip row_output" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw = try Writer.init(&w);
    const values = [_][]const u8{ "2026-05-21", "BTC-USD", "0.5", "BUY" };
    try bw.writeRowOutput(500, 17, &values);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());
    const f = (try br.nextFrame()).?;
    const ro = f.row_output;
    try std.testing.expectEqual(@as(u64, 500), ro.source_locator);
    try std.testing.expectEqual(@as(u64, 17), ro.output_idx);
    try std.testing.expectEqual(@as(usize, 4), ro.values.len);
    try std.testing.expectEqualStrings("2026-05-21", ro.values[0]);
    try std.testing.expectEqualStrings("BUY", ro.values[3]);
}

test "chunk_id round-trips when set on writer" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw = try Writer.init(&w);
    bw.chunk_id = 7;
    try bw.writeOutputRow(99, 0, 0, "BUY");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rdr: std.Io.Reader = .fixed(w.buffered());
    var br = try Reader.init(&rdr, arena.allocator());
    const f = (try br.nextFrame()).?;
    try std.testing.expectEqual(@as(u16, 7), f.output_row.chunk_id);
}
