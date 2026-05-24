const std = @import("std");
const testing = std.testing;
const sunrise = @import("sunrise");

// ========== Method Chaining Tests ==========

test "DateTime - method chaining with parse and format" {
    const allocator = testing.allocator;

    // Parse -> Add days -> Format
    const dt = try sunrise.DateTime.parse("2024-01-15", .{});
    const result = try dt.addDays(7).format(allocator, "YYYY-MM-DD");
    defer allocator.free(result);

    try testing.expectEqualStrings("2024-01-22", result);
}

test "DateTime - complex method chaining" {
    const allocator = testing.allocator;

    // Parse -> Add months -> Add days -> Subtract days -> Format
    const dt = try sunrise.DateTime.parse("2024-01-15 10:30:45", .{});
    const result = try dt.addMonths(2).addDays(10).subDays(3).format(allocator, "YYYY-MM-DD hh:mm:ss");
    defer allocator.free(result);

    // 2024-01-15 -> 2024-03-15 -> 2024-03-25 -> 2024-03-22
    try testing.expectEqualStrings("2024-03-22 10:30:45", result);
}

test "DateTime - start/end of day chaining" {
    const allocator = testing.allocator;

    const dt = try sunrise.DateTime.parse("2024-01-15 10:30:45", .{});

    // Start of day
    const start_result = try dt.startOfDay().format(allocator, "YYYY-MM-DD hh:mm:ss");
    defer allocator.free(start_result);
    try testing.expectEqualStrings("2024-01-15 00:00:00", start_result);

    // End of day
    const end_result = try dt.endOfDay().format(allocator, "YYYY-MM-DD hh:mm:ss");
    defer allocator.free(end_result);
    try testing.expectEqualStrings("2024-01-15 23:59:59", end_result);
}

test "DateTime - start/end of month chaining" {
    const allocator = testing.allocator;

    const dt = try sunrise.DateTime.parse("2024-01-15", .{});

    // Start of month
    const start_result = try dt.startOfMonth().format(allocator, "YYYY-MM-DD");
    defer allocator.free(start_result);
    try testing.expectEqualStrings("2024-01-01", start_result);

    // End of month
    const end_result = try dt.endOfMonth().format(allocator, "YYYY-MM-DD");
    defer allocator.free(end_result);
    try testing.expectEqualStrings("2024-01-31", end_result);
}

test "DateTime - start/end of year chaining" {
    const allocator = testing.allocator;

    const dt = try sunrise.DateTime.parse("2024-06-15", .{});

    // Start of year
    const start_result = try dt.startOfYear().format(allocator, "YYYY-MM-DD");
    defer allocator.free(start_result);
    try testing.expectEqualStrings("2024-01-01", start_result);

    // End of year
    const end_result = try dt.endOfYear().format(allocator, "YYYY-MM-DD");
    defer allocator.free(end_result);
    try testing.expectEqualStrings("2024-12-31", end_result);
}

test "DateTime - comparison methods" {
    const dt1 = try sunrise.DateTime.parse("2024-01-15", .{});
    const dt2 = try sunrise.DateTime.parse("2024-01-20", .{});
    const dt3 = try sunrise.DateTime.parse("2024-01-15", .{});

    try testing.expect(dt2.isAfter(dt1));
    try testing.expect(dt1.isBefore(dt2));
    try testing.expect(dt1.isEqual(dt3));
    try testing.expect(dt1.isSameDay(dt3));
}

test "DateTime - difference calculations" {
    const dt1 = try sunrise.DateTime.parse("2024-01-15", .{});
    const dt2 = try sunrise.DateTime.parse("2024-01-20", .{});

    const diff_days = dt2.diffInDays(dt1);
    try testing.expectEqual(@as(i64, 5), diff_days);
}

test "DateTime - now and fromTimestamp" {
    const allocator = testing.allocator;

    // fromTimestamp
    const dt1 = sunrise.DateTime.fromTimestamp(1705314645);
    const result1 = try dt1.format(allocator, "YYYY-MM-DD hh:mm:ss");
    defer allocator.free(result1);
    try testing.expectEqualStrings("2024-01-15 10:30:45", result1);

    // now
    const dt2 = sunrise.DateTime.now();
    const timestamp = dt2.toTimestamp();
    try testing.expect(timestamp > 0);
}

