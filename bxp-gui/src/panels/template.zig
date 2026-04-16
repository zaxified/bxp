const std = @import("std");
const dvui = @import("dvui");
const config = @import("config");
const app = @import("../app.zig");
const highlighter = @import("../expr_editor/highlighter.zig");
const expr_widget = @import("../expr_editor/widget.zig");

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

    // Title + view-mode toggle
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 12, .y = 10, .w = 12, .h = 4 },
        });
        defer hbox.deinit();
        var tl = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .font = .theme(.title),
        });
        tl.addText(name, .{});
        tl.deinit();
        if (dvui.button(@src(), "Debug ▶", .{}, .{})) {
            state.view_mode = .debug;
        }
    }

    // Validation banner
    const vmsg = state.validationText(selected_idx);
    if (vmsg.len > 0) {
        var tl = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .style = .err,
            .background = true,
            .margin = .{ .x = 12, .y = 0, .w = 12, .h = 8 },
            .padding = .all(8),
        });
        tl.addText(vmsg, .{});
        tl.deinit();
    }

    // ── General ──
    sectionHeader("General");
    try editableRow(state, selected_idx, 0, "data_dir", &edits.data_dir, &edits.data_dir_len, .data_dir);
    try editableRow(state, selected_idx, 1, "file_pattern_in", &edits.file_pattern_in, &edits.file_pattern_in_len, .file_pattern_in);
    try editableRow(state, selected_idx, 2, "file_pattern_out", &edits.file_pattern_out, &edits.file_pattern_out_len, .file_pattern_out);
    kvRow("date_filter_from_filename", if (broker.date_filter_from_filename) "true" else "false");
    kvRow("file_type_in", @tagName(broker.file_type_in));
    kvRow("file_type_out", @tagName(broker.file_type_out));

    // ── CSV Format ──
    sectionHeader("CSV Format");
    try csvCharRow(state, selected_idx, 30, "delimiter_in", broker.csv_delimiter_in, .delimiter_in);
    try csvCharRow(state, selected_idx, 31, "delimiter_out", broker.csv_delimiter_out, .delimiter_out);
    try csvCharRow(state, selected_idx, 32, "decimal_sep_in", broker.csv_decimal_separator_in, .decimal_sep_in);
    try csvCharRow(state, selected_idx, 33, "decimal_sep_out", broker.csv_decimal_separator_out, .decimal_sep_out);
    try csvQuoteRow(state, selected_idx, 34, "quote_in", broker.csv_text_quote_in, .text_quote_in);
    try csvQuoteRow(state, selected_idx, 35, "quote_out", broker.csv_text_quote_out, .text_quote_out);

    // ── XLSX Sheet ──
    if (broker.xlsx_sheet != null) {
        sectionHeader("XLSX Sheet");
        try editableRow(state, selected_idx, 10, "name", &edits.xlsx_name, &edits.xlsx_name_len, .xlsx_sheet_name);
        try editableRow(state, selected_idx, 11, "output_suffix", &edits.xlsx_suffix, &edits.xlsx_suffix_len, .xlsx_sheet_output_suffix);
        try headerRowEditableRow(state, selected_idx, &edits.xlsx_header_row_buf, &edits.xlsx_header_row_len);
    }

    // ── Ticker Map ──
    sectionHeader("Ticker Map");
    schemaHeaderRow("Symbol", "Mapped Ticker");
    try tickerMapTable(state, selected_idx, &edits.ticker_map);

    // ── Pre-pass ──
    if (edits.has_pre_pass) {
        sectionHeader("Pre-pass");
        try editableRow(state, selected_idx, 20, "when", &edits.pre_pass_when, &edits.pre_pass_when_len, .pre_pass_when);
        try editableRow(state, selected_idx, 21, "key", &edits.pre_pass_key, &edits.pre_pass_key_len, .pre_pass_key);
        schemaHeaderRow("Field", "Expression");
        try prePassValuesTable(state, selected_idx, &edits.pre_pass_values);
    }

    // ── Input Schema ──
    sectionHeader("Input Schema");
    schemaHeaderRow("Variable", "Expression");
    try schemaTable(state, selected_idx, .input, &edits.input_schema);

    // ── Output Schema ──
    sectionHeader("Output Schema");
    schemaHeaderRow("CSV Header", "Variable / Expression");
    try schemaTable(state, selected_idx, .output, &edits.output_schema);

    // ── Row Rules ──
    sectionHeader("Row Rules");
    try rowRulesTable(state, selected_idx, &edits.row_rules);
    if (dvui.button(@src(), "+ Add Rule", .{}, .{ .margin = .{ .x = 20, .y = 4, .w = 8, .h = 4 } })) {
        state.addRowRule(selected_idx) catch |err| {
            std.log.err("add row rule: {s}", .{@errorName(err)});
        };
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
            .margin = .{ .x = 20, .y = 3, .w = 12, .h = 3 },
        });
        defer hbox.deinit();

        var key_te = dvui.textEntry(
            @src(),
            .{ .text = .{ .buffer = &entry.key } },
            .{ .min_size_content = .{ .w = 160, .h = 26 } },
        );
        const key_changed = key_te.text_changed;
        entry.key_len = key_te.getText().len;
        key_te.deinit();

        const val_res = expr_widget.exprEntry(@src(), &entry.val, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 26 },
            .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
        });
        entry.val_len = val_res.text.len;
        if (val_res.text_changed) mutated = true;

        if (dvui.button(@src(), "x", .{}, .{ .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 } })) {
            delete_idx = row_i;
        }

        if (key_changed) mutated = true;
    }

    if (dvui.button(@src(), "+ Add", .{}, .{ .margin = .{ .x = 20, .y = 4, .w = 8, .h = 4 } })) {
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

fn prePassValuesTable(
    state: *app.AppState,
    template_idx: usize,
    list: *std.ArrayListUnmanaged(app.SchemaEntry),
) !void {
    var mutated = false;
    var delete_idx: ?usize = null;

    for (list.items, 0..) |*entry, row_i| {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = row_i,
            .expand = .horizontal,
            .margin = .{ .x = 20, .y = 3, .w = 12, .h = 3 },
        });
        defer hbox.deinit();

        var key_te = dvui.textEntry(
            @src(),
            .{ .text = .{ .buffer = &entry.key } },
            .{ .min_size_content = .{ .w = 160, .h = 26 } },
        );
        if (key_te.text_changed) mutated = true;
        entry.key_len = key_te.getText().len;
        key_te.deinit();

        const val_res = expr_widget.exprEntry(@src(), &entry.val, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 26 },
            .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
        });
        if (val_res.text_changed) mutated = true;
        entry.val_len = val_res.text.len;

        if (dvui.button(@src(), "x", .{}, .{ .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 } })) {
            delete_idx = row_i;
        }
    }

    if (dvui.button(@src(), "+ Add", .{}, .{ .margin = .{ .x = 20, .y = 4, .w = 8, .h = 4 } })) {
        try list.append(state.gpa, .{});
        mutated = true;
    }

    if (delete_idx) |di| {
        _ = list.orderedRemove(di);
        mutated = true;
    }

    if (mutated) {
        state.commitPrePassValues(template_idx) catch |err| {
            std.log.err("commit pre_pass values: {s}", .{@errorName(err)});
        };
    }
}

