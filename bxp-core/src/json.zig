/// JSON array-of-objects input reader for bxp-cli.
///
/// Reads a JSON file containing an array of objects and converts each object
/// to a row of strings matching the union of all keys found across all objects.
/// Keys are ordered by first appearance.  Missing keys in a record become "".
/// Null values become empty strings; numbers are formatted as decimal strings.
/// All allocated memory is owned by the caller-provided allocator (use an arena).

const std = @import("std");

/// Reads a JSON array-of-objects and fills col_names and all_rows.
///
/// col_names: filled with the union of all field names across all records,
///            in first-seen order.
/// all_rows:  filled with one [][]const u8 per object; values in col_names order.
///            Keys absent from a given record produce "".
///
/// Value conversions:
///   .null          → ""
///   .string        → as-is (slice into parsed JSON — valid while alloc lives)
///   .integer       → decimal string (allocated)
///   .float         → decimal string (allocated)
///   .number_string → as-is (unparsed number string)
///   .bool          → "true" or "false"
///   .array/.object → "" (nested structures not supported)
///
/// All strings are allocated from alloc.  Intended for use with a file-scoped
/// arena so that all output remains valid until the arena is freed.
pub fn readJsonRecords(
    alloc: std.mem.Allocator,
    content: []const u8,
    col_names: *std.array_list.Managed([]const u8),
    all_rows: *std.array_list.Managed([][]const u8),
) !void {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, content, .{});
    if (value != .array) return error.JsonNotArray;

    const items = value.array.items;
    if (items.len == 0) return;
    if (items[0] != .object) return error.JsonNotObjectArray;

    // Collect the union of all keys across all records (first-seen order).
    // Use a StringHashMap as a seen-set for O(1) duplicate detection.
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();
    for (items) |item| {
        if (item != .object) continue;
        var it = item.object.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            if (!seen.contains(key)) {
                const owned = try alloc.dupe(u8, key);
                try seen.put(owned, {});
                try col_names.append(owned);
            }
        }
    }

    const n_cols = col_names.items.len;

    // Convert each object to a row of strings; missing keys produce "".
    for (items) |item| {
        if (item != .object) continue;
        const row = try alloc.alloc([]const u8, n_cols);
        for (col_names.items, 0..) |name, ci| {
            const v = item.object.get(name) orelse .null;
            row[ci] = try jsonValueToString(alloc, v);
        }
        try all_rows.append(row);
    }
}

/// Converts a std.json.Value to a string.
/// Integer and float values are formatted via allocPrint (caller owns the result).
/// String values return a slice into the original parsed JSON (no allocation).
/// Null, bool, array, and object collapse to "" or "true"/"false".
fn jsonValueToString(alloc: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .null => "",
        .bool => |b| if (b) "true" else "false",
        .string => |s| s,
        .integer => |i| try std.fmt.allocPrint(alloc, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(alloc, "{d}", .{f}),
        .number_string => |s| s,
        .array, .object => "",
    };
}

// ────────────────────────────────────────────────────────────────────────────
// NDJSON writer — fast-path for bxp-cli `--trace` event emission.
//
// Wraps a custom mini JSON writer that bypasses `std.json.Stringify`'s
// per-byte escape scan when callers can statically prove a string contains
// no JSON-significant bytes (`"`, `\`, or control char < 0x20). Callers
// signal this by passing values wrapped in `Safe { bytes: ... }`; raw
// `[]const u8` values still travel safely through an ad-hoc classify+escape
// fallback inside the writer.
//
// JSON output is semantically equivalent to `std.json.Stringify` (parses
// back to the same `std.json.Value` tree) but is NOT guaranteed to be
// byte-identical: no whitespace, no indent, single shape of escape
// sequences (`\"`, `\\`, `\n`, `\r`, `\t`, `\b`, `\f`, `\uXXXX` for
// other control bytes).
// ────────────────────────────────────────────────────────────────────────────

/// String marked as containing no JSON-significant bytes — emitted with
/// `"` + bytes + `"` and no escape scan. Caller asserts the contract.
/// Use `wrapChecked` for defensive wrapping or `classify` to test first.
pub const Safe = struct { bytes: []const u8 };

/// Returns true when `s` contains no byte that requires JSON escaping
/// (control chars < 0x20, `"`, or `\`). UTF-8 high bytes are safe — the
/// JSON spec allows raw UTF-8 inside string literals.
pub inline fn classify(s: []const u8) bool {
    for (s) |b| if (b < 0x20 or b == '"' or b == '\\') return false;
    return true;
}

