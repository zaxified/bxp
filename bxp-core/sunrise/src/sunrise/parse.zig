const std = @import("std");
const helpers = @import("helpers.zig");

/// Parse errors
pub const ParseError = error{
    InvalidFormat,
    InvalidDate,
    InvalidTime,
    OutOfRange,
    InvalidFormatString,
    OutOfMemory,
};

/// Parse options
pub const ParseOptions = struct {
    /// Format string (null = auto-detect)
    /// Supports format tokens:
    /// - YYYY: 4-digit year
    /// - YY: 2-digit year
    /// - MM/M: month
    /// - DD/D: day
    /// - hh/h: hour (24h format)
    /// - ii/i: hour (12h format, requires a/A)
    /// - mm/m: minute
    /// - ss/s: second
    /// - a/A: AM/PM
    /// - EEEE: full day name (Monday, Tuesday, etc.)
    /// - EEE/EE/E: short day name (Mon, Tue, etc.)
    /// - e: day of week as number (1-7)
    /// - MMM: short month name (Jan, Feb, etc.)
    /// - MMMM: full month name (January, February, etc.)
    /// - [text]: escaped text (literal)
    /// - [*]: skip arbitrary text until next token
    format: ?[]const u8 = null,

    /// Reference date for missing components (default: epoch)
    /// Use helpers.now() for current date
    reference_date: i64 = 0,
};

/// Parse date/time string to Unix timestamp
///
/// With auto-detection (no format specified):
/// ```zig
/// const ts = sunrise.parse("2024-01-15 10:30:45", .{});
/// ```
///
/// With custom format (date-fns style):
/// ```zig
/// const ts = sunrise.parse("15/01/2024", .{ .format = "dd/MM/yyyy" });
/// ```
pub fn parse(date_str: []const u8, options: ParseOptions) !i64 {
    if (options.format) |fmt| {
        return parseWithFormat(date_str, fmt, options.reference_date);
    } else {
        return autoDetectAndParse(date_str);
    }
}

