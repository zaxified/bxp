const std = @import("std");
const helpers = @import("helpers.zig");
const format_mod = @import("format.zig");
const parse_mod = @import("parse.zig");
const add_mod = @import("add.zig");
const subtract_mod = @import("subtract.zig");
const difference_mod = @import("difference.zig");
const startEnd_mod = @import("startEnd.zig");
const compare_mod = @import("compare.zig");

// Re-export types for convenience
pub const ParseError = parse_mod.ParseError;
pub const ParseOptions = parse_mod.ParseOptions;
pub const FormatOptions = format_mod.FormatOptions;

/// DateTime structure for method chaining
pub const DateTime = struct {
    timestamp: i64,

    /// Create a DateTime from a Unix timestamp
    pub fn fromTimestamp(timestamp: i64) DateTime {
        return DateTime{ .timestamp = timestamp };
    }

    /// Create a DateTime from the current time
    pub fn now() DateTime {
        return DateTime{ .timestamp = helpers.now() };
    }

    /// Parse a date string into a DateTime
    pub fn parse(date_str: []const u8, options: parse_mod.ParseOptions) parse_mod.ParseError!DateTime {
        const timestamp = try parse_mod.parse(date_str, options);
        return DateTime{ .timestamp = timestamp };
    }

    /// Get the Unix timestamp
    pub fn toTimestamp(self: DateTime) i64 {
        return self.timestamp;
    }

    // ========== Addition Methods ==========

    /// Add days to the date
    pub fn addDays(self: DateTime, days: i64) DateTime {
        return DateTime{ .timestamp = add_mod.addDays(self.timestamp, days) };
    }

    /// Add months to the date
    pub fn addMonths(self: DateTime, months: i32) DateTime {
        return DateTime{ .timestamp = add_mod.addMonths(self.timestamp, months) };
    }

    /// Add years to the date
    pub fn addYears(self: DateTime, years: i32) DateTime {
        return DateTime{ .timestamp = add_mod.addYears(self.timestamp, years) };
    }

    // ========== Subtraction Methods ==========

    /// Subtract days from the date
    pub fn subDays(self: DateTime, days: i64) DateTime {
        return DateTime{ .timestamp = subtract_mod.subDays(self.timestamp, days) };
    }

    /// Subtract months from the date
    pub fn subMonths(self: DateTime, months: i32) DateTime {
        return DateTime{ .timestamp = subtract_mod.subMonths(self.timestamp, months) };
    }

    /// Subtract years from the date
    pub fn subYears(self: DateTime, years: i32) DateTime {
        return DateTime{ .timestamp = subtract_mod.subYears(self.timestamp, years) };
    }

    // ========== Difference Methods ==========

    /// Calculate difference in days from another DateTime
    pub fn diffInDays(self: DateTime, other: DateTime) i64 {
        return difference_mod.differenceInDays(self.timestamp, other.timestamp);
    }

    /// Calculate difference in months from another DateTime
    pub fn diffInMonths(self: DateTime, other: DateTime) i32 {
        return difference_mod.differenceInMonths(self.timestamp, other.timestamp);
    }

    /// Calculate difference in years from another DateTime
    pub fn diffInYears(self: DateTime, other: DateTime) i32 {
        return difference_mod.differenceInYears(self.timestamp, other.timestamp);
    }

    // ========== Start/End Methods ==========

    /// Get the start of the day (00:00:00)
    pub fn startOfDay(self: DateTime) DateTime {
        return DateTime{ .timestamp = startEnd_mod.startOfDay(self.timestamp) };
    }

    /// Get the end of the day (23:59:59)
    pub fn endOfDay(self: DateTime) DateTime {
        return DateTime{ .timestamp = startEnd_mod.endOfDay(self.timestamp) };
    }

    /// Get the start of the month
    pub fn startOfMonth(self: DateTime) DateTime {
        return DateTime{ .timestamp = startEnd_mod.startOfMonth(self.timestamp) };
    }

    /// Get the end of the month
    pub fn endOfMonth(self: DateTime) DateTime {
        return DateTime{ .timestamp = startEnd_mod.endOfMonth(self.timestamp) };
    }

    /// Get the start of the year
    pub fn startOfYear(self: DateTime) DateTime {
        return DateTime{ .timestamp = startEnd_mod.startOfYear(self.timestamp) };
    }

    /// Get the end of the year
    pub fn endOfYear(self: DateTime) DateTime {
        return DateTime{ .timestamp = startEnd_mod.endOfYear(self.timestamp) };
    }

    // ========== Comparison Methods ==========

    /// Check if this date is after another date
    pub fn isAfter(self: DateTime, other: DateTime) bool {
        return compare_mod.isAfter(self.timestamp, other.timestamp);
    }

    /// Check if this date is before another date
    pub fn isBefore(self: DateTime, other: DateTime) bool {
        return compare_mod.isBefore(self.timestamp, other.timestamp);
    }

    /// Check if this date is equal to another date
    pub fn isEqual(self: DateTime, other: DateTime) bool {
        return compare_mod.isEqual(self.timestamp, other.timestamp);
    }

    /// Check if this date is on the same day as another date
    pub fn isSameDay(self: DateTime, other: DateTime) bool {
        return compare_mod.isSameDay(self.timestamp, other.timestamp);
    }

    /// Check if this date is in the same month as another date
    pub fn isSameMonth(self: DateTime, other: DateTime) bool {
        return compare_mod.isSameMonth(self.timestamp, other.timestamp);
    }

    /// Check if this date is in the same year as another date
    pub fn isSameYear(self: DateTime, other: DateTime) bool {
        return compare_mod.isSameYear(self.timestamp, other.timestamp);
    }

    // ========== Format Methods ==========

    /// Format the DateTime as a string with a format string
    pub fn format(self: DateTime, allocator: std.mem.Allocator, format_str: []const u8) ![]const u8 {
        return try format_mod.format(allocator, self.timestamp, .{ .format = format_str });
    }

    /// Format the DateTime as a string with FormatOptions
    pub fn formatWithOptions(self: DateTime, allocator: std.mem.Allocator, options: format_mod.FormatOptions) ![]const u8 {
        return try format_mod.format(allocator, self.timestamp, options);
    }
};
