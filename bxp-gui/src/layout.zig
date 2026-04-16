const std = @import("std");
const dvui = @import("dvui");
const app = @import("app.zig");

const explorer = @import("panels/explorer.zig");
const template_panel = @import("panels/template.zig");
const status_panel = @import("panels/status.zig");

var main_split: f32 = 0.18;
var inner_split: f32 = 0.80;

pub fn render(state: *app.AppState) !void {
    var main = dvui.paned(@src(), .{
        .direction = .horizontal,
        .collapsed_size = 300,
        .split_ratio = &main_split,
    }, .{ .expand = .both, .background = true });
    defer main.deinit();

    if (main.showFirst()) {
        var sidebar = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .min_size_content = .{ .w = 160, .h = 0 },
            .background = true,
        });
        defer sidebar.deinit();
        try explorer.render(state);
    }

    if (main.showSecond()) {
        var inner = dvui.paned(@src(), .{
            .direction = .horizontal,
            .collapsed_size = 300,
            .split_ratio = &inner_split,
        }, .{ .expand = .both });
        defer inner.deinit();

        if (inner.showFirst()) {
            var center = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
            defer center.deinit();
            try template_panel.render(state);
        }

        if (inner.showSecond()) {
            var right = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .both,
                .min_size_content = .{ .w = 180, .h = 0 },
                .background = true,
            });
            defer right.deinit();
            try status_panel.render(state);
        }
    }
}
