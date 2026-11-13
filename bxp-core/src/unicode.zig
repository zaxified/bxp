//! UTF-8 text operations behind expr.zig's UPPER / LOWER / UNACCENT / PROPER.
//!
//! The algorithms and the Unicode data are the zig-libs `unitext` module (full
//! case mapping with SpecialCasing and Final_Sigma, NFD/NFC, the ICU-style
//! unaccent); this file only fixes bxp's policy for calling it, so the three
//! builtins cannot drift apart on it:
//!
//! - Data-lenient: a byte sequence that is not well-formed UTF-8 is copied
//!   through unchanged (`.pass_through`), never an error and never a crash.
//!   Broker exports read without `csv_input_encoding` carry such bytes.
//! - The output length may differ from the input (`ß` → `SS`), so callers must
//!   not pre-size to `s.len`.
//! - `error.TooLarge` (unitext's cap on what one input may allocate, 1 GiB by
//!   default) is reported as `error.OutOfMemory`: no field gets near it, and
//!   the callers already treat OOM as non-recoverable.

const std = @import("std");
const unitext = @import("unitext");

const opts: unitext.Options = .{ .invalid_utf8 = .pass_through };

/// Full-Unicode upper-casing: `café` → `CAFÉ`, `ß` → `SS`, `я` → `Я`.
/// Unicameral scripts (CJK, Arabic, Hebrew) pass through unchanged.
/// Caller owns the returned slice.
pub fn toUpperStr(alloc: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    return unitext.upper(alloc, s, opts) catch |err| mapErr(err);
}

/// Full-Unicode lower-casing: `CAFÉ` → `café`, `Я` → `я`, a word-final
/// capital sigma → `ς`. Caller owns the returned slice.
pub fn toLowerStr(alloc: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    return unitext.lower(alloc, s, opts) catch |err| mapErr(err);
}

/// Strip diacritics: `café` → `cafe`, `Łódź` → `Lodz`, `straße` → `strasse`,
/// `æther` → `aether`. A non-Latin letter keeps its own script (`Ά` → `Α`, a
/// Greek alpha, not `A`) — romanisation is lossy and almost never wanted.
/// Compatibility forms (`①`, full-width letters) are not folded.
/// Caller owns the returned slice.
pub fn unaccentStr(alloc: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    const out = unitext.unaccent(alloc, s, .{ .invalid_utf8 = .pass_through }) catch |err| return mapErr(err);
    return foldEng(alloc, out);
}

/// zig-libs request: unitext — `unaccent` leaves ŋ / Ŋ (U+014B / U+014A, eng)
/// unchanged, where ICU Latin-ASCII and PostgreSQL `unaccent` give n / N.
/// Both encode as two bytes (C5 8B / C5 8A) and fold to one, so this rewrites
/// `out` in place and shrinks the allocation. Delete once upstream folds them.
fn foldEng(alloc: std.mem.Allocator, out: []u8) error{OutOfMemory}![]u8 {
    if (std.mem.indexOfScalar(u8, out, 0xC5) == null) return out;
    var r: usize = 0;
    var w: usize = 0;
    while (r < out.len) {
        if (out[r] == 0xC5 and r + 1 < out.len and (out[r + 1] == 0x8B or out[r + 1] == 0x8A)) {
            out[w] = if (out[r + 1] == 0x8B) 'n' else 'N';
            r += 2;
        } else {
            out[w] = out[r];
            r += 1;
        }
        w += 1;
    }
    if (w == out.len) return out;
    return alloc.realloc(out, w);
}

fn mapErr(err: unitext.Error) error{OutOfMemory} {
    return switch (err) {
        error.OutOfMemory, error.TooLarge => error.OutOfMemory,
        error.InvalidUtf8 => unreachable, // `.pass_through` never reports it
    };
}

// ── tests ────────────────────────────────────────────────────────────────
// bxp's contract on top of unitext (which carries the conformance suites):
// the pass-through policy and the examples the builtin docs promise.
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
    try expectUnaccent("ab\xffcd é", "ab\xffcd e");
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

test "unaccent: non-decomposing Latin letters" {
    try expectUnaccent("straße", "strasse");
    try expectUnaccent("Øresund", "Oresund");
    try expectUnaccent("Łódź", "Lodz");
    try expectUnaccent("æther œuvre", "aether oeuvre");
    try expectUnaccent("Ŋaŋ ŋ", "Nan n");
}

test "unaccent: non-Latin keeps its base script (no romanisation)" {
    // Greek alpha-with-tonos → bare Greek alpha, NOT Latin "A"
    try expectUnaccent("Ά", "Α");
    // CJK / Arabic / Hangul pass through unchanged
    try expectUnaccent("日本語", "日本語");
    try expectUnaccent("مرحبا", "مرحبا");
    try expectUnaccent("한국어", "한국어");
}

test "unaccent: empty" {
    try expectUnaccent("", "");
}