test "DateTime - real-world usage example" {
    const allocator = testing.allocator;

    // Parse a date, add 1 month and 5 days, then get the end of that day
    const dt = try sunrise.DateTime.parse("2024-01-15", .{});
    const result = try dt.addMonths(1).addDays(5).endOfDay().format(allocator, "YYYY-MM-DD hh:mm:ss");
    defer allocator.free(result);

    // 2024-01-15 -> 2024-02-15 -> 2024-02-20 -> 2024-02-20 23:59:59
    try testing.expectEqualStrings("2024-02-20 23:59:59", result);
}

test "DateTime - custom format with chaining" {
    const allocator = testing.allocator;

    const dt = try sunrise.DateTime.parse("15/01/2024", .{ .format = "DD/MM/YYYY" });
    const result = try dt.addYears(1).format(allocator, "MMMM DD, YYYY");
    defer allocator.free(result);

    try testing.expectEqualStrings("January 15, 2025", result);
}

test "DateTime - ISO8601 format" {
    const allocator = testing.allocator;

    const dt = try sunrise.DateTime.parse("2024-01-15 10:30:45", .{});
    const result = try dt.formatWithOptions(allocator, .{ .iso8601 = true });
    defer allocator.free(result);

    try testing.expectEqualStrings("2024-01-15T10:30:45Z", result);
}

test "DateTime - parse with auto-detect" {
    const allocator = testing.allocator;

    // ISO8601 with T separator
    const dt1 = try sunrise.DateTime.parse("2024-01-15T10:30:45", .{});
    const result1 = try dt1.format(allocator, "YYYY-MM-DD hh:mm:ss");
    defer allocator.free(result1);
    try testing.expectEqualStrings("2024-01-15 10:30:45", result1);

    // Standard format with space
    const dt2 = try sunrise.DateTime.parse("2024-01-15 10:30:45", .{});
    const result2 = try dt2.format(allocator, "YYYY-MM-DD hh:mm:ss");
    defer allocator.free(result2);
    try testing.expectEqualStrings("2024-01-15 10:30:45", result2);

    // Compact format
    const dt3 = try sunrise.DateTime.parse("20240115", .{});
    const result3 = try dt3.format(allocator, "YYYY-MM-DD");
    defer allocator.free(result3);
    try testing.expectEqualStrings("2024-01-15", result3);
}

test "DateTime - parse with custom format" {
    const allocator = testing.allocator;

    // DD/MM/YYYY format
    const dt1 = try sunrise.DateTime.parse("15/01/2024", .{ .format = "DD/MM/YYYY" });
    const result1 = try dt1.format(allocator, "YYYY-MM-DD");
    defer allocator.free(result1);
    try testing.expectEqualStrings("2024-01-15", result1);

    // MM/DD/YYYY format
    const dt2 = try sunrise.DateTime.parse("01/15/2024", .{ .format = "MM/DD/YYYY" });
    const result2 = try dt2.format(allocator, "YYYY-MM-DD");
    defer allocator.free(result2);
    try testing.expectEqualStrings("2024-01-15", result2);
}

test "DateTime - format with various formats" {
    const allocator = testing.allocator;
    const dt = sunrise.DateTime.fromTimestamp(1705314645); // 2024-01-15 10:30:45

    // YYYY-MM-DD
    {
        const result = try dt.format(allocator, "YYYY-MM-DD");
        defer allocator.free(result);
        try testing.expectEqualStrings("2024-01-15", result);
    }

    // DD/MM/YYYY
    {
        const result = try dt.format(allocator, "DD/MM/YYYY");
        defer allocator.free(result);
        try testing.expectEqualStrings("15/01/2024", result);
    }

    // MMMM DD, YYYY
    {
        const result = try dt.format(allocator, "MMMM DD, YYYY");
        defer allocator.free(result);
        try testing.expectEqualStrings("January 15, 2024", result);
    }

    // MMM DD, YYYY
    {
        const result = try dt.format(allocator, "MMM DD, YYYY");
        defer allocator.free(result);
        try testing.expectEqualStrings("Jan 15, 2024", result);
    }
}

