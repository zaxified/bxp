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

    try editableRow(state, selected_idx, 0, "data_dir", &edits.data_dir, &edits.data_dir_len, .data_dir);
    try editableRow(state, selected_idx, 1, "file_pattern_in", &edits.file_pattern_in, &edits.file_pattern_in_len, .file_pattern_in);
    try editableRow(state, selected_idx, 2, "file_pattern_out", &edits.file_pattern_out, &edits.file_pattern_out_len, .file_pattern_out);
    kvRow("date_filter_from_filename", if (broker.date_filter_from_filename) "true" else "false");

    sectionHeader("input_schema");
    {
        var it = broker.input_schema.iterator();
        while (it.next()) |e| kvRow(e.key_ptr.*, e.value_ptr.*);
    }

    sectionHeader("output_schema");
    for (broker.output_schema.items) |col| kvRow(col.header, col.variable);

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
