const std = @import("std");

pub const Suggestion = struct {
    label: []const u8,
    insert: []const u8,
    detail: []const u8,
};

pub const builtins = [_]Suggestion{
    .{ .label = "IF", .insert = "IF(", .detail = "IF(cond, then, else)" },
    .{ .label = "ABS", .insert = "ABS(", .detail = "ABS(number)" },
    .{ .label = "DATE_CONVERT", .insert = "DATE_CONVERT(", .detail = "DATE_CONVERT(value, in_fmt, out_fmt)" },
    .{ .label = "PRICE_VALUE", .insert = "PRICE_VALUE(", .detail = "PRICE_VALUE(text) → numeric string" },
    .{ .label = "PRICE_CURRENCY", .insert = "PRICE_CURRENCY(", .detail = "PRICE_CURRENCY(text) → currency code" },
    .{ .label = "TICKER", .insert = "TICKER(", .detail = "TICKER(symbol) → mapped ticker" },
    .{ .label = "LOOKUP", .insert = "LOOKUP(", .detail = "LOOKUP(key, field) → pre_pass value" },
    .{ .label = "SPLIT_PART", .insert = "SPLIT_PART(", .detail = "SPLIT_PART(text, delim, index)" },
    .{ .label = "CONTAINS", .insert = "CONTAINS(", .detail = "CONTAINS(text, search) → bool" },
    .{ .label = "REPLACE", .insert = "REPLACE(", .detail = "REPLACE(text, old, new)" },
    .{ .label = "TRIM", .insert = "TRIM(", .detail = "TRIM(text)" },
    .{ .label = "ROUND", .insert = "ROUND(", .detail = "ROUND(number, decimals)" },
    .{ .label = "FLOOR", .insert = "FLOOR(", .detail = "FLOOR(number)" },
    .{ .label = "CEILING", .insert = "CEILING(", .detail = "CEILING(number)" },
    .{ .label = "NOW", .insert = "NOW(", .detail = "NOW(format)" },
    .{ .label = "RAND", .insert = "RAND(", .detail = "RAND()" },
    .{ .label = "COALESCE", .insert = "COALESCE(", .detail = "COALESCE(a, b, ...) → first non-empty" },
    .{ .label = "FIELDS", .insert = "FIELDS(", .detail = "FIELDS() → all column names" },
};

pub fn matchBuiltins(prefix: []const u8, out: []Suggestion) usize {
    var n: usize = 0;
    const upper = blk: {
        var buf: [64]u8 = undefined;
        const len = @min(buf.len, prefix.len);
        for (0..len) |i| buf[i] = std.ascii.toUpper(prefix[i]);
        break :blk buf[0..len];
    };
    for (&builtins) |*s| {
        if (n >= out.len) break;
        if (prefix.len == 0 or std.mem.startsWith(u8, s.label, upper)) {
            out[n] = s.*;
            n += 1;
        }
    }
    return n;
}
