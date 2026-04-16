const std = @import("std");
const dvui = @import("dvui");
const config = @import("config");
const app = @import("../app.zig");

pub fn render(state: *app.AppState) !void {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    const selected_idx = state.selected_template orelse {
        dvui.label(@src(), "Select a template from the left panel.", .{}, .{ .margin = .all(16) });
        return;
    };

    const cfg = state.config_owner orelse return;
    if (selected_idx >= state.template_names.items.len) return;

    const name = state.template_names.items[selected_idx];
    const broker = cfg.brokers.get(name) orelse return;
    const edits = &state.edits.items[selected_idx];

    {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font = .theme(.title), .margin = .all(8) });
        tl.addText(name, .{});
        tl.deinit();
    }

    const vmsg = state.validationText(selected_idx);
    if (vmsg.len > 0) {
        var tl = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .style = .err,
            .background = true,
            .margin = .{ .x = 8, .y = 2, .w = 8, .h = 6 },
            .padding = .all(6),
        });
        tl.addText(vmsg, .{});
        tl.deinit();
    }

    try editableRow(state, selected_idx, 0, "data_dir", &edits.data_dir, &edits.data_dir_len, .data_dir);
    try editableRow(state, selected_idx, 1, "file_pattern_in", &edits.file_pattern_in, &edits.file_pattern_in_len, .file_pattern_in);
    try editableRow(state, selected_idx, 2, "file_pattern_out", &edits.file_pattern_out, &edits.file_pattern_out_len, .file_pattern_out);
    kvRow("date_filter_from_filename", if (broker.date_filter_from_filename) "true" else "false");

    if (broker.xlsx_sheet) |xs| {
        sectionHeader("xlsx_sheet");
        try editableRow(state, selected_idx, 10, "name", &edits.xlsx_name, &edits.xlsx_name_len, .xlsx_sheet_name);
        try editableRow(state, selected_idx, 11, "output_suffix", &edits.xlsx_suffix, &edits.xlsx_suffix_len, .xlsx_sheet_output_suffix);
        headerRowRow(state, selected_idx, xs.header_row);
    }

    if (broker.pre_pass) |pp| {
        sectionHeader("pre_pass");
        kvRow("when", pp.when);
        kvRow("key", pp.key);
        var it = pp.values.iterator();
        while (it.next()) |e| kvRow(e.key_ptr.*, e.value_ptr.*);
    }

    if (broker.ticker_map.count() > 0) {
        sectionHeader("ticker_map");
        var it = broker.ticker_map.iterator();
        while (it.next()) |e| kvRow(e.key_ptr.*, e.value_ptr.*);
    }

    sectionHeader("csv_format");
    kvRowChar("csv_delimiter_in", broker.csv_delimiter_in);
    kvRowChar("csv_delimiter_out", broker.csv_delimiter_out);
    kvRowChar("csv_decimal_separator_in", broker.csv_decimal_separator_in);
    kvRowChar("csv_decimal_separator_out", broker.csv_decimal_separator_out);
    kvRowQuote("csv_text_quote_in", broker.csv_text_quote_in);
    kvRowQuote("csv_text_quote_out", broker.csv_text_quote_out);
    kvRow("file_type_in", @tagName(broker.file_type_in));
    kvRow("file_type_out", @tagName(broker.file_type_out));

    sectionHeader("input_schema");
    try schemaTable(state, selected_idx, .input, &edits.input_schema);

    sectionHeader("output_schema");
    try schemaTable(state, selected_idx, .output, &edits.output_schema);

    sectionHeader("row_rules");
    if (broker.row_rules) |rules| {
        if (rules.len == 0) {
            dvui.label(@src(), "(empty)", .{}, .{ .margin = .{ .x = 16, .y = 2, .w = 8, .h = 2 } });
        } else {
            for (rules, 0..) |rule, idx| {
                var tl = dvui.textLayout(@src(), .{}, .{ .id_extra = idx, .expand = .horizontal, .margin = .{ .x = 16, .y = 2, .w = 8, .h = 2 } });
                tl.format("when: {s}  →  {d} row(s)", .{ rule.when, rule.rows.len }, .{});
                tl.deinit();
            }
        }
    } else {
        dvui.label(@src(), "(none)", .{}, .{ .margin = .{ .x = 16, .y = 2, .w = 8, .h = 2 } });
    }
}