/// Parse date/time string with format string (date-fns style)
///
/// **bxp vendor patch (2026-05-25):** the tokenizer allocator was hardcoded
/// to `std.heap.page_allocator`, which routed every per-call growth of the
/// `ArrayList(FormatToken)` straight to `mmap` / `munmap`. Under bxp's
/// per-row `DATE_CONVERT` call site that meant one mmap+munmap pair per
/// source row — on a 2M-row workload the syscall count dominated the
/// wall-time budget (~100 s of kernel time on 25 s wall). The patch uses
/// a stack-resident `FixedBufferAllocator` (1 KiB; sunrise format strings
/// never exceed ~20 tokens × 24 bytes per token) so the tokenizer
/// allocates exclusively on the calling thread's stack — zero syscalls,
/// zero shared allocator contention. Upstream PR pending; revert once
/// the dependency picks up an allocator-parameterised signature.
fn parseWithFormat(date_str: []const u8, format_str: []const u8, reference_date: i64) ParseError!i64 {
    var fba_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    var tokens = try tokenizeFormat(fba.allocator(), format_str);
    defer tokens.deinit(fba.allocator());

    var date_components = DateComponents{
        .year = null,
        .month = null,
        .day = null,
        .hour = 0,
        .minute = 0,
        .second = 0,
        .is_pm = null,
    };

    var date_pos: usize = 0;

    for (tokens.items, 0..) |token, token_idx| {
        if (date_pos >= date_str.len) {
            // Allow end of string for last token
            switch (token) {
                .literal => |lit| {
                    if (lit.len > 0) return ParseError.InvalidFormat;
                },
                else => return ParseError.InvalidFormat,
            }
            continue;
        }

        switch (token) {
            .year_full => {
                // yyyy: 4 digits
                if (date_pos + 4 > date_str.len) return ParseError.InvalidFormat;
                const year_str = date_str[date_pos .. date_pos + 4];
                date_components.year = std.fmt.parseInt(i32, year_str, 10) catch return ParseError.InvalidDate;
                date_pos += 4;
            },
            .year_short => {
                // yy: 2 digits
                if (date_pos + 2 > date_str.len) return ParseError.InvalidFormat;
                const year_str = date_str[date_pos .. date_pos + 2];
                const year_short = std.fmt.parseInt(i32, year_str, 10) catch return ParseError.InvalidDate;
                // Convert 2-digit year to 4-digit (00-69 -> 2000-2069, 70-99 -> 1970-1999)
                date_components.year = if (year_short < 70) year_short + 2000 else year_short + 1900;
                date_pos += 2;
            },
            .month_full => {
                // MM: 2 digits
                if (date_pos + 2 > date_str.len) return ParseError.InvalidFormat;
                const month_str = date_str[date_pos .. date_pos + 2];
                date_components.month = std.fmt.parseInt(i32, month_str, 10) catch return ParseError.InvalidDate;
                date_pos += 2;
            },
            .month_short => {
                // M: 1-2 digits
                const end_pos = findNumberEnd(date_str, date_pos, 2);
                const month_str = date_str[date_pos..end_pos];
                date_components.month = std.fmt.parseInt(i32, month_str, 10) catch return ParseError.InvalidDate;
                date_pos = end_pos;
            },
            .month_name_short => {
                // MMM: Jan, Feb, etc.
                const month_value = try parseShortMonthName(date_str[date_pos..]);
                date_components.month = month_value;
                date_pos += 3;
            },
            .month_name_long => {
                // MMMM: January, February, etc.
                const result = try parseLongMonthName(date_str[date_pos..]);
                date_components.month = result.month;
                date_pos += result.length;
            },
            .day_full => {
                // dd: 2 digits
                if (date_pos + 2 > date_str.len) return ParseError.InvalidFormat;
                const day_str = date_str[date_pos .. date_pos + 2];
                date_components.day = std.fmt.parseInt(i32, day_str, 10) catch return ParseError.InvalidDate;
                date_pos += 2;
            },
            .day_short => {
                // d: 1-2 digits
                const end_pos = findNumberEnd(date_str, date_pos, 2);
                const day_str = date_str[date_pos..end_pos];
                date_components.day = std.fmt.parseInt(i32, day_str, 10) catch return ParseError.InvalidDate;
                date_pos = end_pos;
            },
            .day_name_short, .day_name_long => {
                // EEE/EEEE: Skip day name parsing (informational only)
                const result = try parseDayName(date_str[date_pos..]);
                date_pos += result.length;
            },
            .day_of_week => {
                // e: 1 digit (1-7)
                const end_pos = findNumberEnd(date_str, date_pos, 1);
                if (end_pos == date_pos) return ParseError.InvalidFormat;
                const dow_str = date_str[date_pos..end_pos];
                const dow = std.fmt.parseInt(i32, dow_str, 10) catch return ParseError.InvalidDate;
                if (dow < 1 or dow > 7) return ParseError.InvalidDate;
                // Day of week is informational, not used for timestamp calculation
                date_pos = end_pos;
            },
            .hour_24_full => {
                // hh: 2 digits (24h)
                if (date_pos + 2 > date_str.len) return ParseError.InvalidFormat;
                const hour_str = date_str[date_pos .. date_pos + 2];
                date_components.hour = std.fmt.parseInt(i32, hour_str, 10) catch return ParseError.InvalidTime;
                date_pos += 2;
            },
            .hour_24_short => {
                // h: 1-2 digits (24h)
                const end_pos = findNumberEnd(date_str, date_pos, 2);
                const hour_str = date_str[date_pos..end_pos];
                date_components.hour = std.fmt.parseInt(i32, hour_str, 10) catch return ParseError.InvalidTime;
                date_pos = end_pos;
            },
            .hour_12_full => {
                // ii: 2 digits (12h)
                if (date_pos + 2 > date_str.len) return ParseError.InvalidFormat;
                const hour_str = date_str[date_pos .. date_pos + 2];
                date_components.hour = std.fmt.parseInt(i32, hour_str, 10) catch return ParseError.InvalidTime;
                date_pos += 2;
            },
            .hour_12_short => {
                // i: 1-2 digits (12h)
                const end_pos = findNumberEnd(date_str, date_pos, 2);
                const hour_str = date_str[date_pos..end_pos];
                date_components.hour = std.fmt.parseInt(i32, hour_str, 10) catch return ParseError.InvalidTime;
                date_pos = end_pos;
            },
            .minute_full => {
                // mm: 2 digits
                if (date_pos + 2 > date_str.len) return ParseError.InvalidFormat;
                const min_str = date_str[date_pos .. date_pos + 2];
                date_components.minute = std.fmt.parseInt(i32, min_str, 10) catch return ParseError.InvalidTime;
                date_pos += 2;
            },
            .minute_short => {
                // m: 1-2 digits
                const end_pos = findNumberEnd(date_str, date_pos, 2);
                const min_str = date_str[date_pos..end_pos];
                date_components.minute = std.fmt.parseInt(i32, min_str, 10) catch return ParseError.InvalidTime;
                date_pos = end_pos;
            },
            .second_full => {
                // ss: 2 digits
                if (date_pos + 2 > date_str.len) return ParseError.InvalidFormat;
                const sec_str = date_str[date_pos .. date_pos + 2];
                date_components.second = std.fmt.parseInt(i32, sec_str, 10) catch return ParseError.InvalidTime;
                date_pos += 2;
            },
            .second_short => {
                // s: 1-2 digits
                const end_pos = findNumberEnd(date_str, date_pos, 2);
                const sec_str = date_str[date_pos..end_pos];
                date_components.second = std.fmt.parseInt(i32, sec_str, 10) catch return ParseError.InvalidTime;
                date_pos = end_pos;
            },
            .ampm_upper => {
                // A: AM/PM
                if (date_pos + 2 > date_str.len) return ParseError.InvalidFormat;
                const ampm = date_str[date_pos .. date_pos + 2];
                if (std.ascii.eqlIgnoreCase(ampm, "AM")) {
                    date_components.is_pm = false;
                } else if (std.ascii.eqlIgnoreCase(ampm, "PM")) {
                    date_components.is_pm = true;
                } else {
                    return ParseError.InvalidTime;
                }
                date_pos += 2;
            },
            .ampm_lower => {
                // a: am/pm
                if (date_pos + 2 > date_str.len) return ParseError.InvalidFormat;
                const ampm = date_str[date_pos .. date_pos + 2];
                if (std.ascii.eqlIgnoreCase(ampm, "AM")) {
                    date_components.is_pm = false;
                } else if (std.ascii.eqlIgnoreCase(ampm, "PM")) {
                    date_components.is_pm = true;
                } else {
                    return ParseError.InvalidTime;
                }
                date_pos += 2;
            },
            .wildcard => {
                // [*]: Skip arbitrary text until next token
                if (token_idx + 1 < tokens.items.len) {
                    const next_token = tokens.items[token_idx + 1];
                    // Skip until we can match the next token
                    date_pos = try skipUntilNextToken(date_str, date_pos, next_token);
                } else {
                    // If this is the last token, skip to the end
                    date_pos = date_str.len;
                }
            },
            .literal => |lit| {
                // Match literal characters
                if (date_pos + lit.len > date_str.len) return ParseError.InvalidFormat;
                const match = date_str[date_pos .. date_pos + lit.len];
                if (!std.mem.eql(u8, match, lit)) return ParseError.InvalidFormat;
                date_pos += lit.len;
            },
        }
    }

    // Convert 12h to 24h if needed
    if (date_components.is_pm) |is_pm| {
        if (date_components.hour == 12) {
            // 12 PM = 12, 12 AM = 0
            if (!is_pm) date_components.hour = 0;
        } else if (is_pm) {
            // 1-11 PM = 13-23
            date_components.hour += 12;
        }
        // 1-11 AM = 1-11 (no change)
    }

    // Fill in missing components from reference date
    if (date_components.year == null or date_components.month == null or date_components.day == null) {
        if (reference_date == 0) {
            // Use epoch date (1970-01-01) for missing components
            if (date_components.year == null) date_components.year = 1970;
            if (date_components.month == null) date_components.month = 1;
            if (date_components.day == null) date_components.day = 1;
        } else {
            // Extract date components from reference date
            const ref_components = timestampToComponents(reference_date);
            if (date_components.year == null) date_components.year = ref_components.year;
            if (date_components.month == null) date_components.month = ref_components.month;
            if (date_components.day == null) date_components.day = ref_components.day;
        }
    }

    return componentsToTimestamp(date_components);
}

