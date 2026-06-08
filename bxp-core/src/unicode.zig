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

// ── unaccent (diacritic stripping) ─────────────────────────────────────────

/// Strip diacritics from Latin text: `café`→`cafe`, `ÀÉÎ`→`AEI`, `ß`→`ss`,
/// `ø`→`o`. Deliberately Latin-scope, matching Postgres's `unaccent`: a
/// non-Latin letter keeps its base form rather than being romanised
/// (`unaccent('Ά')`→`Α`, a Greek alpha, NOT `A`; CJK passes through unchanged) —
/// romanisation is lossy and almost never what the caller wants.
///
/// Method: recurse the canonical (NFD) decomposition, drop combining marks
/// (non-zero canonical combining class), keep base codepoints; plus a small
/// hand-list for the Latin letters that have no canonical decomposition
/// (`ß ø ł đ æ þ` …). UTF-8 in / out; invalid bytes pass through verbatim.
/// Caller owns the returned slice.
pub fn unaccentStr(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, s.len);

    var i: usize = 0;
    var enc_buf: [4]u8 = undefined;
    while (i < s.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try out.append(alloc, s[i]);
            i += 1;
            continue;
        };
        if (i + seq_len > s.len) {
            try out.append(alloc, s[i]);
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + seq_len]) catch {
            try out.append(alloc, s[i]);
            i += 1;
            continue;
        };
        try emitUnaccented(alloc, &out, cp, &enc_buf);
        i += seq_len;
    }
    return out.toOwnedSlice(alloc);
}

fn emitUnaccented(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    cp: u21,
    enc_buf: *[4]u8,
) error{OutOfMemory}!void {
    // Latin letters with no canonical decomposition → conventional ASCII spelling.
    if (latinHandlist(cp)) |repl| {
        try out.appendSlice(alloc, repl);
        return;
    }
    // Canonical decomposition (NFD): recurse so multi-step decompositions fully
    // unfold. Compatibility decompositions are intentionally skipped (we don't
    // want ligatures/① folded here — only diacritics removed).
    if (uucode.get(.decomposition_type, cp) == .canonical) {
        var dec_buf: [1]u21 = undefined;
        const seq = uucode.get(.decomposition_mapping, cp).with(&dec_buf, cp);
        for (seq) |dcp| try emitUnaccented(alloc, out, dcp, enc_buf);
        return;
    }
    // Atomic codepoint: drop it if it is a combining mark, else keep it verbatim
    // (an unaccented base letter — Latin → ASCII, non-Latin → its own script).
    if (uucode.get(.canonical_combining_class, cp) != 0) return;
    const n = std.unicode.utf8Encode(cp, enc_buf) catch return;
    try out.appendSlice(alloc, enc_buf[0..n]);
}

/// ASCII spellings for the common European Latin letters that carry no
/// canonical decomposition (so the NFD walk above leaves them untouched).
/// Mirrors the non-decomposing entries of CLDR `Latin-ASCII` / Postgres
/// `unaccent`. Returns null for everything else (let the NFD path handle it).
fn latinHandlist(cp: u21) ?[]const u8 {
    return switch (cp) {
        0x00DF => "ss", // ß
        0x1E9E => "SS", // ẞ
        0x00E6 => "ae", // æ
        0x00C6 => "AE", // Æ
        0x0153 => "oe", // œ
        0x0152 => "OE", // Œ
        0x00F8 => "o", // ø
        0x00D8 => "O", // Ø
        0x0142 => "l", // ł
        0x0141 => "L", // Ł
        0x0111 => "d", // đ
        0x0110 => "D", // Đ
        0x00F0 => "d", // ð
        0x00D0 => "D", // Ð
        0x00FE => "th", // þ
        0x00DE => "TH", // Þ
        0x0127 => "h", // ħ
        0x0126 => "H", // Ħ
        0x0131 => "i", // ı (dotless i)
        0x0130 => "I", // İ
        0x014B => "n", // ŋ
        0x014A => "N", // Ŋ
        else => null,
    };
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

fn expectUnaccent(s: []const u8, want: []const u8) !void {
    const got = try unaccentStr(testing.allocator, s);
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

test "unaccent: Latin diacritics stripped to base letter" {
    try expectUnaccent("café", "cafe");
    try expectUnaccent("naïve", "naive");
    try expectUnaccent("À É Î Ô Û", "A E I O U");
    try expectUnaccent("Žluťoučký kůň", "Zlutoucky kun");
    try expectUnaccent("Crème brûlée", "Creme brulee");
    // plain ASCII untouched
    try expectUnaccent("AAPL 123", "AAPL 123");
}

test "unaccent: non-decomposing Latin letters via hand-list" {
    try expectUnaccent("straße", "strasse");
    try expectUnaccent("Øresund", "Oresund");
    try expectUnaccent("Łódź", "Lodz");
    try expectUnaccent("æther œuvre", "aether oeuvre");
    try expectUnaccent("Þór", "THor");
}

test "unaccent: non-Latin keeps its base script (no romanisation)" {
    // Greek alpha-with-tonos → bare Greek alpha, NOT Latin "A"
    try expectUnaccent("Ά", "Α");
    // CJK / Arabic pass through unchanged
    try expectUnaccent("日本語", "日本語");
    try expectUnaccent("مرحبا", "مرحبا");
}

test "unaccent: empty + invalid UTF-8 passthrough" {
    try expectUnaccent("", "");
    try expectUnaccent("ab\xffcd", "ab\xffcd");
}
