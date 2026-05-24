const std = @import("std");
const helpers = @import("helpers.zig");

/// Format options
pub const FormatOptions = struct {
    /// Format string (null = use default format)
    /// Supports format tokens:
    /// - YYYY: 4-digit year
    /// - YY: 2-digit year
    /// - MM: 2-digit month (01-12)
    /// - M: 1-2 digit month (1-12)
    /// - DD: 2-digit day (01-31)
    /// - D: 1-2 digit day (1-31)
    /// - hh: 2-digit hour 24h format (00-23)
    /// - h: 1-2 digit hour 24h format (0-23)
    /// - ii: 2-digit hour 12h format (01-12)
    /// - i: 1-2 digit hour 12h format (1-12)
    /// - mm: 2-digit minute (00-59)
    /// - m: 1-2 digit minute (0-59)
    /// - ss: 2-digit second (00-59)
    /// - s: 1-2 digit second (0-59)
    /// - a: AM/PM (lowercase: am/pm)
    /// - A: AM/PM (uppercase: AM/PM)
    /// - EEEE: full day name (Monday, Tuesday, etc.)
    /// - EEE, EE, E: short day name (Mon, Tue, etc.)
    /// - e: day of week as number (1-7, Monday=1)
    /// - MMM: short month name (Jan, Feb, etc.)
    /// - MMMM: full month name (January, February, etc.)
    /// - [text]: escaped text (literal)
    format: ?[]const u8 = null,

    /// Use ISO8601 format (only used when format is null)
    iso8601: bool = false,

    /// Reserved for future timezone support
    include_timezone: bool = false,
};

/// Date components
const DateComponents = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    day_of_week: u8, // 1-7 (Monday=1)
};

/// Format Unix timestamp as string
/// Converts Unix timestamp (seconds since 1970-01-01 00:00:00 UTC) to formatted string
pub fn format(allocator: std.mem.Allocator, timestamp: i64, options: FormatOptions) ![]const u8 {
    const ts = if (timestamp < 0) @as(u64, 0) else @as(u64, @intCast(timestamp));

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = ts };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const components = DateComponents{
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = month_day.day_index + 1,
        .hour = day_seconds.getHoursIntoDay(),
        .minute = day_seconds.getMinutesIntoHour(),
        .second = day_seconds.getSecondsIntoMinute(),
        .day_of_week = calculateDayOfWeek(epoch_day),
    };

    // Custom format
    if (options.format) |fmt| {
        return formatWithPattern(allocator, components, fmt);
    }

    // Default formats
    const year_u32 = @as(u32, @intCast(components.year));
    if (options.iso8601) {
        return std.fmt.allocPrint(
            allocator,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
            .{ year_u32, components.month, components.day, components.hour, components.minute, components.second },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}",
        .{ year_u32, components.month, components.day, components.hour, components.minute, components.second },
    );
}

