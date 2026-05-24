const std = @import("std");
const helpers = @import("helpers.zig");

/// Add days to a timestamp
pub fn addDays(timestamp: i64, days: i64) i64 {
    return timestamp + (days * 86400);
}

/// Add months to a timestamp
pub fn addMonths(timestamp: i64, months: i32) i64 {
    const ts = if (timestamp < 0) @as(u64, 0) else @as(u64, @intCast(timestamp));

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = ts };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var year: i32 = year_day.year;
    var month = month_day.month.numeric();
    const day = month_day.day_index + 1;

    // Add months
    const total_months = @as(i32, @intCast(month)) + months;
    const years_to_add = @divFloor(total_months - 1, 12);
    const new_month = @mod(total_months - 1, 12) + 1;

    year += years_to_add;
    month = @as(u4, @intCast(new_month));

    // Ensure day is valid for the new month
    const max_day = helpers.daysInMonth(year, @as(i32, @intCast(month)));
    const adjusted_day = @min(day, @as(u8, @intCast(max_day)));

    // Reconstruct timestamp
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

    days += @as(i64, @intCast(adjusted_day - 1));

    return days * 86400 + @as(i64, @intCast(day_seconds.secs));
}

/// Add years to a timestamp
pub fn addYears(timestamp: i64, years: i32) i64 {
    return addMonths(timestamp, years * 12);
}
