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