/// Date components structure
const DateComponents = struct {
    year: ?i32,
    month: ?i32,
    day: ?i32,
    hour: i32,
    minute: i32,
    second: i32,
    is_pm: ?bool, // For 12h format: true=PM, false=AM
};

/// Format token types
const FormatToken = union(enum) {
    year_full, // YYYY
    year_short, // YY
    month_full, // MM
    month_short, // M
    month_name_short, // MMM
    month_name_long, // MMMM
    day_full, // DD
    day_short, // D
    day_name_long, // EEEE
    day_name_short, // EEE, EE, E
    day_of_week, // e
    hour_24_full, // hh
    hour_24_short, // h
    hour_12_full, // ii
    hour_12_short, // i
    minute_full, // mm
    minute_short, // m
    second_full, // ss
    second_short, // s
    ampm_upper, // A
    ampm_lower, // a
    wildcard, // [*]
    literal: []const u8,
};

/// Tokenize format string into format tokens
fn tokenizeFormat(allocator: std.mem.Allocator, format_str: []const u8) !std.ArrayList(FormatToken) {
    var tokens: std.ArrayList(FormatToken) = .{};
    errdefer tokens.deinit(allocator);
    var pos: usize = 0;

    while (pos < format_str.len) {
        // Check for escaped text [text] or wildcard [*]
        if (format_str[pos] == '[') {
            const end_pos = std.mem.indexOfScalarPos(u8, format_str, pos + 1, ']') orelse format_str.len;
            if (end_pos > pos + 1) {
                const content = format_str[pos + 1 .. end_pos];
                if (std.mem.eql(u8, content, "*")) {
                    // Wildcard [*]
                    try tokens.append(allocator, .wildcard);
                } else {
                    // Escaped text [text]
                    try tokens.append(allocator, .{ .literal = content });
                }
                pos = end_pos + 1;
                continue;
            }
        }

        // Check for format tokens (longest match first)
        if (matchToken(format_str, pos, "YYYY")) {
            try tokens.append(allocator, .year_full);
            pos += 4;
        } else if (matchToken(format_str, pos, "MMMM")) {
            try tokens.append(allocator, .month_name_long);
            pos += 4;
        } else if (matchToken(format_str, pos, "EEEE")) {
            try tokens.append(allocator, .day_name_long);
            pos += 4;
        } else if (matchToken(format_str, pos, "MMM")) {
            try tokens.append(allocator, .month_name_short);
            pos += 3;
        } else if (matchToken(format_str, pos, "EEE")) {
            try tokens.append(allocator, .day_name_short);
            pos += 3;
        } else if (matchToken(format_str, pos, "MM")) {
            try tokens.append(allocator, .month_full);
            pos += 2;
        } else if (matchToken(format_str, pos, "DD")) {
            try tokens.append(allocator, .day_full);
            pos += 2;
        } else if (matchToken(format_str, pos, "ii")) {
            try tokens.append(allocator, .hour_12_full);
            pos += 2;
        } else if (matchToken(format_str, pos, "hh")) {
            try tokens.append(allocator, .hour_24_full);
            pos += 2;
        } else if (matchToken(format_str, pos, "mm")) {
            try tokens.append(allocator, .minute_full);
            pos += 2;
        } else if (matchToken(format_str, pos, "ss")) {
            try tokens.append(allocator, .second_full);
            pos += 2;
        } else if (matchToken(format_str, pos, "YY")) {
            try tokens.append(allocator, .year_short);
            pos += 2;
        } else if (matchToken(format_str, pos, "EE")) {
            try tokens.append(allocator, .day_name_short);
            pos += 2;
        } else if (matchToken(format_str, pos, "M")) {
            try tokens.append(allocator, .month_short);
            pos += 1;
        } else if (matchToken(format_str, pos, "D")) {
            try tokens.append(allocator, .day_short);
            pos += 1;
        } else if (matchToken(format_str, pos, "i")) {
            try tokens.append(allocator, .hour_12_short);
            pos += 1;
        } else if (matchToken(format_str, pos, "h")) {
            try tokens.append(allocator, .hour_24_short);
            pos += 1;
        } else if (matchToken(format_str, pos, "m")) {
            try tokens.append(allocator, .minute_short);
            pos += 1;
        } else if (matchToken(format_str, pos, "s")) {
            try tokens.append(allocator, .second_short);
            pos += 1;
        } else if (matchToken(format_str, pos, "E")) {
            try tokens.append(allocator, .day_name_short);
            pos += 1;
        } else if (matchToken(format_str, pos, "e")) {
            try tokens.append(allocator, .day_of_week);
            pos += 1;
        } else if (matchToken(format_str, pos, "A")) {
            try tokens.append(allocator, .ampm_upper);
            pos += 1;
        } else if (matchToken(format_str, pos, "a")) {
            try tokens.append(allocator, .ampm_lower);
            pos += 1;
        } else {
            // Literal character - collect consecutive non-token characters
            const start = pos;
            pos += 1;
            while (pos < format_str.len and !isTokenStart(format_str, pos)) {
                pos += 1;
            }
            try tokens.append(allocator, .{ .literal = format_str[start..pos] });
        }
    }

    return tokens;
}

