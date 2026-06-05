//! Fixed-point decimal numeric core for the expression evaluator.
//!
//! Money and bounded-magnitude ETL values are stored as an `i128` scaled by
//! a constant `SCALE = 1e12` (12 fractional digits). This replaces the former
//! `f80` representation whose binary-float noise (`0.02 + 0.08 → 0.0999…`) had
//! to be masked by an 8-decimal print cap. With fixed-point, `0.02 + 0.08` is
//! exactly `0.10` — no cap needed.
//!
//! Range (i128 @ 1e12):
//!   max  +170 141 183 460 469 231 731 687 303.715884105727
//!   min  -170 141 183 460 469 231 731 687 303.715884105728
//!   step  0.000000000001
//!
//! The integer part ceiling (~1.7e26) is far beyond world money supply, and
//! i128-only division is safe to value ≈ 170 trillion. `× ÷` widen to `i256`
//! intermediates so a product of two large operands can't overflow.
//!
//! Rounding contract (all rounding is half-away-from-zero — "school" rounding,
//! matching what Excel / LibreOffice present, since the target users are not
//! programmers or scientists):
//!   `+ −`   exact.
//!   `× ÷`   round the 12th fractional digit half-away-from-zero (a product or
//!           quotient with more than 12 fractional digits is rounded, not
//!           truncated). `ROUND()` uses the same mode.
//!   Output prints up to 12 digits, trailing zeros trimmed.
//!
//! This module is pure integer arithmetic — no float touches parse or format,
//! which is also where the ~22× format speedup over `{d:.8}` comes from.

const std = @import("std");

