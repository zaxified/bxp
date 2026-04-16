//! Settings persistence for bxp-gui.
//!
//! Stores recent file paths and last view mode in
//! `$XDG_CONFIG_HOME/bxp-gui/settings.json` (falling back to
//! `$HOME/.config/bxp-gui/settings.json`). Format is plain JSON for easy
//! hand-editing — not the same writer as the bxp config.

const std = @import("std");

const MAX_RECENT: usize = 8;
const SETTINGS_FILENAME: []const u8 = "settings.json";
const APP_DIR: []const u8 = "bxp-gui";

pub const Settings = struct {
    arena: std.heap.ArenaAllocator,
    recent_files: std.ArrayListUnmanaged([]const u8) = .empty,
    last_view_mode: []const u8 = "form",

    pub fn init(gpa: std.mem.Allocator) Settings {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Settings) void {
        self.arena.deinit();
    }

    /// Move/insert `path` at the front of `recent_files`, capped at MAX_RECENT.
    pub fn touchRecent(self: *Settings, path: []const u8) !void {
        const a = self.arena.allocator();
        // Remove existing entry pointing at the same path.
        var i: usize = 0;
        while (i < self.recent_files.items.len) {
            if (std.mem.eql(u8, self.recent_files.items[i], path)) {
                _ = self.recent_files.orderedRemove(i);
                continue;
            }
            i += 1;
        }
        const owned = try a.dupe(u8, path);
        try self.recent_files.insert(a, 0, owned);
        while (self.recent_files.items.len > MAX_RECENT) {
            _ = self.recent_files.pop();
        }
    }

    pub fn setViewMode(self: *Settings, mode: []const u8) !void {
        const a = self.arena.allocator();
        self.last_view_mode = try a.dupe(u8, mode);
    }
};

fn settingsPath(gpa: std.mem.Allocator) ![]u8 {
    const xdg = std.process.getEnvVarOwned(gpa, "XDG_CONFIG_HOME") catch null;
    const base = if (xdg) |v| v else blk: {
        const home = std.process.getEnvVarOwned(gpa, "HOME") catch return error.NoHome;
        defer gpa.free(home);
        break :blk try std.fs.path.join(gpa, &.{ home, ".config" });
    };
    defer gpa.free(base);
    return std.fs.path.join(gpa, &.{ base, APP_DIR, SETTINGS_FILENAME });
}

pub fn load(gpa: std.mem.Allocator) !Settings {
    var s = Settings.init(gpa);
    const a = s.arena.allocator();

    const path = settingsPath(gpa) catch return s;
    defer gpa.free(path);

    const f = std.fs.cwd().openFile(path, .{}) catch return s;
    defer f.close();
    const content = f.readToEndAlloc(a, 1024 * 1024) catch return s;

    var parsed = std.json.parseFromSlice(std.json.Value, a, content, .{}) catch return s;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return s;

    if (root.object.get("last_view_mode")) |v| {
        if (v == .string) s.last_view_mode = try a.dupe(u8, v.string);
    }
    if (root.object.get("recent_files")) |v| {
        if (v == .array) {
            for (v.array.items) |item| {
                if (item == .string) {
                    const owned = try a.dupe(u8, item.string);
                    try s.recent_files.append(a, owned);
                }
            }
        }
    }
    return s;
}

pub fn save(gpa: std.mem.Allocator, s: *const Settings) !void {
    const path = try settingsPath(gpa);
    defer gpa.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();

    var buf: [4096]u8 = undefined;
    var fw = f.writer(&buf);
    const w = &fw.interface;

    try w.writeAll("{\n");
    try w.print("  \"last_view_mode\": \"{s}\",\n", .{s.last_view_mode});
    try w.writeAll("  \"recent_files\": [");
    for (s.recent_files.items, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("\n    ");
        try writeJsonString(w, p);
    }
    if (s.recent_files.items.len > 0) try w.writeAll("\n  ");
    try w.writeAll("]\n");
    try w.writeAll("}\n");
    try w.flush();
}

fn writeJsonString(w: anytype, str: []const u8) !void {
    try w.writeByte('"');
    for (str) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

test "touchRecent dedupes and caps" {
    var s = Settings.init(testing.allocator);
    defer s.deinit();
    try s.touchRecent("/a");
    try s.touchRecent("/b");
    try s.touchRecent("/a"); // moves to front
    try testing.expectEqual(@as(usize, 2), s.recent_files.items.len);
    try testing.expectEqualStrings("/a", s.recent_files.items[0]);
    try testing.expectEqualStrings("/b", s.recent_files.items[1]);

    inline for (0..MAX_RECENT + 3) |i| {
        var buf: [16]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "/p{d}", .{i}) catch unreachable;
        try s.touchRecent(p);
    }
    try testing.expect(s.recent_files.items.len <= MAX_RECENT);
}