/// Check if position is start of a format token
fn isTokenStart(format_str: []const u8, pos: usize) bool {
    const tokens = [_][]const u8{ "YYYY", "MMMM", "EEEE", "MMM", "EEE", "MM", "DD", "ii", "hh", "mm", "ss", "YY", "EE", "M", "D", "i", "h", "m", "s", "E", "e", "A", "a", "[" };
    for (tokens) |token| {
        if (matchToken(format_str, pos, token)) return true;
    }
    return false;
}

/// Match token at position
fn matchToken(str: []const u8, pos: usize, token: []const u8) bool {
    if (pos + token.len > str.len) return false;
    return std.mem.eql(u8, str[pos .. pos + token.len], token);
}

/// Find end position of number with max digits
fn findNumberEnd(str: []const u8, start: usize, max_digits: usize) usize {
    var pos = start;
    var count: usize = 0;
    while (pos < str.len and count < max_digits) : ({
        pos += 1;
        count += 1;
    }) {
        const c = str[pos];
        if (c < '0' or c > '9') break;
    }
    return pos;
}

/// Parse short month name (Jan, Feb, etc.)
fn parseShortMonthName(str: []const u8) ParseError!i32 {
    if (str.len < 3) return ParseError.InvalidFormat;

    const month_names = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };

    const prefix = str[0..3];
    for (month_names, 0..) |name, i| {
        if (std.ascii.eqlIgnoreCase(prefix, name)) {
            return @as(i32, @intCast(i + 1));
        }
    }

    return ParseError.InvalidDate;
}