/// Format with custom pattern
fn formatWithPattern(allocator: std.mem.Allocator, components: DateComponents, pattern: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    var pos: usize = 0;
    while (pos < pattern.len) {
        // Check for escaped text [text]
        if (pattern[pos] == '[') {
            const end_pos = std.mem.indexOfScalarPos(u8, pattern, pos + 1, ']') orelse pattern.len;
            if (end_pos > pos + 1) {
                try result.appendSlice(allocator, pattern[pos + 1 .. end_pos]);
                pos = end_pos + 1;
                continue;
            }
        }

        // Check for format tokens (longest match first)
        if (matchToken(pattern, pos, "YYYY")) {
            try result.writer(allocator).print("{d:0>4}", .{@as(u32, @intCast(components.year))});
            pos += 4;
        } else if (matchToken(pattern, pos, "MMMM")) {
            try result.appendSlice(allocator, getFullMonthName(components.month));
            pos += 4;
        } else if (matchToken(pattern, pos, "EEEE")) {
            try result.appendSlice(allocator, getFullDayName(components.day_of_week));
            pos += 4;
        } else if (matchToken(pattern, pos, "MMM")) {
            try result.appendSlice(allocator, getShortMonthName(components.month));
            pos += 3;
        } else if (matchToken(pattern, pos, "EEE")) {
            try result.appendSlice(allocator, getShortDayName(components.day_of_week));
            pos += 3;
        } else if (matchToken(pattern, pos, "MM")) {
            try result.writer(allocator).print("{d:0>2}", .{components.month});
            pos += 2;
        } else if (matchToken(pattern, pos, "DD")) {
            try result.writer(allocator).print("{d:0>2}", .{components.day});
            pos += 2;
        } else if (matchToken(pattern, pos, "ii")) {
            const hour12 = get12Hour(components.hour);
            try result.writer(allocator).print("{d:0>2}", .{hour12});
            pos += 2;
        } else if (matchToken(pattern, pos, "hh")) {
            try result.writer(allocator).print("{d:0>2}", .{components.hour});
            pos += 2;
        } else if (matchToken(pattern, pos, "mm")) {
            try result.writer(allocator).print("{d:0>2}", .{components.minute});
            pos += 2;
        } else if (matchToken(pattern, pos, "ss")) {
            try result.writer(allocator).print("{d:0>2}", .{components.second});
            pos += 2;
        } else if (matchToken(pattern, pos, "YY")) {
            const year_short = @as(u32, @intCast(@mod(components.year, 100)));
            try result.writer(allocator).print("{d:0>2}", .{year_short});
            pos += 2;
        } else if (matchToken(pattern, pos, "EE")) {
            try result.appendSlice(allocator, getShortDayName(components.day_of_week));
            pos += 2;
        } else if (matchToken(pattern, pos, "M")) {
            try result.writer(allocator).print("{d}", .{components.month});
            pos += 1;
        } else if (matchToken(pattern, pos, "D")) {
            try result.writer(allocator).print("{d}", .{components.day});
            pos += 1;
        } else if (matchToken(pattern, pos, "i")) {
            const hour12 = get12Hour(components.hour);
            try result.writer(allocator).print("{d}", .{hour12});
            pos += 1;
        } else if (matchToken(pattern, pos, "h")) {
            try result.writer(allocator).print("{d}", .{components.hour});
            pos += 1;
        } else if (matchToken(pattern, pos, "m")) {
            try result.writer(allocator).print("{d}", .{components.minute});
            pos += 1;
        } else if (matchToken(pattern, pos, "s")) {
            try result.writer(allocator).print("{d}", .{components.second});
            pos += 1;
        } else if (matchToken(pattern, pos, "E")) {
            try result.appendSlice(allocator, getShortDayName(components.day_of_week));
            pos += 1;
        } else if (matchToken(pattern, pos, "e")) {
            try result.writer(allocator).print("{d}", .{components.day_of_week});
            pos += 1;
        } else if (matchToken(pattern, pos, "A")) {
            try result.appendSlice(allocator, getAMPM(components.hour, true));
            pos += 1;
        } else if (matchToken(pattern, pos, "a")) {
            try result.appendSlice(allocator, getAMPM(components.hour, false));
            pos += 1;
        } else {
            // Literal character
            try result.append(allocator, pattern[pos]);
            pos += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Match token at position
fn matchToken(str: []const u8, pos: usize, token: []const u8) bool {
    if (pos + token.len > str.len) return false;
    return std.mem.eql(u8, str[pos .. pos + token.len], token);
}

/// Get short month name
fn getShortMonthName(month: u8) []const u8 {
    const names = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    if (month < 1 or month > 12) return "???";
    return names[month - 1];
}

/// Get full month name
fn getFullMonthName(month: u8) []const u8 {
    const names = [_][]const u8{
        "January",   "February", "March",    "April",
        "May",       "June",     "July",     "August",
        "September", "October",  "November", "December",
    };
    if (month < 1 or month > 12) return "Unknown";
    return names[month - 1];
}

/// Get short day name
fn getShortDayName(day: u8) []const u8 {
    const names = [_][]const u8{
        "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun",
    };
    if (day < 1 or day > 7) return "???";
    return names[day - 1];
}

/// Get full day name
fn getFullDayName(day: u8) []const u8 {
    const names = [_][]const u8{
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    };
    if (day < 1 or day > 7) return "Unknown";
    return names[day - 1];
}

/// Calculate day of week (1=Monday, 7=Sunday)
fn calculateDayOfWeek(epoch_day: std.time.epoch.EpochDay) u8 {
    // 1970-01-01 was Thursday (4)
    const day_num = epoch_day.day;
    const dow = @mod(day_num + 3, 7) + 1;
    return @as(u8, @intCast(dow));
}

/// Convert 24h hour to 12h hour (1-12)
fn get12Hour(hour: u8) u8 {
    if (hour == 0) return 12;
    if (hour <= 12) return hour;
    return hour - 12;
}

/// Get AM/PM string
fn getAMPM(hour: u8, uppercase: bool) []const u8 {
    if (hour < 12) {
        return if (uppercase) "AM" else "am";
    } else {
        return if (uppercase) "PM" else "pm";
    }
}