/// Wraps a string as `Safe` without checking — caller must guarantee.
/// Use when the value comes from a known-safe source (config var names,
/// numeric output, ISO dates, ticker keys).
pub inline fn wrap(s: []const u8) Safe {
    return .{ .bytes = s };
}

/// Wraps a string as `Safe` only when `classify(s)` returns true.
/// Returns `null` otherwise, so callers can fall back to passing the raw
/// `[]const u8` (which the writer will then classify + escape ad-hoc).
pub inline fn wrapChecked(s: []const u8) ?Safe {
    return if (classify(s)) .{ .bytes = s } else null;
}

/// Emits one NDJSON event line to `w`: `{"t":"<t_name>",<args fields>}\n`.
/// Field types supported (compile-time dispatched in `writeValue`):
///   `Safe`             — emitted as `"<bytes>"` (no escape scan)
///   `[]const u8`       — classified ad-hoc; safe path skips escape, else escape
///   integer / float    — `std.fmt`'s `{d}`
///   `bool`             — `true` / `false`
///   `?T`               — `null` or recurse on payload
///   `[]const T`        — array, recurse on each element
///   struct with `.iterator()` returning `key_ptr`/`value_ptr` — object, recurse
pub fn writeEvent(w: *std.Io.Writer, comptime t_name: []const u8, args: anytype) !void {
    try w.writeAll("{\"t\":\"" ++ t_name ++ "\"");
    inline for (std.meta.fields(@TypeOf(args))) |f| {
        try w.writeAll(",\"" ++ f.name ++ "\":");
        try writeValue(w, @field(args, f.name));
    }
    try w.writeAll("}\n");
}

fn writeValue(w: *std.Io.Writer, v: anytype) !void {
    const T = @TypeOf(v);
    if (T == Safe) {
        try w.writeByte('"');
        try w.writeAll(v.bytes);
        try w.writeByte('"');
        return;
    }
    const info = @typeInfo(T);
    switch (info) {
        .int, .comptime_int => try w.print("{d}", .{v}),
        .float, .comptime_float => try w.print("{d}", .{v}),
        .bool => try w.writeAll(if (v) "true" else "false"),
        .optional => {
            if (v) |inner| {
                try writeValue(w, inner);
            } else {
                try w.writeAll("null");
            }
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                // []const u8 — classify ad-hoc, then safe-fast or escape-fallback.
                if (classify(v)) {
                    try w.writeByte('"');
                    try w.writeAll(v);
                    try w.writeByte('"');
                } else {
                    try writeJsonString(w, v);
                }
            } else if (p.size == .slice) {
                try w.writeByte('[');
                for (v, 0..) |item, i| {
                    if (i > 0) try w.writeByte(',');
                    try writeValue(w, item);
                }
                try w.writeByte(']');
            } else if (p.size == .one) {
                // Single-item pointer — most commonly `*const [N]T` or
                // `*const [N:S]T` (string literals are `*const [N:0]u8`).
                // Coerce to slice and recurse so the .pointer .slice arm
                // handles the byte-by-byte work.
                const child_info = @typeInfo(p.child);
                if (child_info == .array) {
                    const slice: []const child_info.array.child = v;
                    try writeValue(w, slice);
                } else {
                    @compileError("writeValue: unsupported pointer type " ++ @typeName(T));
                }
            } else {
                @compileError("writeValue: unsupported pointer type " ++ @typeName(T));
            }
        },
        .array => |a| {
            if (a.child == u8) {
                // Fixed array of bytes (rare — most byte arrays arrive as pointers).
                const slice: []const u8 = &v;
                if (classify(slice)) {
                    try w.writeByte('"');
                    try w.writeAll(slice);
                    try w.writeByte('"');
                } else {
                    try writeJsonString(w, slice);
                }
            } else {
                try w.writeByte('[');
                for (v, 0..) |item, i| {
                    if (i > 0) try w.writeByte(',');
                    try writeValue(w, item);
                }
                try w.writeByte(']');
            }
        },
        .@"struct" => |s| {
            // Two cases:
            //   1. StringHashMap / StringArrayHashMap — expose `.iterator()`
            //      returning entries with `key_ptr` / `value_ptr`. Emit as
            //      a runtime-keyed JSON object.
            //   2. Generic anonymous struct (e.g. nested `.stats = .{...}` in
            //      file_end payload) — emit as a JSON object with field names
            //      as keys, comptime-iterated.
            if (@hasDecl(T, "iterator")) {
                var it = v.iterator();
                try w.writeByte('{');
                var first = true;
                while (it.next()) |e| {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try writeValue(w, e.key_ptr.*);
                    try w.writeByte(':');
                    try writeValue(w, e.value_ptr.*);
                }
                try w.writeByte('}');
            } else {
                try w.writeByte('{');
                inline for (s.fields, 0..) |f, i| {
                    if (i > 0) try w.writeByte(',');
                    try w.writeAll("\"" ++ f.name ++ "\":");
                    try writeValue(w, @field(v, f.name));
                }
                try w.writeByte('}');
            }
        },
        else => @compileError("writeValue: unsupported type " ++ @typeName(T)),
    }
}