test "DateTime - add operations" {
    const allocator = testing.allocator;
    const dt = try sunrise.DateTime.parse("2024-01-15", .{});

    // Add days
    {
        const result = try dt.addDays(10).format(allocator, "YYYY-MM-DD");
        defer allocator.free(result);
        try testing.expectEqualStrings("2024-01-25", result);
    }

    // Add months
    {
        const result = try dt.addMonths(3).format(allocator, "YYYY-MM-DD");
        defer allocator.free(result);
        try testing.expectEqualStrings("2024-04-15", result);
    }

    // Add years
    {
        const result = try dt.addYears(2).format(allocator, "YYYY-MM-DD");
        defer allocator.free(result);
        try testing.expectEqualStrings("2026-01-15", result);
    }
}

test "DateTime - subtract operations" {
    const allocator = testing.allocator;
    const dt = try sunrise.DateTime.parse("2024-01-15", .{});

    // Subtract days
    {
        const result = try dt.subDays(10).format(allocator, "YYYY-MM-DD");
        defer allocator.free(result);
        try testing.expectEqualStrings("2024-01-05", result);
    }

    // Subtract months
    {
        const result = try dt.subMonths(3).format(allocator, "YYYY-MM-DD");
        defer allocator.free(result);
        try testing.expectEqualStrings("2023-10-15", result);
    }

    // Subtract years
    {
        const result = try dt.subYears(2).format(allocator, "YYYY-MM-DD");
        defer allocator.free(result);
        try testing.expectEqualStrings("2022-01-15", result);
    }
}

test "DateTime - same period comparisons" {
    const dt1 = try sunrise.DateTime.parse("2024-01-15 10:30:45", .{});
    const dt2 = try sunrise.DateTime.parse("2024-01-15 15:20:10", .{});
    const dt3 = try sunrise.DateTime.parse("2024-01-20 10:30:45", .{});

    // Same day
    try testing.expect(dt1.isSameDay(dt2));
    try testing.expect(!dt1.isSameDay(dt3));

    // Same month
    try testing.expect(dt1.isSameMonth(dt3));

    // Same year
    const dt4 = try sunrise.DateTime.parse("2024-06-15", .{});
    try testing.expect(dt1.isSameYear(dt4));
}

test "DateTime - difference calculations for months and years" {
    const dt1 = try sunrise.DateTime.parse("2024-01-15", .{});
    const dt2 = try sunrise.DateTime.parse("2024-06-20", .{});
    const dt3 = try sunrise.DateTime.parse("2026-01-15", .{});

    // Difference in months
    const diff_months = dt2.diffInMonths(dt1);
    try testing.expectEqual(@as(i32, 5), diff_months);

    // Difference in years
    const diff_years = dt3.diffInYears(dt1);
    try testing.expectEqual(@as(i32, 2), diff_years);
}

test "DateTime - edge cases with month boundaries" {
    const allocator = testing.allocator;

    // January 31 + 1 month should be February 28/29
    const dt1 = try sunrise.DateTime.parse("2024-01-31", .{});
    const result1 = try dt1.addMonths(1).format(allocator, "YYYY-MM-DD");
    defer allocator.free(result1);
    try testing.expectEqualStrings("2024-02-29", result1); // 2024 is leap year

    // February 29 + 1 year should be February 28
    const dt2 = try sunrise.DateTime.parse("2024-02-29", .{});
    const result2 = try dt2.addYears(1).format(allocator, "YYYY-MM-DD");
    defer allocator.free(result2);
    try testing.expectEqualStrings("2025-02-28", result2); // 2025 is not leap year
}

test "DateTime - chaining multiple operations" {
    const allocator = testing.allocator;

    const dt = try sunrise.DateTime.parse("2024-01-01", .{});
    const result = try dt
        .addYears(1)
        .addMonths(2)
        .addDays(14)
        .startOfDay()
        .format(allocator, "YYYY-MM-DD hh:mm:ss");
    defer allocator.free(result);

    // 2024-01-01 -> 2025-01-01 -> 2025-03-01 -> 2025-03-15 -> 2025-03-15 00:00:00
    try testing.expectEqualStrings("2025-03-15 00:00:00", result);
}

