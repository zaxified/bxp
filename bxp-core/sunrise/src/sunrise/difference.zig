const std = @import("std");

/// Calculate difference in days between two timestamps
pub fn differenceInDays(timestamp1: i64, timestamp2: i64) i64 {
    const diff = timestamp1 - timestamp2;
    return @divFloor(diff, 86400);
}

/// Calculate difference in months between two timestamps (approximate)
pub fn differenceInMonths(timestamp1: i64, timestamp2: i64) i32 {
    const ts1 = if (timestamp1 < 0) @as(u64, 0) else @as(u64, @intCast(timestamp1));
    const ts2 = if (timestamp2 < 0) @as(u64, 0) else @as(u64, @intCast(timestamp2));

    const epoch_seconds1 = std.time.epoch.EpochSeconds{ .secs = ts1 };
    const epoch_day1 = epoch_seconds1.getEpochDay();
    const year_day1 = epoch_day1.calculateYearDay();
    const month_day1 = year_day1.calculateMonthDay();

    const epoch_seconds2 = std.time.epoch.EpochSeconds{ .secs = ts2 };
    const epoch_day2 = epoch_seconds2.getEpochDay();
    const year_day2 = epoch_day2.calculateYearDay();
    const month_day2 = year_day2.calculateMonthDay();

    const year1 = year_day1.year;
    const month1 = month_day1.month.numeric();
    const year2 = year_day2.year;
    const month2 = month_day2.month.numeric();

    const total_months1 = year1 * 12 + @as(i32, @intCast(month1));
    const total_months2 = year2 * 12 + @as(i32, @intCast(month2));

    return total_months1 - total_months2;
}

/// Calculate difference in years between two timestamps
pub fn differenceInYears(timestamp1: i64, timestamp2: i64) i32 {
    const ts1 = if (timestamp1 < 0) @as(u64, 0) else @as(u64, @intCast(timestamp1));
    const ts2 = if (timestamp2 < 0) @as(u64, 0) else @as(u64, @intCast(timestamp2));

    const epoch_seconds1 = std.time.epoch.EpochSeconds{ .secs = ts1 };
    const epoch_day1 = epoch_seconds1.getEpochDay();
    const year_day1 = epoch_day1.calculateYearDay();

    const epoch_seconds2 = std.time.epoch.EpochSeconds{ .secs = ts2 };
    const epoch_day2 = epoch_seconds2.getEpochDay();
    const year_day2 = epoch_day2.calculateYearDay();

    return year_day1.year - year_day2.year;
}