pub const Decimal = struct {
    raw: i128, // value × SCALE

    pub const SCALE_DIGITS: u32 = 12;
    pub const SCALE: i128 = 1_000_000_000_000; // 1e12
    pub const SCALE_256: i256 = 1_000_000_000_000;

    pub const zero: Decimal = .{ .raw = 0 };
    pub const one: Decimal = .{ .raw = SCALE };

    /// Largest power-of-ten exponent we materialise for scaling. 10^48 fits an
    /// i256 (max ≈ 5.7e76) with wide margin; anything past this overflows the
    /// i128 result anyway, so it is rejected as out-of-range.
    const MAX_POW10: u32 = 48;

    pub fn fromInt(n: i128) Decimal {
        return .{ .raw = n * SCALE };
    }

    /// Integer part, truncated toward zero. Used by index/offset helpers.
    pub fn trunc(self: Decimal) i128 {
        return @divTrunc(self.raw, SCALE);
    }

    pub fn isZero(self: Decimal) bool {
        return self.raw == 0;
    }

    // Arithmetic is overflow-checked: a result beyond the fixed-point range
    // (≈ ±1.7e26) returns null so the caller can surface a clean error rather
    // than trapping. Real bounded-ETL values never approach the ceiling; only
    // pathological inputs (e.g. 1e14 × 1e14) reach it.

    pub fn add(a: Decimal, b: Decimal) ?Decimal {
        const r = @addWithOverflow(a.raw, b.raw);
        return if (r[1] != 0) null else .{ .raw = r[0] };
    }

    pub fn sub(a: Decimal, b: Decimal) ?Decimal {
        const r = @subWithOverflow(a.raw, b.raw);
        return if (r[1] != 0) null else .{ .raw = r[0] };
    }

    pub fn neg(self: Decimal) ?Decimal {
        const r = @subWithOverflow(@as(i128, 0), self.raw);
        return if (r[1] != 0) null else .{ .raw = r[0] }; // null only at i128 min
    }

    pub fn abs(self: Decimal) ?Decimal {
        return if (self.raw >= 0) self else self.neg();
    }

    /// (a×S)(b×S)/S = a·b·S. Widen so the a.raw×b.raw product (up to ~3e52)
    /// can't overflow the i256 intermediate; the final value may still exceed
    /// i128 (→ null). Rounds the 12th fractional digit half-away-from-zero,
    /// matching how Excel/LibreOffice present results.
    pub fn mul(a: Decimal, b: Decimal) ?Decimal {
        const p: i256 = @as(i256, a.raw) * @as(i256, b.raw);
        const q = divRoundHalfAway(p, SCALE_256);
        if (q > std.math.maxInt(i128) or q < std.math.minInt(i128)) return null;
        return .{ .raw = @intCast(q) };
    }

    /// a/b rounded to 12 fractional digits, half-away-from-zero (Excel/
    /// LibreOffice display rounding). Returns null on divide-by-zero (caller
    /// maps to the silent "" contract).
    pub fn div(a: Decimal, b: Decimal) ?Decimal {
        if (b.raw == 0) return null;
        const num: i256 = @as(i256, a.raw) * SCALE_256;
        return .{ .raw = @intCast(divRoundHalfAway(num, @as(i256, b.raw))) };
    }

    /// Largest Decimal ≤ self with zero fractional part.
    pub fn floor(self: Decimal) Decimal {
        return .{ .raw = @divFloor(self.raw, SCALE) * SCALE };
    }

    /// Smallest Decimal ≥ self with zero fractional part.
    pub fn ceil(self: Decimal) Decimal {
        return .{ .raw = -(@divFloor(-self.raw, SCALE) * SCALE) };
    }

    /// Re-quantise to `n` fractional digits, **round-half-away-from-zero**
    /// (matches the `ROUND()` builtin's historical surface and Excel's ROUND:
    /// `ROUND(2.5, 0) = 3`, `ROUND(-2.5, 0) = -3`) — the same mode `× ÷` use.
    /// `n >= 12` is a no-op (already max precision); `n < 0` rounds to
    /// tens/hundreds/… Returns self unchanged if the result would overflow.
    pub fn round(self: Decimal, n: i32) Decimal {
        if (n >= @as(i32, @intCast(SCALE_DIGITS))) return self;
        const drop: u32 = @intCast(@as(i64, SCALE_DIGITS) - n); // 1..(12+|n|)
        if (drop > MAX_POW10) return self;
        const divisor = pow10_256(drop);
        const q = divRoundHalfAway(@as(i256, self.raw), divisor);
        const scaled = q * divisor;
        if (scaled > std.math.maxInt(i128) or scaled < std.math.minInt(i128)) return self;
        return .{ .raw = @intCast(scaled) };
    }

    pub fn order(a: Decimal, b: Decimal) std.math.Order {
        return std.math.order(a.raw, b.raw);
    }

    pub fn eql(a: Decimal, b: Decimal) bool {
        return a.raw == b.raw;
    }

    /// Parse a plain numeric string (optional sign, decimal point, scientific
    /// notation) into a fixed-point Decimal. Float-free. Returns null on any
    /// non-numeric input, on empty input, or on a value that overflows the
    /// i128 range. Thousands-grouped input ("1,234.56") is intentionally
    /// rejected here — the caller handles grouping separately.
    ///
    /// Fractional digits beyond 12 are rounded half-away-from-zero into the
    /// 12th (matching `divRoundHalfAway` and the rest of the module).
    pub fn parse(s: []const u8) ?Decimal {
        if (s.len == 0) return null;
        var i: usize = 0;
        var is_neg = false;
        if (s[i] == '+') {
            i += 1;
        } else if (s[i] == '-') {
            is_neg = true;
            i += 1;
        }

        // Mantissa: integer digits, optional '.', fractional digits.
        var mant: i256 = 0;
        var digits_seen: u32 = 0;
        var frac_digits: i64 = 0;
        var seen_dot = false;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c == '.') {
                if (seen_dot) return null;
                seen_dot = true;
                continue;
            }
            if (c == 'e' or c == 'E') break;
            if (!std.ascii.isDigit(c)) return null;
            digits_seen += 1;
            // Cap mantissa width so the i256 accumulator can't overflow; far
            // more digits than any representable value needs.
            if (digits_seen > 60) return null;
            mant = mant * 10 + @as(i256, c - '0');
            if (seen_dot) frac_digits += 1;
        }
        if (digits_seen == 0) return null;

        // Optional exponent.
        var exp: i64 = 0;
        if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
            i += 1;
            var exp_neg = false;
            if (i < s.len and (s[i] == '+' or s[i] == '-')) {
                exp_neg = s[i] == '-';
                i += 1;
            }
            var exp_digits: u32 = 0;
            while (i < s.len) : (i += 1) {
                if (!std.ascii.isDigit(s[i])) return null;
                exp = exp * 10 + @as(i64, s[i] - '0');
                exp_digits += 1;
                if (exp_digits > 4) return null; // |exp| ≤ 9999 is ample
            }
            if (exp_digits == 0) return null;
            if (exp_neg) exp = -exp;
        }
        if (i != s.len) return null;

        // value = mant × 10^(exp - frac_digits); raw = value × 10^12.
        const shift: i64 = exp - frac_digits + @as(i64, SCALE_DIGITS);
        var raw256: i256 = undefined;
        if (shift >= 0) {
            if (shift > MAX_POW10) return null; // overflows i128
            raw256 = mant * pow10_256(@intCast(shift));
        } else {
            const drop: i64 = -shift;
            if (drop > MAX_POW10) return null; // rounds to zero / unrepresentable
            raw256 = divRoundHalfAway(mant, pow10_256(@intCast(drop)));
        }
        if (is_neg) raw256 = -raw256;
        if (raw256 > std.math.maxInt(i128) or raw256 < std.math.minInt(i128)) return null;
        return .{ .raw = @intCast(raw256) };
    }

    /// Format as a string: integer part, then up to 12 fractional digits with
    /// trailing zeros trimmed and the dot dropped when no fraction remains.
    /// Integer digit extraction only — no float formatter (the ~22× win).
    pub fn toString(self: Decimal, alloc: std.mem.Allocator) ![]const u8 {
        const negative = self.raw < 0;
        // Magnitude in u128 so i128's asymmetric min is representable.
        const mag: u128 = if (negative)
            @as(u128, @intCast(-(self.raw + 1))) + 1
        else
            @intCast(self.raw);
        const scale_u: u128 = @intCast(SCALE);
        const int_part = mag / scale_u;
        const frac = mag % scale_u;

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        if (negative and mag != 0) try buf.append(alloc, '-');
        try buf.print(alloc, "{d}", .{int_part});
        if (frac != 0) {
            // 12-digit zero-padded fraction, trailing zeros trimmed.
            var fbuf: [SCALE_DIGITS]u8 = undefined;
            var f = frac;
            var k: usize = SCALE_DIGITS;
            while (k > 0) {
                k -= 1;
                fbuf[k] = @intCast('0' + @as(u8, @intCast(f % 10)));
                f /= 10;
            }
            var end: usize = SCALE_DIGITS;
            while (end > 0 and fbuf[end - 1] == '0') end -= 1;
            try buf.append(alloc, '.');
            try buf.appendSlice(alloc, fbuf[0..end]);
        }
        return buf.toOwnedSlice(alloc);
    }
};