const SchemaKind = enum { input, output };

fn schemaTable(
    state: *app.AppState,
    template_idx: usize,
    kind: SchemaKind,
    list: *std.ArrayListUnmanaged(app.SchemaEntry),
) !void {
    var mutated = false;
    var delete_idx: ?usize = null;

    for (list.items, 0..) |*entry, row_i| {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = row_i,
            .expand = .horizontal,
            .margin = .{ .x = 16, .y = 1, .w = 8, .h = 1 },
        });
        defer hbox.deinit();

        var key_te = dvui.textEntry(
            @src(),
            .{ .text = .{ .buffer = &entry.key } },
            .{ .min_size_content = .{ .w = 180, .h = 0 } },
        );
        const key_changed = key_te.text_changed;
        entry.key_len = key_te.getText().len;
        key_te.deinit();

        var val_te = dvui.textEntry(
            @src(),
            .{ .text = .{ .buffer = &entry.val } },
            .{ .expand = .horizontal },
        );
        const val_changed = val_te.text_changed;
        entry.val_len = val_te.getText().len;
        val_te.deinit();

        if (dvui.button(@src(), "×", .{}, .{ .min_size_content = .{ .w = 24, .h = 0 } })) {
            delete_idx = row_i;
        }

        if (key_changed or val_changed) mutated = true;
    }

    if (dvui.button(@src(), "+ Add", .{}, .{ .margin = .{ .x = 16, .y = 2, .w = 8, .h = 2 } })) {
        try list.append(state.gpa, .{});
        mutated = true;
    }

    if (delete_idx) |di| {
        _ = list.orderedRemove(di);
        mutated = true;
    }

    if (mutated) {
        switch (kind) {
            .input => state.commitInputSchema(template_idx) catch |err| {
                std.log.err("commit input_schema: {s}", .{@errorName(err)});
            },
            .output => state.commitOutputSchema(template_idx) catch |err| {
                std.log.err("commit output_schema: {s}", .{@errorName(err)});
            },
        }
    }
}

fn editableRow(
    state: *app.AppState,
    template_idx: usize,
    row_id: usize,
    label: []const u8,
    buf: []u8,
    len_ptr: *usize,
    comptime field: app.BrokerStringField,
) !void {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = row_id, .expand = .horizontal, .margin = .{ .x = 16, .y = 1, .w = 8, .h = 1 } });
    defer hbox.deinit();

    var key_tl = dvui.textLayout(@src(), .{}, .{ .min_size_content = .{ .w = 180, .h = 0 } });
    key_tl.addText(label, .{});
    key_tl.deinit();

    var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = buf } }, .{ .expand = .horizontal });
    const text_changed = te.text_changed;
    const current = te.getText();
    const new_len = current.len;
    te.deinit();

    if (text_changed) {
        len_ptr.* = new_len;
        state.updateBrokerString(template_idx, field, buf[0..new_len]) catch |err| {
            std.log.err("update {s} failed: {s}", .{ label, @errorName(err) });
        };
    }
}

fn headerRowRow(state: *app.AppState, template_idx: usize, current: u32) void {
    _ = state;
    _ = template_idx;
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{current}) catch "?";
    kvRow("header_row", s);
}

fn kvRowChar(key: []const u8, c: u8) void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "'{c}' (0x{x:0>2})", .{ c, c }) catch "?";
    kvRow(key, s);
}

fn kvRowQuote(key: []const u8, c: u8) void {
    const label: []const u8 = switch (c) {
        '"' => "double",
        '\'' => "single",
        0 => "none",
        else => "?",
    };
    kvRow(key, label);
}

fn sectionHeader(title: []const u8) void {
    var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font = .theme(.heading), .margin = .{ .x = 8, .y = 8, .w = 0, .h = 2 } });
    tl.addText(title, .{});
    tl.deinit();
}

fn kvRow(key: []const u8, value: []const u8) void {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 1, .w = 8, .h = 1 } });
    defer hbox.deinit();

    var key_tl = dvui.textLayout(@src(), .{}, .{ .min_size_content = .{ .w = 180, .h = 0 } });
    key_tl.addText(key, .{});
    key_tl.deinit();

    var val_tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
    val_tl.addText(value, .{});
    val_tl.deinit();
}
