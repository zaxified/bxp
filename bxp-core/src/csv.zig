const std = @import("std");

/// Splits one CSV line into its constituent fields.
///
/// quote controls the quoting character (0 = no quoting, '"' = RFC 4180).
/// When quote != 0, fields wrapped in that character may contain the delimiter;
/// doubled quote chars (e.g. "" for quote='"') inside a quoted field are
/// unescaped to a single quote char.
/// Fills buf with slices that point directly into line when no unescaping is
/// needed, or into alloc-owned copies for fields containing an escaped quote.
/// Returns a sub-slice of buf containing only the fields found on the line.
/// buf must be large enough to hold all fields; extra capacity is ignored.
pub fn splitFields(line: []const u8, buf: [][]const u8, delimiter: u8, quote: u8, alloc: std.mem.Allocator) ![][]const u8 {
    var count: usize = 0;
    var pos: usize = 0;
    // Loop condition: pos <= line.len (one past end) lets the outer while
    // reach the `if (pos == line.len) break` sentinel for the trailing-field
    // case, avoiding a separate post-loop append.
    while (count < buf.len and pos <= line.len) {
        if (pos == line.len) break;
        if (quote != 0 and line[pos] == quote) {
            // Quoted field: scan until the closing quote.
            // Track whether any doubled-quote escape sequences were found so we
            // only allocate when actually needed.
            pos += 1;
            const start = pos;
            var has_escaped_quote = false;
            while (pos < line.len) {
                const b = line[pos];
                if (b == quote) {
                    if (pos + 1 < line.len and line[pos + 1] == quote) {
                        has_escaped_quote = true;
                        pos += 2; // Skip escaped quote (e.g. "")
                    } else {
                        break; // Closing quote
                    }
                } else {
                    pos += 1;
                }
            }
            const raw = line[start..pos];
            if (pos < line.len) pos += 1; // Skip closing quote.
            if (pos < line.len and line[pos] == delimiter) pos += 1; // Skip delimiter.

            // Unescape doubled quote → single quote only when needed (avoids
            // allocation in the common case).
            if (has_escaped_quote) {
                buf[count] = try unescapeQuotes(raw, quote, alloc);
            } else {
                buf[count] = raw;
            }
        } else {
            // Unquoted field: scan until the next delimiter.
            const start = pos;
            while (pos < line.len and line[pos] != delimiter) : (pos += 1) {}
            buf[count] = line[start..pos];
            if (pos < line.len) pos += 1; // Skip delimiter.
        }
        count += 1;
    }
    return buf[0..count];
}

/// Splits CSV file content into logical records (RFC 4180 §2 rule 6).
///
/// quote controls the quoting character used in the input file (0 = no quoting,
/// '"' = RFC 4180 double-quote, '\'' = single-quote).  When quote != 0, a \n
/// inside a quoted field does not end the record (multi-line field support).
/// Each returned slice is a complete logical CSV record with \r stripped from
/// line endings; empty records are skipped.
/// Slices point into content — no allocation beyond the list itself.
pub fn splitRecords(content: []const u8, quote: u8, alloc: std.mem.Allocator) !std.array_list.Managed([]const u8) {
    var records = std.array_list.Managed([]const u8).init(alloc);
    var pos: usize = 0;
    var rec_start: usize = 0;
    var in_quotes: bool = false;

    while (pos < content.len) {
        const c = content[pos];
        if (quote != 0 and c == quote) {
            if (in_quotes and pos + 1 < content.len and content[pos + 1] == quote) {
                pos += 2; // escaped quote (e.g. "") — stay in quoted field
                continue;
            }
            in_quotes = !in_quotes;
            pos += 1;
        } else if (c == '\n' and !in_quotes) {
            // End of logical record.
            var rec = content[rec_start..pos];
            if (rec.len > 0 and rec[rec.len - 1] == '\r') rec = rec[0 .. rec.len - 1];
            if (rec.len > 0) try records.append(rec);
            pos += 1;
            rec_start = pos;
        } else {
            pos += 1;
        }
    }
    // Handle last record when file has no trailing newline.
    if (rec_start < content.len) {
        var rec = content[rec_start..];
        if (rec.len > 0 and rec[rec.len - 1] == '\r') rec = rec[0 .. rec.len - 1];
        if (rec.len > 0) try records.append(rec);
    }
    return records;
}

// ============================================================
// Tests
// ============================================================

const t = std.testing;

test "splitFields: empty line yields zero fields" {
    var buf: [8][]const u8 = undefined;
    const fields = try splitFields("", &buf, ',', '"', t.allocator);
    try t.expectEqual(@as(usize, 0), fields.len);
}

