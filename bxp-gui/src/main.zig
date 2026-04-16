const std = @import("std");
const dvui = @import("dvui");
const sdl = @import("sdl-backend");

const app_state = @import("app.zig");
const layout = @import("layout.zig");

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = &appStart },
    .frameFn = appFrame,
    .initFn = appInit,
    .deinitFn = appDeinit,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;

fn appStart() dvui.App.StartOptions {
    _ = sdl.c.SDL_SetHint("SDL_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR", "0");
    return .{
        .size = .{ .w = 1280.0, .h = 800.0 },
        .min_size = .{ .w = 800.0, .h = 600.0 },
        .title = "bxp-gui",
        .window_init_options = .{
            .theme = dvui.Theme.builtin.dracula,
        },
    };
}
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_instance.allocator();

var state: app_state.AppState = undefined;

pub fn appInit(win: *dvui.Window) !void {
    win.max_fps = 30;
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
        const save_label: []const u8 = if (state.loaded_path != null) "Save" else "Save (no file)";
        if (dvui.menuItemLabel(@src(), save_label, .{}, .{ .expand = .horizontal }) != null) {
            saveConfig();
            m.close();
        }
        if (dvui.menuItemLabel(@src(), "Save As...", .{}, .{ .expand = .horizontal }) != null) {
            saveConfigDialog();
            m.close();
        }
        if (state.settings.recent_files.items.len > 0) {
            if (dvui.menuItemLabel(@src(), "Open Recent", .{ .submenu = true }, .{ .expand = .horizontal })) |rr| {
                var rfw = dvui.floatingMenu(@src(), .{ .from = rr }, .{});
                defer rfw.deinit();
                for (state.settings.recent_files.items, 0..) |path, i| {
                    if (dvui.menuItemLabel(@src(), path, .{}, .{ .id_extra = i, .expand = .horizontal }) != null) {
                        state.loadConfig(path) catch |err| {
                            std.log.err("recent load failed: {s} ({s})", .{ path, @errorName(err) });
                        };
                        m.close();
                    }
                }
            }
        }
        if (dvui.menuItemLabel(@src(), "Exit", .{}, .{ .expand = .horizontal }) != null) {
            return .close;
        }
    }

    if (dvui.menuItemLabel(@src(), "Edit", .{ .submenu = true }, .{ .tag = "menu-edit" })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        const undo_label: []const u8 = if (state.canUndo()) "Undo" else "Undo (none)";
        if (dvui.menuItemLabel(@src(), undo_label, .{}, .{ .expand = .horizontal }) != null) {
            state.undo() catch |err| std.log.err("undo: {s}", .{@errorName(err)});
            m.close();
        }
        const redo_label: []const u8 = if (state.canRedo()) "Redo" else "Redo (none)";
        if (dvui.menuItemLabel(@src(), redo_label, .{}, .{ .expand = .horizontal }) != null) {
            state.redo() catch |err| std.log.err("redo: {s}", .{@errorName(err)});
            m.close();
        }
    }

    if (dvui.menuItemLabel(@src(), "Debug", .{ .submenu = true }, .{ .tag = "menu-debug" })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "Start Dry-Run", .{}, .{ .expand = .horizontal }) != null) {
            if (state.selected_template) |idx| {
                state.startSimulation(idx) catch |err| {
                    std.log.err("startSimulation: {s}", .{@errorName(err)});
                };
            }
            m.close();
        }
        if (dvui.menuItemLabel(@src(), "Form view", .{}, .{ .expand = .horizontal }) != null) {
            state.view_mode = .form;
            m.close();
        }
        if (dvui.menuItemLabel(@src(), "Debug view", .{}, .{ .expand = .horizontal }) != null) {
            state.view_mode = .debug;
            m.close();
        }
    }

    if (dvui.menuItemLabel(@src(), "View", .{ .submenu = true }, .{ .tag = "menu-view" })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "DVUI Debug Window", .{}, .{ .expand = .horizontal }) != null) {
            dvui.toggleDebugWindow();
            m.close();
        }
    }

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

fn saveConfig() void {
    const path = state.loaded_path orelse {
        saveConfigDialog();
        return;
    };
    state.saveConfigAs(path) catch |err| {
        std.log.err("failed to save {s}: {s}", .{ path, @errorName(err) });
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