/// Emits `s` as a quoted JSON string with the minimal-shape escape set
/// (`\"`, `\\`, `\n`, `\r`, `\t`, `\b`, `\f`, `\uXXXX` for other < 0x20).
/// Caller-side classify already proved at least one byte needs escaping;
/// this function rescans to find boundaries and emit slices in chunks.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    var start: usize = 0;
    for (s, 0..) |b, i| {
        if (b < 0x20 or b == '"' or b == '\\') {
            if (start < i) try w.writeAll(s[start..i]);
            switch (b) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                0x08 => try w.writeAll("\\b"),
                0x0C => try w.writeAll("\\f"),
                else => try w.print("\\u{x:0>4}", .{b}),
            }
            start = i + 1;
        }
    }
    if (start < s.len) try w.writeAll(s[start..]);
    try w.writeByte('"');
}

// ────────────────────────────────────────────────────────────────────────────
// Inline tests for the writer.
//
// Strategy: every test emits one event, parses the buffer back via
// `std.json.parseFromSlice(std.json.Value, ...)`, and asserts the parsed
// tree matches expectations. This validates semantic correctness (the
// only contract callers care about) without locking in byte-exact output.
// ────────────────────────────────────────────────────────────────────────────

fn writeEventToBuf(buf: []u8, comptime t_name: []const u8, args: anytype) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try writeEvent(&w, t_name, args);
    return w.buffered();
}

test "classify: boundary bytes" {
    try std.testing.expect(classify(""));
    try std.testing.expect(classify("abc123"));
    try std.testing.expect(classify("česká koruna"));
    try std.testing.expect(classify(" !#$%&'()*+,-./:;<=>?@[]^_`{|}~"));
    try std.testing.expect(!classify("\""));
    try std.testing.expect(!classify("\\"));
    try std.testing.expect(!classify("\n"));
    try std.testing.expect(!classify("\t"));
    try std.testing.expect(!classify(&.{0x1F}));
    try std.testing.expect(classify(&.{0x20}));
    try std.testing.expect(classify(&.{0x7F}));
}

test "wrapChecked: returns null on unsafe" {
    try std.testing.expect(wrapChecked("safe") != null);
    try std.testing.expect(wrapChecked("with\"quote") == null);
    try std.testing.expect(wrapChecked("") != null);
}

test "writeEvent: empty args" {
    var buf: [256]u8 = undefined;
    const out = try writeEventToBuf(&buf, "done", .{});
    try std.testing.expectEqualStrings("{\"t\":\"done\"}\n", out);
}

test "writeEvent: Safe wrap roundtrip" {
    var buf: [256]u8 = undefined;
    const out = try writeEventToBuf(&buf, "var_eval", .{
        .name = wrap("$date"),
        .value = wrap("2026-05-18"),
    });
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("var_eval", parsed.value.object.get("t").?.string);
    try std.testing.expectEqualStrings("$date", parsed.value.object.get("name").?.string);
    try std.testing.expectEqualStrings("2026-05-18", parsed.value.object.get("value").?.string);
}

test "writeEvent: []const u8 safe ad-hoc" {
    var buf: [256]u8 = undefined;
    const value: []const u8 = "alphanumeric_123";
    const out = try writeEventToBuf(&buf, "var_eval", .{ .value = value });
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("alphanumeric_123", parsed.value.object.get("value").?.string);
}

test "writeEvent: []const u8 unsafe escape" {
    var buf: [256]u8 = undefined;
    const value: []const u8 = "with\"quote\\back\nnewline\ttab\x01ctrl";
    const out = try writeEventToBuf(&buf, "var_eval", .{ .value = value });
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(value, parsed.value.object.get("value").?.string);
}

test "writeEvent: UTF-8 multibyte safe" {
    var buf: [256]u8 = undefined;
    const value: []const u8 = "česká koruna ✓";
    const out = try writeEventToBuf(&buf, "var_eval", .{ .value = value });
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(value, parsed.value.object.get("value").?.string);
}