/// Parse long month name (January, February, etc.)
fn parseLongMonthName(str: []const u8) ParseError!struct { month: i32, length: usize } {
    const month_names = [_][]const u8{
        "January",   "February", "March",    "April",
        "May",       "June",     "July",     "August",
        "September", "October",  "November", "December",
    };

    for (month_names, 0..) |name, i| {
        if (str.len >= name.len and std.ascii.eqlIgnoreCase(str[0..name.len], name)) {
            return .{ .month = @as(i32, @intCast(i + 1)), .length = name.len };
        }
    }

    return ParseError.InvalidDate;
}

/// Convert timestamp to date components
fn timestampToComponents(timestamp: i64) DateComponents {
    const days_since_epoch = @divTrunc(timestamp, 86400);
    const seconds_today = @mod(timestamp, 86400);

    // Calculate date from days
    var year: i32 = 1970;
    var remaining_days = days_since_epoch;

    // Find year
    while (true) {
        const days_in_year: i64 = if (helpers.isLeapYear(year)) 366 else 365;
        if (remaining_days < days_in_year) break;
        remaining_days -= days_in_year;
        year += 1;
    }

    // Find month and day
    const month_days = [_]i32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const is_leap = helpers.isLeapYear(year);
    var month: i32 = 1;
    var remaining_days_i32 = @as(i32, @intCast(remaining_days));

    while (month <= 12) : (month += 1) {
        var days_in_month = month_days[@as(usize, @intCast(month - 1))];
        if (month == 2 and is_leap) days_in_month = 29;
        if (remaining_days_i32 < days_in_month) break;
        remaining_days_i32 -= days_in_month;
    }

    const day = remaining_days_i32 + 1;

    // Calculate time from seconds
    const hour = @divTrunc(seconds_today, 3600);
    const minute = @divTrunc(@mod(seconds_today, 3600), 60);
    const second = @mod(seconds_today, 60);

    return DateComponents{
        .year = year,
        .month = month,
        .day = day,
        .hour = @as(i32, @intCast(hour)),
        .minute = @as(i32, @intCast(minute)),
        .second = @as(i32, @intCast(second)),
        .is_pm = null,
    };
}