// ========== Phase 1 Enhanced Format Tests ==========

test "Format - day of week (short)" {
    const allocator = testing.allocator;

    // 2024-01-01 is Monday
    const dt1 = try sunrise.DateTime.parse("2024-01-01", .{});
    const result1 = try dt1.format(allocator, "E");
    defer allocator.free(result1);
    try testing.expectEqualStrings("Mon", result1);

    const result2 = try dt1.format(allocator, "EE");
    defer allocator.free(result2);
    try testing.expectEqualStrings("Mon", result2);

    const result3 = try dt1.format(allocator, "EEE");
    defer allocator.free(result3);
    try testing.expectEqualStrings("Mon", result3);

    // 2024-01-07 is Sunday
    const dt2 = try sunrise.DateTime.parse("2024-01-07", .{});
    const result4 = try dt2.format(allocator, "EEE");
    defer allocator.free(result4);
    try testing.expectEqualStrings("Sun", result4);
}

test "Format - day of week (full)" {
    const allocator = testing.allocator;

    // 2024-01-01 is Monday
    const dt1 = try sunrise.DateTime.parse("2024-01-01", .{});
    const result1 = try dt1.format(allocator, "EEEE");
    defer allocator.free(result1);
    try testing.expectEqualStrings("Monday", result1);

    // 2024-01-06 is Saturday
    const dt2 = try sunrise.DateTime.parse("2024-01-06", .{});
    const result2 = try dt2.format(allocator, "EEEE");
    defer allocator.free(result2);
    try testing.expectEqualStrings("Saturday", result2);
}

test "Format - day of week number" {
    const allocator = testing.allocator;

    // 2024-01-01 is Monday (1)
    const dt1 = try sunrise.DateTime.parse("2024-01-01", .{});
    const result1 = try dt1.format(allocator, "e");
    defer allocator.free(result1);
    try testing.expectEqualStrings("1", result1);

    // 2024-01-07 is Sunday (7)
    const dt2 = try sunrise.DateTime.parse("2024-01-07", .{});
    const result2 = try dt2.format(allocator, "e");
    defer allocator.free(result2);
    try testing.expectEqualStrings("7", result2);
}

test "Format - 12-hour format with AM/PM" {
    const allocator = testing.allocator;

    // 10:30 AM
    const dt1 = try sunrise.DateTime.parse("2024-01-15 10:30:00", .{});
    const result1 = try dt1.format(allocator, "ii:mm A");
    defer allocator.free(result1);
    try testing.expectEqualStrings("10:30 AM", result1);

    const result2 = try dt1.format(allocator, "i:mm a");
    defer allocator.free(result2);
    try testing.expectEqualStrings("10:30 am", result2);

    // 2:15 PM (14:15)
    const dt2 = try sunrise.DateTime.parse("2024-01-15 14:15:00", .{});
    const result3 = try dt2.format(allocator, "ii:mm A");
    defer allocator.free(result3);
    try testing.expectEqualStrings("02:15 PM", result3);

    const result4 = try dt2.format(allocator, "i:mm a");
    defer allocator.free(result4);
    try testing.expectEqualStrings("2:15 pm", result4);

    // 12:00 AM (midnight)
    const dt3 = try sunrise.DateTime.parse("2024-01-15 00:00:00", .{});
    const result5 = try dt3.format(allocator, "ii:mm A");
    defer allocator.free(result5);
    try testing.expectEqualStrings("12:00 AM", result5);

    // 12:00 PM (noon)
    const dt4 = try sunrise.DateTime.parse("2024-01-15 12:00:00", .{});
    const result6 = try dt4.format(allocator, "ii:mm A");
    defer allocator.free(result6);
    try testing.expectEqualStrings("12:00 PM", result6);
}

test "Format - 24-hour format with hh/h" {
    const allocator = testing.allocator;

    const dt1 = try sunrise.DateTime.parse("2024-01-15 09:30:00", .{});
    const result1 = try dt1.format(allocator, "hh:mm:ss");
    defer allocator.free(result1);
    try testing.expectEqualStrings("09:30:00", result1);

    const result2 = try dt1.format(allocator, "h:mm:ss");
    defer allocator.free(result2);
    try testing.expectEqualStrings("9:30:00", result2);

    const dt2 = try sunrise.DateTime.parse("2024-01-15 14:15:00", .{});
    const result3 = try dt2.format(allocator, "hh:mm:ss");
    defer allocator.free(result3);
    try testing.expectEqualStrings("14:15:00", result3);
}

