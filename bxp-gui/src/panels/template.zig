const std = @import("std");
const dvui = @import("dvui");
const config = @import("config");
const app = @import("../app.zig");
const highlighter = @import("../expr_editor/highlighter.zig");

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

    // Title
    {
        var tl = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .font = .theme(.title),
            .margin = .{ .x = 12, .y = 10, .w = 12, .h = 4 },
        });
        tl.addText(name, .{});
        tl.deinit();
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
    if (broker.csv_delimiter_in != ',' or broker.csv_delimiter_out != ',' or
        broker.csv_decimal_separator_in != '.' or broker.csv_decimal_separator_out != '.' or
        broker.csv_text_quote_in != '"' or broker.csv_text_quote_out != 0)
    {
        sectionHeader("CSV Format");
        if (broker.csv_delimiter_in != ',') kvRowChar("delimiter_in", broker.csv_delimiter_in);
        if (broker.csv_delimiter_out != ',') kvRowChar("delimiter_out", broker.csv_delimiter_out);
        if (broker.csv_decimal_separator_in != '.') kvRowChar("decimal_sep_in", broker.csv_decimal_separator_in);
        if (broker.csv_decimal_separator_out != '.') kvRowChar("decimal_sep_out", broker.csv_decimal_separator_out);
        if (broker.csv_text_quote_in != '"') kvRowQuote("quote_in", broker.csv_text_quote_in);
        if (broker.csv_text_quote_out != 0) kvRowQuote("quote_out", broker.csv_text_quote_out);
    }

    // ── XLSX Sheet ──
    if (broker.xlsx_sheet) |xs| {
        sectionHeader("XLSX Sheet");
        try editableRow(state, selected_idx, 10, "name", &edits.xlsx_name, &edits.xlsx_name_len, .xlsx_sheet_name);
        try editableRow(state, selected_idx, 11, "output_suffix", &edits.xlsx_suffix, &edits.xlsx_suffix_len, .xlsx_sheet_output_suffix);
        headerRowRow(xs.header_row);
    }

    // ── Ticker Map ──
    if (broker.ticker_map.count() > 0) {
        sectionHeader("Ticker Map");
        var it = broker.ticker_map.iterator();
        while (it.next()) |e| kvRow(e.key_ptr.*, e.value_ptr.*);
    }

    // ── Pre-pass ──
    if (broker.pre_pass) |pp| {
        sectionHeader("Pre-pass");
        exprRow("when", pp.when);
        exprRow("key", pp.key);
        var it = pp.values.iterator();
        while (it.next()) |e| exprRow(e.key_ptr.*, e.value_ptr.*);
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
    if (edits.has_row_rules) {
        try rowRulesTable(state, selected_idx, &edits.row_rules);
    } else {
        dvui.label(@src(), "(none)", .{}, .{ .margin = .{ .x = 20, .y = 4, .w = 8, .h = 4 } });
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

        var val_te = dvui.textEntry(
            @src(),
            .{ .text = .{ .buffer = &entry.val } },
            .{
                .expand = .horizontal,
                .min_size_content = .{ .w = 0, .h = 26 },
                .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
            },
        );
        const val_changed = val_te.text_changed;
        entry.val_len = val_te.getText().len;
        val_te.deinit();
        if (val_changed) mutated = true;

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

fn rowRulesTable(
    state: *app.AppState,
    template_idx: usize,
    list: *std.ArrayListUnmanaged(app.RowRuleEdit),
) !void {
    if (list.items.len == 0) {
        dvui.label(@src(), "(empty)", .{}, .{ .margin = .{ .x = 20, .y = 4, .w = 8, .h = 4 } });
        return;
    }

    var mutated = false;
    for (list.items, 0..) |*entry, row_i| {
        // Rule header with when expression (highlighted)
        {
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = row_i,
                .expand = .horizontal,
                .margin = .{ .x = 20, .y = 4, .w = 12, .h = 0 },
            });
            defer hbox.deinit();

            {
                var lbl = dvui.textLayout(@src(), .{}, .{});
                lbl.format("Rule {d}  ", .{row_i + 1}, .{});
                lbl.deinit();
            }

            if (entry.when_len > 0) {
                var preview = dvui.textLayout(@src(), .{}, .{
                    .expand = .horizontal,
                    .font = .theme(.mono),
                });
                highlighter.addHighlighted(&preview, entry.when[0..entry.when_len]);
                preview.deinit();
            }

            {
                var cnt = dvui.textLayout(@src(), .{}, .{});
                cnt.format("  ({d} rows)", .{entry.rows_count}, .{});
                cnt.deinit();
            }
        }

        // Editable when field
        {
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = row_i + 30000,
                .expand = .horizontal,
                .margin = .{ .x = 36, .y = 0, .w = 12, .h = 2 },
            });
            defer hbox.deinit();

            {
                var lbl = dvui.textLayout(@src(), .{}, .{ .min_size_content = .{ .w = 50, .h = 0 } });
                lbl.addText("when:", .{});
                lbl.deinit();
            }

            var te = dvui.textEntry(
                @src(),
                .{ .text = .{ .buffer = &entry.when } },
                .{
                    .expand = .horizontal,
                    .min_size_content = .{ .w = 0, .h = 26 },
                },
            );
            if (te.text_changed) {
                entry.when_len = te.getText().len;
                mutated = true;
            }
            te.deinit();
        }
    }

    if (mutated) {
        state.commitRowRulesWhen(template_idx) catch |err| {
            std.log.err("commit row_rules: {s}", .{@errorName(err)});
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

fn headerRowRow(current: u32) void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{current}) catch "?";
    kvRow("header_row", s);
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

fn kvRowChar(key: []const u8, c: u8) void {
    var buf: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "'{c}'", .{c}) catch "?";
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