fn rowRulesTable(
    state: *app.AppState,
    template_idx: usize,
    list: *std.ArrayListUnmanaged(app.RowRuleEdit),
) !void {
    if (list.items.len == 0) {
        dvui.label(@src(), "(no rules — every row passes through)", .{}, .{
            .margin = .{ .x = 20, .y = 4, .w = 8, .h = 4 },
        });
        return;
    }

    var mutated = false;
    var delete_idx: ?usize = null;

    for (list.items, 0..) |*entry, row_i| {
        // Rule header with when expression (highlighted) + delete button
        {
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = row_i,
                .expand = .horizontal,
                .margin = .{ .x = 20, .y = 6, .w = 12, .h = 0 },
            });
            defer hbox.deinit();

            {
                var lbl = dvui.textLayout(@src(), .{ .break_lines = false }, .{
                    .min_size_content = .{ .w = 70, .h = 0 },
                    .font = .theme(.heading),
                });
                lbl.format("Rule {d}", .{row_i + 1}, .{});
                lbl.deinit();
            }

            if (entry.when_len > 0) {
                var preview = dvui.textLayout(@src(), .{}, .{
                    .expand = .horizontal,
                    .font = .theme(.mono),
                });
                highlighter.addHighlighted(&preview, entry.when[0..entry.when_len]);
                preview.deinit();
            } else {
                var spacer = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                spacer.deinit();
            }

            {
                var cnt = dvui.textLayout(@src(), .{ .break_lines = false }, .{});
                cnt.format("({d} rows)", .{entry.rows_count}, .{});
                cnt.deinit();
            }

            if (dvui.button(@src(), "x", .{}, .{
                .id_extra = row_i,
                .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
            })) {
                delete_idx = row_i;
            }
        }

        // Editable when field
        {
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = row_i + 30000,
                .expand = .horizontal,
                .margin = .{ .x = 36, .y = 0, .w = 12, .h = 4 },
            });
            defer hbox.deinit();

            {
                var lbl = dvui.textLayout(@src(), .{}, .{ .min_size_content = .{ .w = 50, .h = 0 } });
                lbl.addText("when:", .{});
                lbl.deinit();
            }

            const w_res = expr_widget.exprEntry(@src(), &entry.when, .{
                .expand = .horizontal,
                .min_size_content = .{ .w = 0, .h = 26 },
            });
            if (w_res.text_changed) {
                entry.when_len = w_res.text.len;
                mutated = true;
            }
        }
    }

    if (delete_idx) |di| {
        state.deleteRowRule(template_idx, di) catch |err| {
            std.log.err("delete row rule: {s}", .{@errorName(err)});
        };
    }

    if (mutated) {
        state.commitRowRulesWhen(template_idx) catch |err| {
            std.log.err("commit row_rules: {s}", .{@errorName(err)});
        };
    }
}