test "Format - escaped text" {
    const allocator = testing.allocator;

    const dt = try sunrise.DateTime.parse("2024-01-15 10:30:00", .{});
    const result1 = try dt.format(allocator, "[Year:] YYYY [Month:] MM");
    defer allocator.free(result1);
    try testing.expectEqualStrings("Year: 2024 Month: 01", result1);

    const result2 = try dt.format(allocator, "YYYY-MM-DD [at] hh:mm");
    defer allocator.free(result2);
    try testing.expectEqualStrings("2024-01-15 at 10:30", result2);

    const result3 = try dt.format(allocator, "[Today is] EEEE, MMMM DD, YYYY");
    defer allocator.free(result3);
    try testing.expectEqualStrings("Today is Monday, January 15, 2024", result3);
}

test "Format - complex format with all tokens" {
    const allocator = testing.allocator;

    // Monday, January 15, 2024 at 2:30 PM
    const dt = try sunrise.DateTime.parse("2024-01-15 14:30:45", .{});
    const result = try dt.format(allocator, "EEEE, MMMM DD, YYYY [at] i:mm:ss A");
    defer allocator.free(result);
    try testing.expectEqualStrings("Monday, January 15, 2024 at 2:30:45 PM", result);
}

test "Parse - day of week (informational)" {
    const allocator = testing.allocator;

    // Day name is informational and doesn't affect parsing
    const dt1 = try sunrise.DateTime.parse("Mon, 2024-01-15", .{ .format = "EEE, YYYY-MM-DD" });
    const result1 = try dt1.format(allocator, "YYYY-MM-DD");
    defer allocator.free(result1);
    try testing.expectEqualStrings("2024-01-15", result1);

    const dt2 = try sunrise.DateTime.parse("Monday, January 15, 2024", .{ .format = "EEEE, MMMM DD, YYYY" });
    const result2 = try dt2.format(allocator, "YYYY-MM-DD");
    defer allocator.free(result2);
    try testing.expectEqualStrings("2024-01-15", result2);
}

test "Parse - 12-hour format with AM/PM" {
    const allocator = testing.allocator;

    // 10:30 AM
    const dt1 = try sunrise.DateTime.parse("10:30 AM", .{ .format = "ii:mm A" });
    const result1 = try dt1.format(allocator, "hh:mm");
    defer allocator.free(result1);
    try testing.expectEqualStrings("10:30", result1);

    // 2:15 PM (should be 14:15)
    const dt2 = try sunrise.DateTime.parse("2:15 pm", .{ .format = "i:mm a" });
    const result2 = try dt2.format(allocator, "hh:mm");
    defer allocator.free(result2);
    try testing.expectEqualStrings("14:15", result2);

    // 12:00 AM (midnight = 00:00)
    const dt3 = try sunrise.DateTime.parse("12:00 AM", .{ .format = "ii:mm A" });
    const result3 = try dt3.format(allocator, "hh:mm");
    defer allocator.free(result3);
    try testing.expectEqualStrings("00:00", result3);

    // 12:00 PM (noon = 12:00)
    const dt4 = try sunrise.DateTime.parse("12:00 PM", .{ .format = "ii:mm A" });
    const result4 = try dt4.format(allocator, "hh:mm");
    defer allocator.free(result4);
    try testing.expectEqualStrings("12:00", result4);

    // 11:59 PM (should be 23:59)
    const dt5 = try sunrise.DateTime.parse("11:59 PM", .{ .format = "ii:mm A" });
    const result5 = try dt5.format(allocator, "hh:mm");
    defer allocator.free(result5);
    try testing.expectEqualStrings("23:59", result5);
}

