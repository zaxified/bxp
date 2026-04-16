//! Write a `Config` back out to a JSON5-compatible (valid JSON) file,
//! preserving the canonical key ordering from bxp-cli/CLAUDE.md.
//!
//! MVP scope: pure JSON output — comments are not preserved (plan phase 6).
//! Named `ticker_maps` entries get flattened into each template's `ticker_map`
//! at load time, so the writer emits only inline ticker_map objects.

const std = @import("std");
const config = @import("config");

const INDENT = "  ";

pub fn writeConfig(cfg: *const config.Config, w: anytype) !void {
    try w.writeAll("{\n");
    try w.print("{s}\"conversion_templates\": {{\n", .{INDENT});

    const n = cfg.brokers.count();
    var idx: usize = 0;
    var it = cfg.brokers.iterator();
    while (it.next()) |entry| : (idx += 1) {
        try writeTemplate(entry.key_ptr.*, entry.value_ptr, w);
        if (idx + 1 < n) try w.writeAll(",");
        try w.writeAll("\n");
    }

    try w.print("{s}}}\n", .{INDENT});
    try w.writeAll("}\n");
}

fn writeTemplate(id: []const u8, b: *const config.BrokerConfig, w: anytype) !void {
    try w.print("{s}{s}", .{ INDENT ** 2, "" });
    try writeJsonString(id, w);
    try w.writeAll(": {\n");

    try keyString("data_dir", b.data_dir, w, false);
    try w.writeAll(",\n");
    try keyEnum("file_type_in", @tagName(b.file_type_in), w);
    try w.writeAll(",\n");
    try keyEnum("file_type_out", @tagName(b.file_type_out), w);
    try w.writeAll(",\n");
    try keyString("file_pattern_in", b.file_pattern_in, w, false);
    try w.writeAll(",\n");
    try keyString("file_pattern_out", b.file_pattern_out, w, false);
    try w.writeAll(",\n");
    try keyBool("date_filter_from_filename", b.date_filter_from_filename, w);

    if (b.ticker_map.count() > 0) {
        try w.writeAll(",\n");
        try keyMapString("ticker_map", b.ticker_map, w);
    }

    if (b.xlsx_sheet) |xs| {
        try w.writeAll(",\n");
        try keyXlsxSheet(xs, w);
    }

    if (b.pre_pass) |pp| {
        try w.writeAll(",\n");
        try keyPrePass(pp, w);
    }

    try w.writeAll(",\n");
    try keyInputSchema(b.input_schema, w);

    try w.writeAll(",\n");
    try keyBool("row_rules_debug_missing", b.row_rules_debug_missing, w);

    if (b.row_rules) |rules| {
        try w.writeAll(",\n");
        try keyRowRules(rules, w);
    }

    try w.writeAll(",\n");
    try keyOutputSchema(b.output_schema.items, w);

    try w.writeAll(",\n");
    try keyCsvByte("csv_delimiter_in", b.csv_delimiter_in, w);
    try w.writeAll(",\n");
    try keyCsvByte("csv_delimiter_out", b.csv_delimiter_out, w);
    try w.writeAll(",\n");
    try keyCsvByte("csv_decimal_separator_in", b.csv_decimal_separator_in, w);
    try w.writeAll(",\n");
    try keyCsvByte("csv_decimal_separator_out", b.csv_decimal_separator_out, w);
    try w.writeAll(",\n");
    try keyCsvQuote("csv_text_quote_in", b.csv_text_quote_in, w);
    try w.writeAll(",\n");
    try keyCsvQuote("csv_text_quote_out", b.csv_text_quote_out, w);

    try w.writeAll("\n");
    try w.print("{s}}}", .{INDENT ** 2});
}

fn indent(w: anytype, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeAll(INDENT);
}

fn keyString(name: []const u8, v: []const u8, w: anytype, nested: bool) !void {
    try indent(w, if (nested) 4 else 3);
    try writeJsonString(name, w);
    try w.writeAll(": ");
    try writeJsonString(v, w);
}

