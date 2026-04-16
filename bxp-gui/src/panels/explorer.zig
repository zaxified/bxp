const std = @import("std");
const dvui = @import("dvui");
const app = @import("../app.zig");

pub fn render(state: *app.AppState) !void {
    dvui.label(@src(), "Templates", .{}, .{ .font = .theme(.heading), .margin = .all(4) });

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    if (state.template_names.items.len == 0) {
        dvui.label(@src(), "(no config loaded — File → Open)", .{}, .{ .margin = .all(8) });
        return;
    }

    for (state.template_names.items, 0..) |name, i| {
        const selected = state.selected_template == i;
        const valid = state.isValid(i);
        const style: ?dvui.Theme.Style.Name = if (selected) .highlight else if (!valid) .err else null;
        const opts: dvui.Options = .{
            .id_extra = i,
            .expand = .horizontal,
            .margin = .{ .x = 4, .y = 1, .w = 4, .h = 1 },
            .style = style,
        };
        const label_text = if (valid) name else blk: {
            var buf: [128]u8 = undefined;
            break :blk std.fmt.bufPrint(&buf, "⚠ {s}", .{name}) catch name;
        };
        if (dvui.button(@src(), label_text, .{}, opts)) {
            state.selected_template = i;
        }
    }
}
