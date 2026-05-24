const std = @import("std");

/// Check if timestamp1 is after timestamp2
pub fn isAfter(timestamp1: i64, timestamp2: i64) bool {
    return timestamp1 > timestamp2;
}

/// Check if timestamp1 is before timestamp2
pub fn isBefore(timestamp1: i64, timestamp2: i64) bool {
    return timestamp1 < timestamp2;
}

/// Check if timestamp1 is equal to timestamp2
pub fn isEqual(timestamp1: i64, timestamp2: i64) bool {
    return timestamp1 == timestamp2;
}

/// Check if two timestamps are on the same day
pub fn isSameDay(timestamp1: i64, timestamp2: i64) bool {
    const day1 = @divFloor(timestamp1, 86400);
    const day2 = @divFloor(timestamp2, 86400);
    return day1 == day2;
}

/// Check if two timestamps are in the same month
pub fn isSameMonth(timestamp1: i64, timestamp2: i64) bool {
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

    return year_day1.year == year_day2.year and month_day1.month.numeric() == month_day2.month.numeric();
}

/// Check if two timestamps are in the same year
pub fn isSameYear(timestamp1: i64, timestamp2: i64) bool {
    const ts1 = if (timestamp1 < 0) @as(u64, 0) else @as(u64, @intCast(timestamp1));
    const ts2 = if (timestamp2 < 0) @as(u64, 0) else @as(u64, @intCast(timestamp2));

    const epoch_seconds1 = std.time.epoch.EpochSeconds{ .secs = ts1 };
    const epoch_day1 = epoch_seconds1.getEpochDay();
    const year_day1 = epoch_day1.calculateYearDay();

    const epoch_seconds2 = std.time.epoch.EpochSeconds{ .secs = ts2 };
    const epoch_day2 = epoch_seconds2.getEpochDay();
    const year_day2 = epoch_day2.calculateYearDay();

    return year_day1.year == year_day2.year;
}
