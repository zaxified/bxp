/// Streaming JSON array-of-objects reader for bxp-cli.
///
/// Source files are JSON arrays where each top-level element is an object
/// representing one record. Records may have any subset of keys, so the
/// column set is the **union** of keys across all records in first-seen
/// order — this stabilises CSV output column layout when an input file is
/// missing the optional fields some records carry, and lets the same
/// template merge data from heterogeneous JSON exports.
///
/// Two passes over the file are required:
///   Pass 0 (`scanColNames`)       — discover the col_names union; no value
///                                    materialisation; row data is skipped.
///   Pass 1+ (`RecordReader.next`) — re-read from offset 0 and materialise
///                                    one record at a time into the
///                                    caller's row-scoped allocator.
///
/// RSS stays bounded to: one Scanner read buffer (READ_BUF_SIZE) + one
/// row's worth of value bytes. The full file is never held in memory at
/// once, which is what removed the legacy `MAX_FILE_SIZE_BYTES` limit on
/// JSON inputs.
///
/// Value conversions (parity with the prior whole-file `std.json.Value`
/// implementation):
///   .null           → ""
///   .true / .false  → "true" / "false"
///   .string         → owned dupe in row_alloc
///   integer-like #  → owned dupe of the number text (passes JSON literal
///                     verbatim — matches `allocPrint("{d}", .{i64})`)
///   non-integer #   → parsed to f64, re-formatted via `allocPrint("{d}",
///                     .{f64})` so "415.20" canonicalises to "415.2"
///   nested {} / []  → silently collapsed to "" (skipValue advances the
///                     scanner past the structure)

const std = @import("std");
const Scanner = std.json.Scanner;
const Reader = std.json.Reader;

/// Scanner read buffer. Sized to absorb a few records per refill without
/// being so large that a tiny input over-allocates. Records bigger than
/// this still work — the scanner refills mid-token via BufferUnderrun.
pub const READ_BUF_SIZE: usize = 32 * 1024;

/// Pass 0: walks the entire JSON array and collects the union of object
/// keys, in first-seen order, into `col_names`. Each name is duplicated
/// into `name_alloc` so it survives past Pass 0.
///
/// Values are skipped via `skipValue` — no materialisation, no per-value
/// allocation.
///
/// Errors:
///   error.JsonNotArray         — top-level is not an array
///   error.JsonNotObjectArray   — first array element is not an object
///   (any std.json.Reader error) — malformed JSON
pub fn scanColNames(
    name_alloc: std.mem.Allocator,
    io_reader: *std.Io.Reader,
    col_names: *std.array_list.Managed([]const u8),
) !void {
    // Scratch arena absorbs Scanner's nesting-tracker allocations + any
    // allocated_string tokens that exceed the scanner's read buffer for
    // long object keys. Discarded wholesale at function exit.
    var scratch = std.heap.ArenaAllocator.init(name_alloc);
    defer scratch.deinit();
    var reader = Reader.init(scratch.allocator(), io_reader);
    defer reader.deinit();

    var seen = std.StringHashMap(void).init(scratch.allocator());
    defer seen.deinit();

    // Expect top-level array_begin.
    switch (try reader.next()) {
        .array_begin => {},
        else => return error.JsonNotArray,
    }

    var saw_first_object = false;

    // Iterate array elements. For each object, read its keys (and skip
    // values) until object_end. Non-object elements are tolerated only as
    // the first error signal — anything else after a valid first object
    // is permitted (matches the legacy implementation's `if (item != .object) continue`).
    while (true) {
        const peek = try reader.peekNextTokenType();
        switch (peek) {
            .array_end => {
                _ = try reader.next(); // consume array_end
                return;
            },
            .object_begin => {
                _ = try reader.next(); // consume object_begin
                saw_first_object = true;
                try collectKeysUntilObjectEnd(&reader, scratch.allocator(), name_alloc, &seen, col_names);
            },
            else => {
                if (!saw_first_object) return error.JsonNotObjectArray;
                // Non-object element — skip and continue (matches legacy
                // tolerance for malformed array items after a valid first).
                try reader.skipValue();
            },
        }
    }
}