test "splitFields: single unquoted field" {
    var buf: [8][]const u8 = undefined;
    const fields = try splitFields("hello", &buf, ',', '"', t.allocator);
    try t.expectEqual(@as(usize, 1), fields.len);
    try t.expectEqualStrings("hello", fields[0]);
}

test "splitFields: three unquoted fields" {
    var buf: [8][]const u8 = undefined;
    const fields = try splitFields("a,b,c", &buf, ',', '"', t.allocator);
    try t.expectEqual(@as(usize, 3), fields.len);
    try t.expectEqualStrings("a", fields[0]);
    try t.expectEqualStrings("b", fields[1]);
    try t.expectEqualStrings("c", fields[2]);
}

test "splitFields: leading empty field" {
    var buf: [8][]const u8 = undefined;
    const fields = try splitFields(",b", &buf, ',', '"', t.allocator);
    try t.expectEqual(@as(usize, 2), fields.len);
    try t.expectEqualStrings("", fields[0]);
    try t.expectEqualStrings("b", fields[1]);
}

test "splitFields: empty field between delimiters" {
    var buf: [8][]const u8 = undefined;
    const fields = try splitFields("a,,b", &buf, ',', '"', t.allocator);
    try t.expectEqual(@as(usize, 3), fields.len);
    try t.expectEqualStrings("a", fields[0]);
    try t.expectEqualStrings("", fields[1]);
    try t.expectEqualStrings("b", fields[2]);
}

test "splitFields: trailing delimiter produces no extra empty field" {
    // After the last field the delimiter is consumed, then pos==len → break.
    // This deviates from strict RFC 4180 (which would yield a trailing "").
    var buf: [8][]const u8 = undefined;
    const fields = try splitFields("a,b,", &buf, ',', '"', t.allocator);
    try t.expectEqual(@as(usize, 2), fields.len);
    try t.expectEqualStrings("a", fields[0]);
    try t.expectEqualStrings("b", fields[1]);
}

test "splitFields: quoted field containing delimiter" {
    var buf: [8][]const u8 = undefined;
    const fields = try splitFields("\"a,b\",c", &buf, ',', '"', t.allocator);
    try t.expectEqual(@as(usize, 2), fields.len);
    try t.expectEqualStrings("a,b", fields[0]);
    try t.expectEqualStrings("c", fields[1]);
}

test "splitFields: quoted field with escaped double-quote" {
    // Doubled quote inside a quoted field (RFC 4180 §2 rule 7): "" → "
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var buf: [8][]const u8 = undefined;
    const fields = try splitFields("\"a\"\"b\"", &buf, ',', '"', arena.allocator());
    try t.expectEqual(@as(usize, 1), fields.len);
    try t.expectEqualStrings("a\"b", fields[0]);
}

test "splitFields: empty quoted field" {
    var buf: [8][]const u8 = undefined;
    const fields = try splitFields("\"\"", &buf, ',', '"', t.allocator);
    try t.expectEqual(@as(usize, 1), fields.len);
    try t.expectEqualStrings("", fields[0]);
}

test "splitFields: quote=0 disables quoting" {
    // With quote=0 the double-quote is plain data; comma still splits.
    var buf: [8][]const u8 = undefined;
    const fields = try splitFields("\"a,b\"", &buf, ',', 0, t.allocator);
    try t.expectEqual(@as(usize, 2), fields.len);
    try t.expectEqualStrings("\"a", fields[0]);
    try t.expectEqualStrings("b\"", fields[1]);
}

test "splitFields: spaces are preserved (trimming is done by Context.field)" {
    var buf: [8][]const u8 = undefined;
    const fields = try splitFields("  a  ,  b  ", &buf, ',', '"', t.allocator);
    try t.expectEqual(@as(usize, 2), fields.len);
    try t.expectEqualStrings("  a  ", fields[0]);
    try t.expectEqualStrings("  b  ", fields[1]);
}

test "splitFields: tab delimiter" {
    var buf: [8][]const u8 = undefined;
    const fields = try splitFields("x\ty\tz", &buf, '\t', 0, t.allocator);
    try t.expectEqual(@as(usize, 3), fields.len);
    try t.expectEqualStrings("x", fields[0]);
    try t.expectEqualStrings("y", fields[1]);
    try t.expectEqualStrings("z", fields[2]);
}

// ============================================================

/// Returns a copy of s with every doubled quote char replaced by a single one.
/// The returned slice is allocated with alloc.
fn unescapeQuotes(s: []const u8, quote: u8, alloc: std.mem.Allocator) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    try out.ensureTotalCapacity(s.len);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == quote and i + 1 < s.len and s[i + 1] == quote) {
            try out.append(quote);
            i += 2;
        } else {
            try out.append(s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice();
}