test "writeEvent: integer / float / bool fields" {
    var buf: [256]u8 = undefined;
    const out = try writeEventToBuf(&buf, "stats", .{
        .rows = @as(u32, 1234),
        .ratio = @as(f64, 0.5),
        .ok = true,
    });
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1234), parsed.value.object.get("rows").?.integer);
    try std.testing.expectEqual(@as(f64, 0.5), parsed.value.object.get("ratio").?.float);
    try std.testing.expectEqual(true, parsed.value.object.get("ok").?.bool);
}

test "writeEvent: optional null and present" {
    var buf: [256]u8 = undefined;
    const present: ?[]const u8 = "hi";
    const absent: ?[]const u8 = null;
    const out = try writeEventToBuf(&buf, "rule_no_match", .{
        .rule_index = @as(u32, 2),
        .err = absent,
        .detail = present,
    });
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(std.json.Value{ .null = {} }, parsed.value.object.get("err").?);
    try std.testing.expectEqualStrings("hi", parsed.value.object.get("detail").?.string);
}

test "writeEvent: []Safe array (row_start.fields shape)" {
    var buf: [256]u8 = undefined;
    const fields = [_]Safe{ wrap("col1"), wrap("col2"), wrap("col3") };
    const out = try writeEventToBuf(&buf, "row_start", .{
        .file_row = @as(u32, 7),
        .fields = @as([]const Safe, &fields),
    });
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("fields").?.array;
    try std.testing.expectEqual(@as(usize, 3), arr.items.len);
    try std.testing.expectEqualStrings("col1", arr.items[0].string);
    try std.testing.expectEqualStrings("col2", arr.items[1].string);
    try std.testing.expectEqualStrings("col3", arr.items[2].string);
}

test "writeEvent: []const u8 array (mixed safe/unsafe)" {
    var buf: [256]u8 = undefined;
    const a: []const u8 = "safe";
    const b: []const u8 = "with\"quote";
    const items = [_][]const u8{ a, b };
    const out = try writeEventToBuf(&buf, "row_output", .{
        .values = @as([]const []const u8, &items),
    });
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("values").?.array;
    try std.testing.expectEqualStrings("safe", arr.items[0].string);
    try std.testing.expectEqualStrings("with\"quote", arr.items[1].string);
}

test "writeEvent: nested map (rule_match rows shape)" {
    var buf: [512]u8 = undefined;
    var map = std.StringArrayHashMap([]const u8).init(std.testing.allocator);
    defer map.deinit();
    try map.put("$action", "BUY");
    try map.put("$ticker", "AAPL");
    const out = try writeEventToBuf(&buf, "rule_match", .{
        .rule_index = @as(u32, 0),
        .row = map,
    });
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    const row = parsed.value.object.get("row").?.object;
    try std.testing.expectEqualStrings("BUY", row.get("$action").?.string);
    try std.testing.expectEqualStrings("AAPL", row.get("$ticker").?.string);
}

test "writeEvent: array of nested maps" {
    var buf: [1024]u8 = undefined;
    var m1 = std.StringArrayHashMap([]const u8).init(std.testing.allocator);
    defer m1.deinit();
    try m1.put("$action", "FEE");
    var m2 = std.StringArrayHashMap([]const u8).init(std.testing.allocator);
    defer m2.deinit();
    try m2.put("$action", "BUY");
    const rows = [_]std.StringArrayHashMap([]const u8){ m1, m2 };
    const out = try writeEventToBuf(&buf, "rule_match", .{
        .rows = @as([]const std.StringArrayHashMap([]const u8), &rows),
    });
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("rows").?.array;
    try std.testing.expectEqual(@as(usize, 2), arr.items.len);
    try std.testing.expectEqualStrings("FEE", arr.items[0].object.get("$action").?.string);
    try std.testing.expectEqualStrings("BUY", arr.items[1].object.get("$action").?.string);
}

test "writeEvent: single quote byte" {
    var buf: [128]u8 = undefined;
    const value: []const u8 = "\"";
    const out = try writeEventToBuf(&buf, "x", .{ .v = value });
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("\"", parsed.value.object.get("v").?.string);
}

test "writeEvent: empty string" {
    var buf: [128]u8 = undefined;
    const value: []const u8 = "";
    const out = try writeEventToBuf(&buf, "x", .{ .v = value });
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("", parsed.value.object.get("v").?.string);
}