fn tickerMapTable(
    state: *app.AppState,
    template_idx: usize,
    list: *std.ArrayListUnmanaged(app.TickerEntry),
) !void {
    var mutated = false;
    var delete_idx: ?usize = null;

    for (list.items, 0..) |*entry, row_i| {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = row_i,
            .expand = .horizontal,
            .margin = .{ .x = 20, .y = 3, .w = 12, .h = 3 },
        });
        defer hbox.deinit();

        var key_te = dvui.textEntry(
            @src(),
            .{ .text = .{ .buffer = &entry.key } },
            .{ .min_size_content = .{ .w = 160, .h = 26 } },
        );
        if (key_te.text_changed) mutated = true;
        entry.key_len = key_te.getText().len;
        key_te.deinit();

        var val_te = dvui.textEntry(
            @src(),
            .{ .text = .{ .buffer = &entry.val } },
            .{
                .expand = .horizontal,
                .min_size_content = .{ .w = 0, .h = 26 },
                .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
            },
        );
        if (val_te.text_changed) mutated = true;
        entry.val_len = val_te.getText().len;
        val_te.deinit();

        if (dvui.button(@src(), "x", .{}, .{ .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 } })) {
            delete_idx = row_i;
        }
    }

    if (dvui.button(@src(), "+ Add", .{}, .{ .margin = .{ .x = 20, .y = 4, .w = 8, .h = 4 } })) {
        try list.append(state.gpa, .{});
        mutated = true;
    }

    if (delete_idx) |di| {
        _ = list.orderedRemove(di);
        mutated = true;
    }

    if (mutated) {
        state.commitTickerMap(template_idx) catch |err| {
            std.log.err("commit ticker_map: {s}", .{@errorName(err)});
        };
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
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = row_id,
        .expand = .horizontal,
        .margin = .{ .x = 20, .y = 2, .w = 12, .h = 2 },
    });
    defer hbox.deinit();

    {
        var key_tl = dvui.textLayout(@src(), .{}, .{ .min_size_content = .{ .w = 160, .h = 0 } });
        key_tl.addText(label, .{});
        key_tl.deinit();
    }

    var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = buf } }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 26 },
    });
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

fn headerRowEditableRow(
    state: *app.AppState,
    template_idx: usize,
    buf: *[16]u8,
    len_ptr: *usize,
) !void {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = 12,
        .expand = .horizontal,
        .margin = .{ .x = 20, .y = 2, .w = 12, .h = 2 },
    });
    defer hbox.deinit();

    {
        var key_tl = dvui.textLayout(@src(), .{}, .{ .min_size_content = .{ .w = 160, .h = 0 } });
        key_tl.addText("header_row", .{});
        key_tl.deinit();
    }

    var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = buf } }, .{
        .min_size_content = .{ .w = 100, .h = 26 },
    });
    const text_changed = te.text_changed;
    const current = te.getText();
    te.deinit();

    if (text_changed) {
        len_ptr.* = current.len;
        const parsed = std.fmt.parseInt(u32, current, 10) catch return;
        state.setXlsxHeaderRow(template_idx, parsed) catch |err| {
            std.log.err("update header_row failed: {s}", .{@errorName(err)});
        };
    }
}

