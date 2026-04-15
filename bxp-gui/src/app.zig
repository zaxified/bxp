const std = @import("std");
const config = @import("config");

pub const AppState = struct {
    gpa: std.mem.Allocator,
    loaded_path: ?[]u8 = null,
    config_owner: ?*config.Config = null,
    template_names: std.ArrayListUnmanaged([]const u8) = .empty,
    selected_template: ?usize = null,
    status: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) AppState {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *AppState) void {
        self.clearConfig();
        self.status.deinit(self.gpa);
    }

    fn clearConfig(self: *AppState) void {
        if (self.loaded_path) |p| self.gpa.free(p);
        self.loaded_path = null;
        self.template_names.deinit(self.gpa);
        self.template_names = .empty;
        self.selected_template = null;
        if (self.config_owner) |cfg| {
            cfg.deinit();
            self.gpa.destroy(cfg);
            self.config_owner = null;
        }
    }

    pub fn loadConfig(self: *AppState, path: []const u8) !void {
        self.clearConfig();

        const cfg_ptr = try self.gpa.create(config.Config);
        errdefer self.gpa.destroy(cfg_ptr);
        cfg_ptr.* = try config.load(self.gpa, path);
        self.config_owner = cfg_ptr;

        self.loaded_path = try self.gpa.dupe(u8, path);

        var it = cfg_ptr.brokers.iterator();
        while (it.next()) |entry| {
            try self.template_names.append(self.gpa, entry.key_ptr.*);
        }
        std.mem.sort([]const u8, self.template_names.items, {}, lessThan);

        try self.setStatusFmt("loaded {s} ({d} templates)", .{ path, self.template_names.items.len });
    }

    fn setStatusFmt(self: *AppState, comptime fmt: []const u8, args: anytype) !void {
        self.status.clearRetainingCapacity();
        try self.status.writer(self.gpa).print(fmt, args);
    }

    pub fn statusText(self: *const AppState) []const u8 {
        return self.status.items;
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