fn keyBool(name: []const u8, v: bool, w: anytype) !void {
    try indent(w, 3);
    try writeJsonString(name, w);
    try w.print(": {s}", .{if (v) "true" else "false"});
}

fn keyEnum(name: []const u8, v: []const u8, w: anytype) !void {
    try keyString(name, v, w, false);
}

fn keyMapString(name: []const u8, m: std.StringHashMap([]const u8), w: anytype) !void {
    try indent(w, 3);
    try writeJsonString(name, w);
    try w.writeAll(": {\n");
    const n = m.count();
    var idx: usize = 0;
    var it = m.iterator();
    while (it.next()) |e| : (idx += 1) {
        try indent(w, 4);
        try writeJsonString(e.key_ptr.*, w);
        try w.writeAll(": ");
        try writeJsonString(e.value_ptr.*, w);
        if (idx + 1 < n) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try indent(w, 3);
    try w.writeAll("}");
}

fn keyXlsxSheet(xs: config.XlsxSheet, w: anytype) !void {
    try indent(w, 3);
    try w.writeAll("\"xlsx_sheet\": {\n");
    try indent(w, 4);
    try w.print("\"name\": ", .{});
    try writeJsonString(xs.name, w);
    try w.writeAll(",\n");
    try indent(w, 4);
    try w.print("\"header_row\": {d},\n", .{xs.header_row});
    try indent(w, 4);
    try w.writeAll("\"output_suffix\": ");
    try writeJsonString(xs.output_suffix, w);
    try w.writeAll("\n");
    try indent(w, 3);
    try w.writeAll("}");
}

fn keyPrePass(pp: config.PrePass, w: anytype) !void {
    try indent(w, 3);
    try w.writeAll("\"pre_pass\": {\n");
    try indent(w, 4);
    try w.writeAll("\"when\": ");
    try writeJsonString(pp.when, w);
    try w.writeAll(",\n");
    try indent(w, 4);
    try w.writeAll("\"key\": ");
    try writeJsonString(pp.key, w);
    try w.writeAll(",\n");
    try indent(w, 4);
    try w.writeAll("\"values\": {\n");
    const n = pp.values.count();
    var idx: usize = 0;
    var it = pp.values.iterator();
    while (it.next()) |e| : (idx += 1) {
        try indent(w, 5);
        try writeJsonString(e.key_ptr.*, w);
        try w.writeAll(": ");
        try writeJsonString(e.value_ptr.*, w);
        if (idx + 1 < n) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try indent(w, 4);
    try w.writeAll("}\n");
    try indent(w, 3);
    try w.writeAll("}");
}

fn keyInputSchema(m: std.StringHashMap([]const u8), w: anytype) !void {
    try indent(w, 3);
    try w.writeAll("\"input_schema\": {\n");
    const n = m.count();
    var idx: usize = 0;
    var it = m.iterator();
    while (it.next()) |e| : (idx += 1) {
        try indent(w, 4);
        try writeJsonString(e.key_ptr.*, w);
        try w.writeAll(": ");
        try writeJsonString(e.value_ptr.*, w);
        if (idx + 1 < n) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try indent(w, 3);
    try w.writeAll("}");
}

fn keyRowRules(rules: []const config.RowRule, w: anytype) !void {
    try indent(w, 3);
    try w.writeAll("\"row_rules\": [\n");
    for (rules, 0..) |rule, ri| {
        try indent(w, 4);
        try w.writeAll("{\n");
        try indent(w, 5);
        try w.writeAll("\"when\": ");
        try writeJsonString(rule.when, w);
        try w.writeAll(",\n");
        try indent(w, 5);
        try w.writeAll("\"rows\": [\n");
        for (rule.rows, 0..) |ovr, oi| {
            try indent(w, 6);
            try w.writeAll("{\n");
            const nm = ovr.count();
            var oidx: usize = 0;
            var oit = ovr.iterator();
            while (oit.next()) |e| : (oidx += 1) {
                try indent(w, 7);
                try writeJsonString(e.key_ptr.*, w);
                try w.writeAll(": ");
                try writeJsonString(e.value_ptr.*, w);
                if (oidx + 1 < nm) try w.writeAll(",");
                try w.writeAll("\n");
            }
            try indent(w, 6);
            try w.writeAll("}");
            if (oi + 1 < rule.rows.len) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try indent(w, 5);
        try w.writeAll("]\n");
        try indent(w, 4);
        try w.writeAll("}");
        if (ri + 1 < rules.len) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try indent(w, 3);
    try w.writeAll("]");
}

fn keyOutputSchema(cols: []const config.OutputColumn, w: anytype) !void {
    try indent(w, 3);
    try w.writeAll("\"output_schema\": {\n");
    for (cols, 0..) |col, i| {
        try indent(w, 4);
        try writeJsonString(col.header, w);
        try w.writeAll(": ");
        try writeJsonString(col.variable, w);
        if (i + 1 < cols.len) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try indent(w, 3);
    try w.writeAll("}");
}

fn keyCsvByte(name: []const u8, b: u8, w: anytype) !void {
    try indent(w, 3);
    try writeJsonString(name, w);
    try w.writeAll(": ");
    var buf: [1]u8 = .{b};
    try writeJsonString(&buf, w);
}

fn keyCsvQuote(name: []const u8, b: u8, w: anytype) !void {
    try indent(w, 3);
    try writeJsonString(name, w);
    const s: []const u8 = switch (b) {
        '"' => "double",
        '\'' => "single",
        else => "none",
    };
    try w.writeAll(": ");
    try writeJsonString(s, w);
}

fn writeJsonString(s: []const u8, w: anytype) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

test "roundtrip: write then reload yields equivalent broker fields" {
    const tmp_in = "/tmp/bxp_gui_rt_in.json";
    const tmp_out = "/tmp/bxp_gui_rt_out.json";

    const src =
        \\{
        \\  conversion_templates: {
        \\    demo: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      date_filter_from_filename: false,
        \\      ticker_map: { "BTC": "BTC-USD" },
        \\      input_schema: { "$date": "[Date]", "$ticker": "[Symbol]" },
        \\      row_rules_debug_missing: false,
        \\      output_schema: { "Date": "$date", "Symbol": "$ticker" }
        \\    }
        \\  }
        \\}
    ;

    {
        const f = try std.fs.cwd().createFile(tmp_in, .{});
        defer f.close();
        try f.writeAll(src);
    }

    var cfg = try config.load(testing.allocator, tmp_in);
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 1), cfg.brokers.count());
    const b1 = cfg.brokers.get("demo").?;

    {
        const f = try std.fs.cwd().createFile(tmp_out, .{});
        defer f.close();
        var buf: [4096]u8 = undefined;
        var fw = f.writer(&buf);
        try writeConfig(&cfg, &fw.interface);
        try fw.interface.flush();
    }

    var cfg2 = try config.load(testing.allocator, tmp_out);
    defer cfg2.deinit();

    try testing.expectEqual(@as(usize, 1), cfg2.brokers.count());
    const b2 = cfg2.brokers.get("demo").?;

    try testing.expectEqualStrings(b1.data_dir[b1.data_dir.len - 1 ..], b2.data_dir[b2.data_dir.len - 1 ..]);
    try testing.expectEqualStrings(b1.file_pattern_in, b2.file_pattern_in);
    try testing.expectEqualStrings(b1.file_pattern_out, b2.file_pattern_out);
    try testing.expectEqual(b1.date_filter_from_filename, b2.date_filter_from_filename);
    try testing.expectEqual(b1.input_schema.count(), b2.input_schema.count());
    try testing.expectEqual(b1.output_schema.items.len, b2.output_schema.items.len);
    try testing.expectEqualStrings(b1.ticker_map.get("BTC").?, b2.ticker_map.get("BTC").?);
}
