const std = @import("std");
const dvui = @import("dvui");

const app_state = @import("app.zig");
const layout = @import("layout.zig");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 1280.0, .h = 800.0 },
            .min_size = .{ .w = 800.0, .h = 600.0 },
            .title = "bxp-gui",
            .window_init_options = .{
                .theme = dvui.Theme.builtin.dracula,
            },
        },
    },
    .frameFn = appFrame,
    .initFn = appInit,
    .deinitFn = appDeinit,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_instance.allocator();

var state: app_state.AppState = undefined;

pub fn appInit(win: *dvui.Window) !void {
    _ = win;
    state = app_state.AppState.init(gpa);
}

pub fn appDeinit() void {
    state.deinit();
    _ = gpa_instance.deinit();
}

pub fn appFrame() !dvui.App.Result {
    if (menu()) |res| return res;

    try layout.render(&state);

    return .ok;
}

fn menu() ?dvui.App.Result {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .style = .window, .background = true, .expand = .horizontal });
    defer hbox.deinit();

    var m = dvui.menu(@src(), .horizontal, .{});
    defer m.deinit();

    if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{ .tag = "menu-file" })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "Open...", .{}, .{ .expand = .horizontal }) != null) {
            openConfigDialog();
            m.close();
        }
        if (dvui.menuItemLabel(@src(), "Save As...", .{}, .{ .expand = .horizontal }) != null) {
            saveConfigDialog();
            m.close();
        }
        if (dvui.menuItemLabel(@src(), "Exit", .{}, .{ .expand = .horizontal }) != null) {
            return .close;
        }
    }

    if (dvui.menuItemLabel(@src(), "View", .{ .submenu = true }, .{}) != null) {}

    return null;
}

fn openConfigDialog() void {
    const arena = dvui.currentWindow().arena();
    const filters = [_][]const u8{"*.json"};
    const picked = dvui.dialogNativeFileOpen(arena, .{
        .title = "Open bxp config",
        .filters = &filters,
        .filter_description = "bxp config (*.json)",
    }) catch null;

    const path = picked orelse return;
    state.loadConfig(path) catch |err| {
        std.log.err("failed to load {s}: {s}", .{ path, @errorName(err) });
    };
}

fn saveConfigDialog() void {
    if (state.config_owner == null) {
        std.log.warn("no config loaded — open a file first", .{});
        return;
    }
    const arena = dvui.currentWindow().arena();
    const filters = [_][]const u8{"*.json"};
    const picked = dvui.dialogNativeFileSave(arena, .{
        .title = "Save bxp config as",
        .filters = &filters,
        .filter_description = "bxp config (*.json)",
    }) catch null;

    const path = picked orelse return;
    state.saveConfigAs(path) catch |err| {
        std.log.err("failed to save {s}: {s}", .{ path, @errorName(err) });
    };
}