/// Walks object key/value pairs until matching `object_end`. New keys
/// (not in `seen`) are duplicated into `name_alloc` and appended to
/// `col_names`. Values are skipped.
fn collectKeysUntilObjectEnd(
    reader: *Reader,
    scratch_alloc: std.mem.Allocator,
    name_alloc: std.mem.Allocator,
    seen: *std.StringHashMap(void),
    col_names: *std.array_list.Managed([]const u8),
) !void {
    while (true) {
        const peek = try reader.peekNextTokenType();
        if (peek == .object_end) {
            _ = try reader.next();
            return;
        }
        // Inside an object the next token is always a string key.
        // `nextAlloc` with .alloc_if_needed gives us either a slice into
        // the scanner buffer (cheap) or an allocated_string (when the key
        // straddles buffer refills). Both need a name_alloc dupe so the
        // string survives the next refill.
        const tok = try reader.nextAlloc(scratch_alloc, .alloc_if_needed);
        const key_slice: []const u8 = switch (tok) {
            .string => |s| s,
            .allocated_string => |s| s,
            else => return error.JsonNotObjectArray,
        };
        if (!seen.contains(key_slice)) {
            const owned = try name_alloc.dupe(u8, key_slice);
            try seen.put(owned, {});
            try col_names.append(owned);
        }
        // Value: skip without materialising.
        try reader.skipValue();
    }
}

/// Streaming per-record reader. One instance covers Pass 1 (pre_pass)
/// **or** Pass 2 (main) — for both passes the caller seeks the file back
/// to byte 0 and instantiates a fresh `RecordReader`.
///
/// Each `next(row_alloc)` materialises one record into a `[][]const u8`
/// indexed by `col_names` order. Keys absent from this record produce "".
/// Returned slices live in `row_alloc`; passing a per-row arena that gets
/// reset between calls keeps total allocation bounded.
pub const RecordReader = struct {
    scratch: std.heap.ArenaAllocator,
    reader: Reader,
    col_index: *const std.StringHashMap(usize),
    col_count: usize,
    diagnostics: std.json.Scanner.Diagnostics,
    started: bool,
    /// Source-file byte offset of the opening `{` of the most recently
    /// emitted record. 0 before the first `next()` call. Used by btrace
    /// drill-down (CSV path emits the analogous offset via
    /// `csv.LineSlice.byte_offset`).
    last_record_offset: u64,

    /// Caller owns the `io_reader` lifetime. `parent_alloc` only backs the
    /// scratch arena used by the Scanner's nesting tracker — not row data.
    ///
    /// MUST be initialised in place via a pointer (`*RecordReader`) because
    /// the Reader's Scanner captures an Allocator handle into `self.scratch`;
    /// returning by value would memcpy the struct and dangle that pointer
    /// (segfault on the first Scanner allocation).
    pub fn init(
        self: *RecordReader,
        parent_alloc: std.mem.Allocator,
        io_reader: *std.Io.Reader,
        col_index: *const std.StringHashMap(usize),
    ) void {
        self.* = .{
            .scratch = std.heap.ArenaAllocator.init(parent_alloc),
            .reader = undefined,
            .col_index = col_index,
            .col_count = col_index.count(),
            .diagnostics = .{},
            .started = false,
            .last_record_offset = 0,
        };
        self.reader = Reader.init(self.scratch.allocator(), io_reader);
        self.reader.enableDiagnostics(&self.diagnostics);
    }

    pub fn deinit(self: *RecordReader) void {
        self.reader.deinit();
        self.scratch.deinit();
        self.* = undefined;
    }

    /// Source-file byte offset of the opening `{` of the most recently
    /// emitted record. 0 before the first `next()` call.
    pub fn recordStartOffset(self: *const RecordReader) u64 {
        return self.last_record_offset;
    }

    /// Pulls the next record from the array. Returns null when the array
    /// ends. Materialises field values into `row_alloc`; the returned
    /// slice and every string in it live in that allocator.
    pub fn next(
        self: *RecordReader,
        row_alloc: std.mem.Allocator,
    ) !?[][]const u8 {
        if (!self.started) {
            switch (try self.reader.next()) {
                .array_begin => {},
                else => return error.JsonNotArray,
            }
            self.started = true;
        }

        // Look for either `]` (done) or `{` (start of record).
        while (true) {
            const peek = try self.reader.peekNextTokenType();
            switch (peek) {
                .array_end => {
                    _ = try self.reader.next();
                    return null;
                },
                .object_begin => {
                    _ = try self.reader.next();
                    // Diagnostics tracks the scanner cursor, which is at
                    // the byte AFTER `{` once `next()` returns. Subtract
                    // 1 to point at the brace itself.
                    self.last_record_offset = self.diagnostics.getByteOffset() - 1;
                    return try self.readObjectFields(row_alloc);
                },
                else => {
                    // Non-object element in the array — skip and try again
                    // (legacy tolerance for malformed items mid-stream).
                    try self.reader.skipValue();
                },
            }
        }
    }

    fn readObjectFields(self: *RecordReader, row_alloc: std.mem.Allocator) ![][]const u8 {
        const row = try row_alloc.alloc([]const u8, self.col_count);
        for (row) |*cell| cell.* = "";

        while (true) {
            const peek = try self.reader.peekNextTokenType();
            if (peek == .object_end) {
                _ = try self.reader.next();
                return row;
            }
            // Key.
            const key_tok = try self.reader.nextAlloc(self.scratch.allocator(), .alloc_if_needed);
            const key_slice: []const u8 = switch (key_tok) {
                .string => |s| s,
                .allocated_string => |s| s,
                else => return error.JsonNotObjectArray,
            };

            // Locate column. Unknown keys: skip the value silently so the
            // record stays valid; caller's `checkUnknownFields` warning
            // path already covers the user-visible diagnostic.
            const col_idx_opt = self.col_index.get(key_slice);
            if (col_idx_opt == null) {
                try self.reader.skipValue();
                continue;
            }
            const col_idx = col_idx_opt.?;

            // Value.
            const value_peek = try self.reader.peekNextTokenType();
            switch (value_peek) {
                .null => {
                    _ = try self.reader.next();
                    // row[col_idx] already "".
                },
                .true => {
                    _ = try self.reader.next();
                    row[col_idx] = "true";
                },
                .false => {
                    _ = try self.reader.next();
                    row[col_idx] = "false";
                },
                .string => {
                    const tok = try self.reader.nextAlloc(self.scratch.allocator(), .alloc_if_needed);
                    const s: []const u8 = switch (tok) {
                        .string => |v| v,
                        .allocated_string => |v| v,
                        else => unreachable,
                    };
                    row[col_idx] = try row_alloc.dupe(u8, s);
                },
                .number => {
                    const tok = try self.reader.nextAlloc(self.scratch.allocator(), .alloc_if_needed);
                    const num_str: []const u8 = switch (tok) {
                        .number => |v| v,
                        .allocated_number => |v| v,
                        else => unreachable,
                    };
                    row[col_idx] = try numberStringToOutput(row_alloc, num_str);
                },
                .object_begin, .array_begin => {
                    try self.reader.skipValue();
                    // row[col_idx] already "".
                },
                .object_end, .array_end, .end_of_document => {
                    return error.JsonUnexpectedToken;
                },
            }
        }
    }
};

