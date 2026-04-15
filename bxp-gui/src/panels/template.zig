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

    {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font = .theme(.title), .margin = .all(8) });
        tl.addText(name, .{});
        tl.deinit();
    }

    kvRow("data_dir", broker.data_dir);
    kvRow("file_pattern_in", broker.file_pattern_in);
    kvRow("file_pattern_out", broker.file_pattern_out);
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