fn schemaHeaderRow(left: []const u8, right: []const u8) void {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = 20, .y = 4, .w = 12, .h = 2 },
    });
    defer hbox.deinit();

    {
        var l = dvui.textLayout(@src(), .{}, .{
            .min_size_content = .{ .w = 160, .h = 0 },
            .font = .theme(.heading),
        });
        l.addText(left, .{});
        l.deinit();
    }
    {
        var r = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .font = .theme(.heading),
            .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
        });
        r.addText(right, .{});
        r.deinit();
    }
}

fn sectionHeader(title: []const u8) void {
    _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 12, .y = 8, .w = 12, .h = 0 } });
    var tl = dvui.textLayout(@src(), .{}, .{
        .expand = .horizontal,
        .font = .theme(.heading),
        .margin = .{ .x = 12, .y = 2, .w = 12, .h = 4 },
    });
    tl.addText(title, .{});
    tl.deinit();
}

fn exprRow(label: []const u8, expr: []const u8) void {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = 20, .y = 2, .w = 12, .h = 2 },
    });
    defer hbox.deinit();

    {
        var key_tl = dvui.textLayout(@src(), .{}, .{ .min_size_content = .{ .w = 160, .h = 0 } });
        key_tl.addText(label, .{});
        key_tl.deinit();
    }

    var val_tl = dvui.textLayout(@src(), .{}, .{
        .expand = .horizontal,
        .font = .theme(.mono),
    });
    highlighter.addHighlighted(&val_tl, expr);
    val_tl.deinit();
}

fn kvRow(key: []const u8, value: []const u8) void {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = 20, .y = 2, .w = 12, .h = 2 },
    });
    defer hbox.deinit();

    {
        var key_tl = dvui.textLayout(@src(), .{}, .{ .min_size_content = .{ .w = 160, .h = 0 } });
        key_tl.addText(key, .{});
        key_tl.deinit();
    }

    {
        var val_tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
        val_tl.addText(value, .{});
        val_tl.deinit();
    }
}

fn csvCharRow(
    state: *app.AppState,
    template_idx: usize,
    row_id: usize,
    label: []const u8,
    current: u8,
    field: app.CsvCharField,
) !void {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = row_id,
        .expand = .horizontal,
        .margin = .{ .x = 20, .y = 2, .w = 12, .h = 2 },
    });
    defer hbox.deinit();

    {
        var key_tl = dvui.textLayout(@src(), .{}, .{ .min_size_content = .{ .w = 160, .h = 0 } });
        key_tl.addText(label, .{});
        key_tl.deinit();
    }

    const Buf = struct {
        var bufs: [6][2]u8 = .{.{0, 0}} ** 6;
    };
    const slot: usize = @intFromEnum(field);
    Buf.bufs[slot][0] = current;
    Buf.bufs[slot][1] = 0;

    var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &Buf.bufs[slot] } }, .{
        .min_size_content = .{ .w = 60, .h = 26 },
    });
    const text_changed = te.text_changed;
    const text = te.getText();
    te.deinit();

    if (text_changed and text.len >= 1) {
        state.setCsvChar(template_idx, field, text[0]) catch |err| {
            std.log.err("update {s}: {s}", .{ label, @errorName(err) });
        };
    }
}

fn csvQuoteRow(
    state: *app.AppState,
    template_idx: usize,
    row_id: usize,
    label: []const u8,
    current: u8,
    field: app.CsvCharField,
) !void {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = row_id,
        .expand = .horizontal,
        .margin = .{ .x = 20, .y = 2, .w = 12, .h = 2 },
    });
    defer hbox.deinit();

    {
        var key_tl = dvui.textLayout(@src(), .{}, .{ .min_size_content = .{ .w = 160, .h = 0 } });
        key_tl.addText(label, .{});
        key_tl.deinit();
    }

    const opts = [_][]const u8{ "none", "single", "double" };
    var idx: usize = switch (current) {
        0 => 0,
        '\'' => 1,
        '"' => 2,
        else => 0,
    };
    const initial = idx;
    _ = dvui.dropdown(@src(), &opts, .{ .choice = &idx }, .{}, .{
        .id_extra = row_id,
        .min_size_content = .{ .w = 100, .h = 26 },
    });
    if (idx != initial) {
        const new_ch: u8 = switch (idx) {
            0 => 0,
            1 => '\'',
            2 => '"',
            else => 0,
        };
        state.setCsvChar(template_idx, field, new_ch) catch |err| {
            std.log.err("update {s}: {s}", .{ label, @errorName(err) });
        };
    }
}
