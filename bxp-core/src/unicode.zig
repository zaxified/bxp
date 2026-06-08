//! In-house Unicode text operations for expr.zig builtins.
//!
//! Layer 1 of the Unicode subsystem: case mapping (UPPER / LOWER) and, later,
//! diacritic stripping (`unaccent`). The Unicode data tables come from the
//! `uucode` module (field-selected in bxp-core/build.zig); this file is the
//! thin UTF-8 plumbing on top.
//!
//! Everything is UTF-8 in / UTF-8 out. Because case mapping is a codepoint
//! walk (not a byte loop), the output byte length may differ from the input
//! (e.g. `ß` → `SS`), so callers must not pre-size to `s.len`.
//!
//! Data-lenient by design: a byte sequence that is not valid UTF-8 is emitted
//! verbatim, one byte at a time, never an error and never a crash. Broker
//! exports occasionally carry stray non-UTF-8 bytes (see the Layer 0
//! `csv_*_encoding` transcoding work); UPPER/LOWER must pass them through the
//! same way the previous ASCII byte loop did.

const std = @import("std");
const uucode = @import("uucode");

/// Full-Unicode upper-casing: `café` → `CAFÉ`, `ß` → `SS`, `я` → `Я`.
/// Unicameral scripts (CJK, Arabic, Hebrew) pass through unchanged.
/// Caller owns the returned slice.
pub fn toUpperStr(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    return mapCase(alloc, s, .uppercase_mapping);
}

/// Full-Unicode lower-casing: `CAFÉ` → `café`, `Я` → `я`.
/// Caller owns the returned slice.
pub fn toLowerStr(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    return mapCase(alloc, s, .lowercase_mapping);
}

fn mapCase(alloc: std.mem.Allocator, s: []const u8, comptime field: uucode.FieldEnum) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    // Case mapping is 1:1 in length for almost every codepoint; pre-size to the
    // input length and let the rare 1:N mapping (ß→SS) grow the buffer.
    try out.ensureTotalCapacity(alloc, s.len);

    var i: usize = 0;
    var cp_buf: [1]u21 = undefined;
    var enc_buf: [4]u8 = undefined;
    while (i < s.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try out.append(alloc, s[i]); // invalid leading byte → verbatim
            i += 1;
            continue;
        };
        if (i + seq_len > s.len) {
            try out.append(alloc, s[i]); // truncated trailing sequence → verbatim
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + seq_len]) catch {
            try out.append(alloc, s[i]); // malformed continuation → verbatim
            i += 1;
            continue;
        };
        const mapped = uucode.get(field, cp).with(&cp_buf, cp);
        for (mapped) |mcp| {
            const n = std.unicode.utf8Encode(mcp, &enc_buf) catch continue;
            try out.appendSlice(alloc, enc_buf[0..n]);
        }
        i += seq_len;
    }
    return out.toOwnedSlice(alloc);
}

// ── tests ────────────────────────────────────────────────────────────────
const testing = std.testing;

fn expectUpper(s: []const u8, want: []const u8) !void {
    const got = try toUpperStr(testing.allocator, s);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

fn expectLower(s: []const u8, want: []const u8) !void {
    const got = try toLowerStr(testing.allocator, s);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "ASCII case mapping" {
    try expectUpper("aapl", "AAPL");
    try expectLower("AAPL", "aapl");
    try expectUpper("Hello, World 2112!", "HELLO, WORLD 2112!");
    try expectLower("Hello, World 2112!", "hello, world 2112!");
}

test "Latin-1 diacritics keep their accents" {
    try expectUpper("café", "CAFÉ");
    try expectLower("CAFÉ", "café");
    try expectUpper("Œuvre", "ŒUVRE");
}

test "Swedish / German / Cyrillic / Greek" {
    try expectUpper("åäö", "ÅÄÖ");
    try expectLower("ÅÄÖ", "åäö");
    try expectUpper("naïve Ñ", "NAÏVE Ñ");
    try expectUpper("яблоко", "ЯБЛОКО");
    try expectLower("ЯБЛОКО", "яблоко");
}

test "German sharp s expands ß → SS on upper" {
    try expectUpper("straße", "STRASSE");
    // lower-casing SS does not round-trip back to ß (correct Unicode behaviour)
    try expectLower("STRASSE", "strasse");
}

test "unicameral scripts pass through unchanged" {
    try expectUpper("日本語", "日本語");
    try expectLower("日本語", "日本語");
    try expectUpper("مرحبا", "مرحبا");
}

test "empty string" {
    try expectUpper("", "");
    try expectLower("", "");
}

test "invalid UTF-8 bytes pass through verbatim" {
    // stray 0xFF (never a valid UTF-8 byte) surrounded by ASCII
    try expectUpper("ab\xffcd", "AB\xffCD");
    // lone continuation byte 0x80
    try expectLower("X\x80Y", "x\x80y");
    // truncated 2-byte lead at end of string
    try expectUpper("ok\xc3", "OK\xc3");
}
