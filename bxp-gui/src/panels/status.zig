const std = @import("std");
const dvui = @import("dvui");
const app = @import("../app.zig");

pub fn render(state: *app.AppState) !void {
    dvui.label(@src(), "Status", .{}, .{ .font = .theme(.heading), .margin = .all(4) });

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    const text = state.statusText();
    if (text.len == 0) {
        dvui.label(@src(), "(idle)", .{}, .{ .margin = .all(8) });
    } else {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .margin = .all(8) });
        tl.addText(text, .{});
        tl.deinit();
    }
}
