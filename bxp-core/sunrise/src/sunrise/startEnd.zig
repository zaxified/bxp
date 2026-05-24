const std = @import("std");
const helpers = @import("helpers.zig");

/// Get the start of the day (00:00:00) for a timestamp
pub fn startOfDay(timestamp: i64) i64 {
    const days = @divFloor(timestamp, 86400);
    return days * 86400;
}

/// Get the end of the day (23:59:59) for a timestamp
pub fn endOfDay(timestamp: i64) i64 {
    const days = @divFloor(timestamp, 86400);
    return days * 86400 + 86399;
}

/// Get the start of the month for a timestamp
pub fn startOfMonth(timestamp: i64) i64 {
    const ts = if (timestamp < 0) @as(u64, 0) else @as(u64, @intCast(timestamp));

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = ts };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const year = year_day.year;
    const month = month_day.month.numeric();

    // Calculate days since epoch to the first day of the month
    var days: i64 = 0;
    var y: i32 = 1970;
    while (y < year) : (y += 1) {
        days += if (helpers.isLeapYear(y)) 366 else 365;
    }

    const month_days = [_]i32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const is_leap = helpers.isLeapYear(year);
    var m: i32 = 1;
    while (m < @as(i32, @intCast(month))) : (m += 1) {
        var days_in_month_val = month_days[@as(usize, @intCast(m - 1))];
        if (m == 2 and is_leap) {
            days_in_month_val = 29;
        }
        days += days_in_month_val;
    }

    return days * 86400;
}

/// Get the end of the month for a timestamp
pub fn endOfMonth(timestamp: i64) i64 {
    const ts = if (timestamp < 0) @as(u64, 0) else @as(u64, @intCast(timestamp));

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = ts };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const year = year_day.year;
    const month = month_day.month.numeric();
    const last_day = helpers.daysInMonth(year, @as(i32, @intCast(month)));

    // Calculate days since epoch to the last day of the month
    var days: i64 = 0;
    var y: i32 = 1970;
    while (y < year) : (y += 1) {
        days += if (helpers.isLeapYear(y)) 366 else 365;
    }

    const month_days = [_]i32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const is_leap = helpers.isLeapYear(year);
    var m: i32 = 1;
    while (m < @as(i32, @intCast(month))) : (m += 1) {
        var days_in_month_val = month_days[@as(usize, @intCast(m - 1))];
        if (m == 2 and is_leap) {
            days_in_month_val = 29;
        }
        days += days_in_month_val;
    }

    days += @as(i64, @intCast(last_day - 1));

    return days * 86400 + 86399;
}

/// Get the start of the year for a timestamp
pub fn startOfYear(timestamp: i64) i64 {
    const ts = if (timestamp < 0) @as(u64, 0) else @as(u64, @intCast(timestamp));

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = ts };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();

    const year = year_day.year;

    // Calculate days since epoch to the first day of the year
    var days: i64 = 0;
    var y: i32 = 1970;
    while (y < year) : (y += 1) {
        days += if (helpers.isLeapYear(y)) 366 else 365;
    }

    return days * 86400;
}

/// Get the end of the year for a timestamp
pub fn endOfYear(timestamp: i64) i64 {
    const ts = if (timestamp < 0) @as(u64, 0) else @as(u64, @intCast(timestamp));

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = ts };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();

    const year = year_day.year;

    // Calculate days since epoch to the last day of the year
    var days: i64 = 0;
    var y: i32 = 1970;
    while (y < year) : (y += 1) {
        days += if (helpers.isLeapYear(y)) 366 else 365;
    }

    days += if (helpers.isLeapYear(year)) 365 else 364;

    return days * 86400 + 86399;
}