/// Convert date components to Unix timestamp
fn componentsToTimestamp(components: DateComponents) ParseError!i64 {
    const year = components.year orelse return ParseError.InvalidDate;
    const month = components.month orelse return ParseError.InvalidDate;
    const day = components.day orelse return ParseError.InvalidDate;
    const hour = components.hour;
    const minute = components.minute;
    const second = components.second;

    // Validate ranges
    if (year < 1970 or month < 1 or month > 12 or day < 1 or day > 31) {
        return ParseError.OutOfRange;
    }
    if (hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 59) {
        return ParseError.OutOfRange;
    }

    // Validate day against month
    const max_day = helpers.daysInMonth(year, month);
    if (day > max_day) {
        return ParseError.OutOfRange;
    }

    // Calculate days since epoch (1970-01-01)
    var days: i64 = 0;
    var y: i32 = 1970;
    while (y < year) : (y += 1) {
        days += if (helpers.isLeapYear(y)) 366 else 365;
    }

    // Add days for months in the current year
    const month_days = [_]i32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const is_leap = helpers.isLeapYear(year);
    var m: i32 = 1;
    while (m < month) : (m += 1) {
        var days_in_month = month_days[@as(usize, @intCast(m - 1))];
        if (m == 2 and is_leap) {
            days_in_month = 29;
        }
        days += days_in_month;
    }

    // Add days for the current month
    days += @as(i64, @intCast(day - 1));

    // Calculate seconds for the time of day
    const seconds_today = @as(i64, @intCast(hour * 3600 + minute * 60 + second));

    return days * 86400 + seconds_today;
}

/// Auto-detect format and parse (simplified version for common formats)
fn autoDetectAndParse(timestamp_str: []const u8) ParseError!i64 {
    if (timestamp_str.len == 0) return ParseError.InvalidFormat;

    // ISO8601: YYYY-MM-DDTHH:MM:SSZ or YYYY-MM-DDTHH:MM:SS
    if (std.mem.indexOf(u8, timestamp_str, "T")) |t_pos| {
        const time_part_with_z = timestamp_str[t_pos + 1 ..];
        const time_part = if (std.mem.endsWith(u8, time_part_with_z, "Z"))
            time_part_with_z[0 .. time_part_with_z.len - 1]
        else
            time_part_with_z;

        return try parseWithFormat(timestamp_str[0 .. t_pos + 1 + time_part.len], "YYYY-MM-DDThh:mm:ss", 0);
    }

    // Compact datetime: YYYYMMDDHHMMSS
    if (timestamp_str.len == 14 and isAllDigits(timestamp_str)) {
        return try parseWithFormat(timestamp_str, "YYYYMMDDhhmmss", 0);
    }

    // Compact date: YYYYMMDD
    if (timestamp_str.len == 8 and isAllDigits(timestamp_str)) {
        return try parseWithFormat(timestamp_str, "YYYYMMDD", 0);
    }

    // Standard formats with space separator
    if (std.mem.indexOf(u8, timestamp_str, " ")) |_| {
        // Try YYYY-MM-DD hh:mm:ss
        if (std.mem.count(u8, timestamp_str, "-") >= 2) {
            return try parseWithFormat(timestamp_str, "YYYY-MM-DD hh:mm:ss", 0);
        }
        // Try YYYY/MM/DD hh:mm:ss
        if (std.mem.count(u8, timestamp_str, "/") >= 2) {
            return try parseWithFormat(timestamp_str, "YYYY/MM/DD hh:mm:ss", 0);
        }
    }

    // Date only formats
    if (std.mem.count(u8, timestamp_str, "-") == 2) {
        return try parseWithFormat(timestamp_str, "YYYY-MM-DD", 0);
    } else if (std.mem.count(u8, timestamp_str, "/") == 2) {
        return try parseWithFormat(timestamp_str, "YYYY/MM/DD", 0);
    }

    return ParseError.InvalidFormat;
}