/// Number text → row-arena string. Matches the legacy `std.json.Value`
/// path's two-branch behaviour exactly:
///   * integer-like literals (no `.`, `e`, `E`, and not `-0`) pass
///     through verbatim — equivalent to `allocPrint("{d}", .{i64})`
///     which is a no-op on valid JSON integers.
///   * everything else parses as f64 and re-formats with `{d}` so
///     "415.20" canonicalises to "415.2" and "1e3" to "1000".
///
/// f64 precision loss for huge integers (> 2^53) matches the legacy
/// behaviour for the same input range — not introduced by this refactor.
fn numberStringToOutput(row_alloc: std.mem.Allocator, num_str: []const u8) ![]const u8 {
    if (std.json.isNumberFormattedLikeAnInteger(num_str)) {
        return try row_alloc.dupe(u8, num_str);
    }
    const f = try std.fmt.parseFloat(f64, num_str);
    return try std.fmt.allocPrint(row_alloc, "{d}", .{f});
}

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "scanColNames: union across heterogeneous records, first-seen order" {
    const src =
        \\[
        \\  {"a": 1, "b": 2},
        \\  {"b": 3, "c": 4},
        \\  {"a": 5, "d": 6}
        \\]
    ;
    var stream: std.Io.Reader = .fixed(src);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var col_names = std.array_list.Managed([]const u8).init(arena.allocator());
    try scanColNames(arena.allocator(), &stream, &col_names);
    try testing.expectEqual(@as(usize, 4), col_names.items.len);
    try testing.expectEqualStrings("a", col_names.items[0]);
    try testing.expectEqualStrings("b", col_names.items[1]);
    try testing.expectEqualStrings("c", col_names.items[2]);
    try testing.expectEqualStrings("d", col_names.items[3]);
}