test "Parse - 24-hour format with hh/h" {
    const allocator = testing.allocator;

    const dt1 = try sunrise.DateTime.parse("09:30:00", .{ .format = "hh:mm:ss" });
    const result1 = try dt1.format(allocator, "hh:mm:ss");
    defer allocator.free(result1);
    try testing.expectEqualStrings("09:30:00", result1);

    const dt2 = try sunrise.DateTime.parse("14:15:00", .{ .format = "h:mm:ss" });
    const result2 = try dt2.format(allocator, "hh:mm:ss");
    defer allocator.free(result2);
    try testing.expectEqualStrings("14:15:00", result2);
}

test "Parse - escaped text" {
    const allocator = testing.allocator;

    const dt1 = try sunrise.DateTime.parse("Year: 2024 Month: 01", .{ .format = "[Year:] YYYY [Month:] MM" });
    const result1 = try dt1.format(allocator, "YYYY-MM");
    defer allocator.free(result1);
    try testing.expectEqualStrings("2024-01", result1);

    const dt2 = try sunrise.DateTime.parse("2024-01-15 at 10:30", .{ .format = "YYYY-MM-DD [at] hh:mm" });
    const result2 = try dt2.format(allocator, "YYYY-MM-DD hh:mm");
    defer allocator.free(result2);
    try testing.expectEqualStrings("2024-01-15 10:30", result2);
}

test "Parse - complex format with multiple tokens" {
    const allocator = testing.allocator;

    const dt = try sunrise.DateTime.parse("Monday, January 15, 2024 at 2:30:45 PM", .{ .format = "EEEE, MMMM DD, YYYY [at] i:mm:ss A" });
    const result = try dt.format(allocator, "YYYY-MM-DD hh:mm:ss");
    defer allocator.free(result);
    try testing.expectEqualStrings("2024-01-15 14:30:45", result);
}

// ========== Wildcard [*] Tests ==========

test "Parse - skip prefix with [*]" {
    const allocator = testing.allocator;

    // Skip "Date: " prefix
    const dt1 = try sunrise.DateTime.parse("Date: 2024-01-15", .{ .format = "[*]YYYY-MM-DD" });
    const result1 = try dt1.format(allocator, "YYYY-MM-DD");
    defer allocator.free(result1);
    try testing.expectEqualStrings("2024-01-15", result1);

    // Skip "Updated: " prefix
    const dt2 = try sunrise.DateTime.parse("Updated: 2024-01-15 10:30:00", .{ .format = "[*]YYYY-MM-DD hh:mm:ss" });
    const result2 = try dt2.format(allocator, "YYYY-MM-DD hh:mm:ss");
    defer allocator.free(result2);
    try testing.expectEqualStrings("2024-01-15 10:30:00", result2);

    // Skip longer prefix
    const dt3 = try sunrise.DateTime.parse("The date is: 2024-01-15", .{ .format = "[*]YYYY-MM-DD" });
    const result3 = try dt3.format(allocator, "YYYY-MM-DD");
    defer allocator.free(result3);
    try testing.expectEqualStrings("2024-01-15", result3);
}

test "Parse - skip suffix with [*]" {
    const allocator = testing.allocator;

    // Skip " (updated)" suffix
    const dt1 = try sunrise.DateTime.parse("2024-01-15 (updated)", .{ .format = "YYYY-MM-DD[*]" });
    const result1 = try dt1.format(allocator, "YYYY-MM-DD");
    defer allocator.free(result1);
    try testing.expectEqualStrings("2024-01-15", result1);

    // Skip " - some note" suffix
    const dt2 = try sunrise.DateTime.parse("2024-01-15 10:30:00 - some note", .{ .format = "YYYY-MM-DD hh:mm:ss[*]" });
    const result2 = try dt2.format(allocator, "YYYY-MM-DD hh:mm:ss");
    defer allocator.free(result2);
    try testing.expectEqualStrings("2024-01-15 10:30:00", result2);
}