/// Check if string contains only digits
fn isAllDigits(str: []const u8) bool {
    for (str) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Parse day name (Monday, Tuesday, etc. or Mon, Tue, etc.)
fn parseDayName(str: []const u8) ParseError!struct { length: usize } {
    const long_names = [_][]const u8{
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    };
    const short_names = [_][]const u8{
        "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun",
    };

    // Try long names first
    for (long_names) |name| {
        if (str.len >= name.len and std.ascii.eqlIgnoreCase(str[0..name.len], name)) {
            return .{ .length = name.len };
        }
    }

    // Try short names
    for (short_names) |name| {
        if (str.len >= name.len and std.ascii.eqlIgnoreCase(str[0..name.len], name)) {
            return .{ .length = name.len };
        }
    }

    return ParseError.InvalidFormat;
}

/// Skip arbitrary text until the next token can be matched
fn skipUntilNextToken(date_str: []const u8, start_pos: usize, next_token: FormatToken) ParseError!usize {
    var pos = start_pos;

    // For literal tokens, search for the literal string
    switch (next_token) {
        .literal => |lit| {
            // Find the literal string
            while (pos < date_str.len) : (pos += 1) {
                if (pos + lit.len <= date_str.len) {
                    if (std.mem.eql(u8, date_str[pos .. pos + lit.len], lit)) {
                        return pos;
                    }
                }
            }
            return ParseError.InvalidFormat;
        },
        .year_full => {
            // Look for 4 consecutive digits
            while (pos + 4 <= date_str.len) : (pos += 1) {
                if (isAllDigits(date_str[pos .. pos + 4])) {
                    return pos;
                }
            }
            return ParseError.InvalidFormat;
        },
        .year_short => {
            // Look for 2 consecutive digits
            while (pos + 2 <= date_str.len) : (pos += 1) {
                if (isAllDigits(date_str[pos .. pos + 2])) {
                    return pos;
                }
            }
            return ParseError.InvalidFormat;
        },
        .month_full, .day_full, .hour_24_full, .hour_12_full, .minute_full, .second_full => {
            // Look for 2 consecutive digits
            while (pos + 2 <= date_str.len) : (pos += 1) {
                if (isAllDigits(date_str[pos .. pos + 2])) {
                    return pos;
                }
            }
            return ParseError.InvalidFormat;
        },
        .month_short, .day_short, .hour_24_short, .hour_12_short, .minute_short, .second_short, .day_of_week => {
            // Look for 1-2 consecutive digits
            while (pos < date_str.len) : (pos += 1) {
                const c = date_str[pos];
                if (c >= '0' and c <= '9') {
                    return pos;
                }
            }
            return ParseError.InvalidFormat;
        },
        .month_name_short => {
            // Look for month abbreviation
            const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
            while (pos + 3 <= date_str.len) : (pos += 1) {
                const substr = date_str[pos .. pos + 3];
                for (names) |name| {
                    if (std.ascii.eqlIgnoreCase(substr, name)) {
                        return pos;
                    }
                }
            }
            return ParseError.InvalidFormat;
        },
        .month_name_long => {
            // Look for full month name
            const names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
            while (pos < date_str.len) : (pos += 1) {
                for (names) |name| {
                    if (pos + name.len <= date_str.len) {
                        if (std.ascii.eqlIgnoreCase(date_str[pos .. pos + name.len], name)) {
                            return pos;
                        }
                    }
                }
            }
            return ParseError.InvalidFormat;
        },
        .day_name_short => {
            // Look for day abbreviation
            const names = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
            while (pos + 3 <= date_str.len) : (pos += 1) {
                const substr = date_str[pos .. pos + 3];
                for (names) |name| {
                    if (std.ascii.eqlIgnoreCase(substr, name)) {
                        return pos;
                    }
                }
            }
            return ParseError.InvalidFormat;
        },
        .day_name_long => {
            // Look for full day name
            const names = [_][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };
            while (pos < date_str.len) : (pos += 1) {
                for (names) |name| {
                    if (pos + name.len <= date_str.len) {
                        if (std.ascii.eqlIgnoreCase(date_str[pos .. pos + name.len], name)) {
                            return pos;
                        }
                    }
                }
            }
            return ParseError.InvalidFormat;
        },
        .ampm_upper, .ampm_lower => {
            // Look for AM/PM
            while (pos + 2 <= date_str.len) : (pos += 1) {
                const substr = date_str[pos .. pos + 2];
                if (std.ascii.eqlIgnoreCase(substr, "AM") or std.ascii.eqlIgnoreCase(substr, "PM")) {
                    return pos;
                }
            }
            return ParseError.InvalidFormat;
        },
        .wildcard => {
            // Wildcard cannot follow wildcard
            return ParseError.InvalidFormat;
        },
    }
}