test "RecordReader: streams records with type coercions" {
    const src =
        \\[
        \\  {"s": "hi", "i": 10, "f": 415.20, "b": true, "n": null},
        \\  {"s": "ho", "b": false, "i": 99}
        \\]
    ;
    var stream: std.Io.Reader = .fixed(src);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var col_names = std.array_list.Managed([]const u8).init(arena.allocator());
    try scanColNames(arena.allocator(), &stream, &col_names);

    var col_index = std.StringHashMap(usize).init(arena.allocator());
    for (col_names.items, 0..) |name, i| try col_index.put(name, i);

    var stream2: std.Io.Reader = .fixed(src);
    var rr: RecordReader = undefined;
    rr.init(arena.allocator(), &stream2, &col_index);
    defer rr.deinit();

    var row_arena = std.heap.ArenaAllocator.init(arena.allocator());
    defer row_arena.deinit();

    const r1 = (try rr.next(row_arena.allocator())).?;
    try testing.expectEqualStrings("hi", r1[col_index.get("s").?]);
    try testing.expectEqualStrings("10", r1[col_index.get("i").?]);
    try testing.expectEqualStrings("415.2", r1[col_index.get("f").?]);
    try testing.expectEqualStrings("true", r1[col_index.get("b").?]);
    try testing.expectEqualStrings("", r1[col_index.get("n").?]);

    _ = row_arena.reset(.retain_capacity);
    const r2 = (try rr.next(row_arena.allocator())).?;
    try testing.expectEqualStrings("ho", r2[col_index.get("s").?]);
    try testing.expectEqualStrings("99", r2[col_index.get("i").?]);
    try testing.expectEqualStrings("", r2[col_index.get("f").?]); // missing
    try testing.expectEqualStrings("false", r2[col_index.get("b").?]);
    try testing.expectEqualStrings("", r2[col_index.get("n").?]); // missing

    try testing.expectEqual(@as(?[][]const u8, null), try rr.next(row_arena.allocator()));
}

test "scanColNames: rejects non-array top level" {
    var stream: std.Io.Reader = .fixed("{}");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var col_names = std.array_list.Managed([]const u8).init(arena.allocator());
    try testing.expectError(error.JsonNotArray, scanColNames(arena.allocator(), &stream, &col_names));
}

test "scanColNames: rejects array of non-objects" {
    var stream: std.Io.Reader = .fixed("[1, 2, 3]");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var col_names = std.array_list.Managed([]const u8).init(arena.allocator());
    try testing.expectError(error.JsonNotObjectArray, scanColNames(arena.allocator(), &stream, &col_names));
}

test "RecordReader: nested object/array values collapse to empty" {
    const src =
        \\[{"a": {"nested": 1}, "b": [1, 2], "c": "ok"}]
    ;
    var stream: std.Io.Reader = .fixed(src);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var col_names = std.array_list.Managed([]const u8).init(arena.allocator());
    try scanColNames(arena.allocator(), &stream, &col_names);
    var col_index = std.StringHashMap(usize).init(arena.allocator());
    for (col_names.items, 0..) |name, i| try col_index.put(name, i);

    var stream2: std.Io.Reader = .fixed(src);
    var rr: RecordReader = undefined;
    rr.init(arena.allocator(), &stream2, &col_index);
    defer rr.deinit();
    var row_arena = std.heap.ArenaAllocator.init(arena.allocator());
    defer row_arena.deinit();
    const r = (try rr.next(row_arena.allocator())).?;
    try testing.expectEqualStrings("", r[col_index.get("a").?]);
    try testing.expectEqualStrings("", r[col_index.get("b").?]);
    try testing.expectEqualStrings("ok", r[col_index.get("c").?]);
}

test "RecordReader: unknown keys silently skipped (col_index miss)" {
    // col_index built from "a" only; record has "a" + "extra".
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var col_index = std.StringHashMap(usize).init(arena.allocator());
    try col_index.put("a", 0);

    const src =
        \\[{"a": 1, "extra": "ignored"}]
    ;
    var stream: std.Io.Reader = .fixed(src);
    var rr: RecordReader = undefined;
    rr.init(arena.allocator(), &stream, &col_index);
    defer rr.deinit();
    var row_arena = std.heap.ArenaAllocator.init(arena.allocator());
    defer row_arena.deinit();
    const r = (try rr.next(row_arena.allocator())).?;
    try testing.expectEqualStrings("1", r[0]);
}