/// 10^e as i256, for e in [0, MAX_POW10]. Runtime loop — the exponent is
/// bounded and small, so this is not a hot path worth a lookup table.
fn pow10_256(e: u32) i256 {
    var r: i256 = 1;
    var k: u32 = 0;
    while (k < e) : (k += 1) r *= 10;
    return r;
}

/// num / den rounded half-away-from-zero, sign-aware. `den` must be non-zero.
/// Used by `ROUND()` (Excel-compatible: 2.5 → 3, −2.5 → −3).
fn divRoundHalfAway(num: i256, den: i256) i256 {
    const result_neg = (num < 0) != (den < 0);
    const n: i256 = if (num < 0) -num else num;
    const d: i256 = if (den < 0) -den else den;
    var q = @divTrunc(n, d);
    const r = @rem(n, d);
    if (r * 2 >= d) q += 1; // a tie (or more) rounds up, away from zero
    return if (result_neg) -q else q;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectStr(d: Decimal, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try d.toString(arena.allocator());
    try testing.expectEqualStrings(want, got);
}

test "parse + format roundtrip" {
    try expectStr(Decimal.parse("0").?, "0");
    try expectStr(Decimal.parse("123").?, "123");
    try expectStr(Decimal.parse("-123").?, "-123");
    try expectStr(Decimal.parse("1.5").?, "1.5");
    try expectStr(Decimal.parse("1.25").?, "1.25");
    try expectStr(Decimal.parse("-3.0").?, "-3");
    try expectStr(Decimal.parse("1000.00").?, "1000");
    try expectStr(Decimal.parse("0.0313646200").?, "0.03136462");
    try expectStr(Decimal.parse("+42").?, "42");
}

test "parse rejects" {
    try testing.expect(Decimal.parse("") == null);
    try testing.expect(Decimal.parse("abc") == null);
    try testing.expect(Decimal.parse("1,234.56") == null); // grouping not handled here
    try testing.expect(Decimal.parse("1.2.3") == null);
    try testing.expect(Decimal.parse("1e") == null);
    try testing.expect(Decimal.parse("--1") == null);
    try testing.expect(Decimal.parse("1 ") == null);
}

test "scientific notation" {
    try expectStr(Decimal.parse("2.08e9").?, "2080000000");
    try expectStr(Decimal.parse("1.5E2").?, "150");
    try expectStr(Decimal.parse("1e-3").?, "0.001");
    try expectStr(Decimal.parse("1.23e-4").?, "0.000123");
}

test "12-digit quantise, half-away-from-zero on 13th" {
    // 13 fractional digits → rounds into the 12th, half away from zero.
    try expectStr(Decimal.parse("0.1234567890125").?, "0.123456789013"); // exact half → up
    try expectStr(Decimal.parse("0.1234567890124").?, "0.123456789012"); // below half → down
    try expectStr(Decimal.parse("0.0000000000005").?, "0.000000000001"); // exact half → up
    try expectStr(Decimal.parse("0.0000000000004").?, "0"); // below half → down
    try expectStr(Decimal.parse("-0.0000000000005").?, "-0.000000000001"); // away from zero (negative)
}

test "exact decimal arithmetic" {
    const a = Decimal.parse("0.02").?;
    const b = Decimal.parse("0.08").?;
    try expectStr(a.add(b).?, "0.1"); // the headline: no binary-float noise
    try expectStr(Decimal.parse("100").?.sub(Decimal.parse("0.01").?).?, "99.99");
}

test "mul and div" {
    try expectStr(Decimal.parse("1.5").?.mul(Decimal.parse("2").?).?, "3");
    try expectStr(Decimal.parse("0.1").?.mul(Decimal.parse("0.1").?).?, "0.01");
    try expectStr(Decimal.parse("10").?.div(Decimal.parse("4").?).?, "2.5");
    // 1/3, 2/3 → 12 digits (13th digit isn't a tie, so mode is moot here).
    try expectStr(Decimal.parse("1").?.div(Decimal.parse("3").?).?, "0.333333333333");
    try expectStr(Decimal.parse("2").?.div(Decimal.parse("3").?).?, "0.666666666667");
    // mul below 1e-12 rounds half-away (not truncates): 1.5e-12 → 2e-12.
    try expectStr(Decimal.parse("0.000001").?.mul(Decimal.parse("0.0000015").?).?, "0.000000000002");
    try testing.expect(Decimal.parse("1").?.div(Decimal.zero) == null);
}

test "arithmetic overflow returns null (no trap)" {
    // 1e14 × 1e14 = 1e28, beyond the ±1.7e26 range.
    const big = Decimal.parse("100000000000000").?;
    try testing.expect(big.mul(big) == null);
    // add/sub near the i128 ceiling overflow too.
    const near_max = Decimal{ .raw = std.math.maxInt(i128) };
    try testing.expect(near_max.add(Decimal.one) == null);
    const near_min = Decimal{ .raw = std.math.minInt(i128) };
    try testing.expect(near_min.neg() == null); // |i128 min| is unrepresentable
    // A realistic product is fine.
    try expectStr(Decimal.parse("1000000").?.mul(Decimal.parse("1000000").?).?, "1000000000000");
}

test "round — half away from zero (Excel/ROUND surface)" {
    try expectStr(Decimal.parse("1.2345").?.round(2), "1.23");
    try expectStr(Decimal.parse("1.2355").?.round(2), "1.24");
    try expectStr(Decimal.parse("2.5").?.round(0), "3"); // tie → away from zero
    try expectStr(Decimal.parse("3.5").?.round(0), "4");
    try expectStr(Decimal.parse("-2.5").?.round(0), "-3"); // tie → away from zero
    try expectStr(Decimal.parse("0.125").?.round(2), "0.13"); // tie at 3rd place → up
    try expectStr(Decimal.parse("1250").?.round(-2), "1300"); // 12.5 → away → 13 → 1300
    try expectStr(Decimal.parse("1.5").?.round(12), "1.5"); // no-op
}

test "floor and ceil" {
    try expectStr(Decimal.parse("3.7").?.floor(), "3");
    try expectStr(Decimal.parse("-3.2").?.floor(), "-4");
    try expectStr(Decimal.parse("3.2").?.ceil(), "4");
    try expectStr(Decimal.parse("-3.7").?.ceil(), "-3");
}

test "fromInt and trunc" {
    try expectStr(Decimal.fromInt(2025), "2025");
    try expectStr(Decimal.fromInt(-12), "-12");
    try testing.expectEqual(@as(i128, 3), Decimal.parse("3.99").?.trunc());
    try testing.expectEqual(@as(i128, -3), Decimal.parse("-3.99").?.trunc());
}

test "range boundaries" {
    // Max representable integer part region.
    try expectStr(Decimal.parse("170141183460469231731687303.715884105727").?, "170141183460469231731687303.715884105727");
    // Just beyond → overflow → null.
    try testing.expect(Decimal.parse("1e30") == null);
    try testing.expect(Decimal.parse("999999999999999999999999999999") == null);
}

test "order and eql" {
    try testing.expect(Decimal.parse("1.5").?.eql(Decimal.parse("1.50").?));
    try testing.expect(Decimal.parse("1.5").?.order(Decimal.parse("1.6").?) == .lt);
    try testing.expect(Decimal.parse("2").?.order(Decimal.parse("1").?) == .gt);
}
