const std = @import("std");
const add = @import("add.zig");

/// Subtract days from a timestamp
pub fn subDays(timestamp: i64, days: i64) i64 {
    return timestamp - (days * 86400);
}

/// Subtract months from a timestamp
pub fn subMonths(timestamp: i64, months: i32) i64 {
    return add.addMonths(timestamp, -months);
}

/// Subtract years from a timestamp
pub fn subYears(timestamp: i64, years: i32) i64 {
    return add.addMonths(timestamp, -years * 12);
}