test "Parse - skip middle text with [*]" {
    const allocator = testing.allocator;

    // Skip text between year and month
    const dt1 = try sunrise.DateTime.parse("2024-some text-01-15", .{ .format = "YYYY[*]MM-DD" });
    const result1 = try dt1.format(allocator, "YYYY-MM-DD");
    defer allocator.free(result1);
    try testing.expectEqualStrings("2024-01-15", result1);

    // Skip text between date and time
    const dt2 = try sunrise.DateTime.parse("2024-01-15 at 10:30:00", .{ .format = "YYYY-MM-DD[*]hh:mm:ss" });
    const result2 = try dt2.format(allocator, "YYYY-MM-DD hh:mm:ss");
    defer allocator.free(result2);
    try testing.expectEqualStrings("2024-01-15 10:30:00", result2);

    // Skip text between date parts
    const dt3 = try sunrise.DateTime.parse("2024/random text/01/more text/15", .{ .format = "YYYY[*]MM[*]DD" });
    const result3 = try dt3.format(allocator, "YYYY-MM-DD");
    defer allocator.free(result3);
    try testing.expectEqualStrings("2024-01-15", result3);
}

test "Parse - wildcard with month names" {
    const allocator = testing.allocator;

    // Skip prefix before month name
    const dt1 = try sunrise.DateTime.parse("Month: January 15, 2024", .{ .format = "[*]MMMM DD, YYYY" });
    const result1 = try dt1.format(allocator, "YYYY-MM-DD");
    defer allocator.free(result1);
    try testing.expectEqualStrings("2024-01-15", result1);

    // Skip between month and day with clear separator
    const dt2 = try sunrise.DateTime.parse("Jan - 15", .{ .format = "MMM[*]DD" });
    const result2 = try dt2.format(allocator, "YYYY-MM-DD");
    defer allocator.free(result2);
    try testing.expectEqualStrings("1970-01-15", result2); // Year defaults to epoch

    // Skip text between parts
    const dt3 = try sunrise.DateTime.parse("January of 2024", .{ .format = "MMMM[*]YYYY" });
    const result3 = try dt3.format(allocator, "YYYY-MM");
    defer allocator.free(result3);
    try testing.expectEqualStrings("2024-01", result3);
}

test "Parse - wildcard with day names" {
    const allocator = testing.allocator;

    // Skip prefix before day name
    const dt1 = try sunrise.DateTime.parse("Day: Monday, 2024-01-15", .{ .format = "[*]EEEE, YYYY-MM-DD" });
    const result1 = try dt1.format(allocator, "YYYY-MM-DD");
    defer allocator.free(result1);
    try testing.expectEqualStrings("2024-01-15", result1);

    // Skip between day and date
    const dt2 = try sunrise.DateTime.parse("Mon / 2024-01-15", .{ .format = "EEE[*]YYYY-MM-DD" });
    const result2 = try dt2.format(allocator, "YYYY-MM-DD");
    defer allocator.free(result2);
    try testing.expectEqualStrings("2024-01-15", result2);
}

test "Parse - wildcard with time formats" {
    const allocator = testing.allocator;

    // Skip prefix before time
    const dt1 = try sunrise.DateTime.parse("Time: 10:30:45", .{ .format = "[*]hh:mm:ss" });
    const result1 = try dt1.format(allocator, "hh:mm:ss");
    defer allocator.free(result1);
    try testing.expectEqualStrings("10:30:45", result1);

    // Skip text before AM/PM
    const dt2 = try sunrise.DateTime.parse("2:30 in the PM", .{ .format = "i:mm[*]A" });
    const result2 = try dt2.format(allocator, "hh:mm");
    defer allocator.free(result2);
    try testing.expectEqualStrings("14:30", result2);
}

test "Parse - complex wildcard patterns" {
    const allocator = testing.allocator;

    // Real-world example: log format
    const dt1 = try sunrise.DateTime.parse("[INFO] 2024-01-15 10:30:45 - Application started", .{ .format = "[*]YYYY-MM-DD hh:mm:ss[*]" });
    const result1 = try dt1.format(allocator, "YYYY-MM-DD hh:mm:ss");
    defer allocator.free(result1);
    try testing.expectEqualStrings("2024-01-15 10:30:45", result1);

    // Real-world example: email format
    const dt2 = try sunrise.DateTime.parse("Received: Mon, 15 Jan 2024 14:30:00", .{ .format = "[*]EEE, DD MMM YYYY hh:mm:ss" });
    const result2 = try dt2.format(allocator, "YYYY-MM-DD hh:mm:ss");
    defer allocator.free(result2);
    try testing.expectEqualStrings("2024-01-15 14:30:00", result2);
}
