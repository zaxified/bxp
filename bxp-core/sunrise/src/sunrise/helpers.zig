const std = @import("std");

/// Get current Unix timestamp (seconds since 1970-01-01 00:00:00 UTC)
pub fn now() i64 {
    return std.time.timestamp();
}

/// Check if year is a leap year
pub fn isLeapYear(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
}

/// Get the number of days in a specific month
pub fn daysInMonth(year: i32, month: i32) i32 {
    const month_days = [_]i32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month < 1 or month > 12) return 0;

    var days = month_days[@as(usize, @intCast(month - 1))];
    if (month == 2 and isLeapYear(year)) {
        days = 29;
    }
    return days;
}
