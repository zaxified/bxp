const std = @import("std");
const config = @import("config");
const json5_writer = @import("json5_writer.zig");

pub const BrokerStringField = enum {
    data_dir,
    file_pattern_in,
    file_pattern_out,
    xlsx_sheet_name,
    xlsx_sheet_output_suffix,
};

pub const TemplateEdits = struct {
    data_dir: [512]u8 = [_]u8{0} ** 512,
    data_dir_len: usize = 0,
    file_pattern_in: [128]u8 = [_]u8{0} ** 128,
    file_pattern_in_len: usize = 0,
    file_pattern_out: [128]u8 = [_]u8{0} ** 128,
    file_pattern_out_len: usize = 0,
    xlsx_name: [256]u8 = [_]u8{0} ** 256,
    xlsx_name_len: usize = 0,
    xlsx_suffix: [64]u8 = [_]u8{0} ** 64,
    xlsx_suffix_len: usize = 0,

    pub fn load(self: *TemplateEdits, b: *const config.BrokerConfig) void {
        copyInto(&self.data_dir, &self.data_dir_len, b.data_dir);
        copyInto(&self.file_pattern_in, &self.file_pattern_in_len, b.file_pattern_in);
        copyInto(&self.file_pattern_out, &self.file_pattern_out_len, b.file_pattern_out);
        if (b.xlsx_sheet) |xs| {
            copyInto(&self.xlsx_name, &self.xlsx_name_len, xs.name);
            copyInto(&self.xlsx_suffix, &self.xlsx_suffix_len, xs.output_suffix);
        }
    }
};

fn copyInto(dst: []u8, len: *usize, src: []const u8) void {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

pub const AppState = struct {
    gpa: std.mem.Allocator,
    loaded_path: ?[]u8 = null,
    config_owner: ?*config.Config = null,
    template_names: std.ArrayListUnmanaged([]const u8) = .empty,
    selected_template: ?usize = null,
    status: std.ArrayListUnmanaged(u8) = .empty,
    edits: std.ArrayListUnmanaged(TemplateEdits) = .empty,

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
        self.edits.deinit(self.gpa);
        self.edits = .empty;
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

        try self.edits.ensureTotalCapacity(self.gpa, self.template_names.items.len);
        for (self.template_names.items) |name| {
            var e: TemplateEdits = .{};
            if (cfg_ptr.brokers.get(name)) |b| e.load(&b);
            self.edits.appendAssumeCapacity(e);
        }

        try self.setStatusFmt("loaded {s} ({d} templates)", .{ path, self.template_names.items.len });
    }

    /// Replace broker field with `new_value`, reallocating via the config's allocator.
    pub fn updateBrokerString(
        self: *AppState,
        template_idx: usize,
        comptime field: BrokerStringField,
        new_value: []const u8,
    ) !void {
        const cfg = self.config_owner orelse return error.NoConfigLoaded;
        if (template_idx >= self.template_names.items.len) return error.OutOfRange;
        const name = self.template_names.items[template_idx];
        const b_ptr = cfg.brokers.getPtr(name) orelse return error.TemplateNotFound;
        const alloc = cfg._alloc;

        const old_slice: []const u8 = switch (field) {
            .data_dir => b_ptr.data_dir,
            .file_pattern_in => b_ptr.file_pattern_in,
            .file_pattern_out => b_ptr.file_pattern_out,
            .xlsx_sheet_name => if (b_ptr.xlsx_sheet) |xs| xs.name else return error.NoXlsxSheet,
            .xlsx_sheet_output_suffix => if (b_ptr.xlsx_sheet) |xs| xs.output_suffix else return error.NoXlsxSheet,
        };
        if (std.mem.eql(u8, old_slice, new_value)) return;

        const new_slice = try alloc.dupe(u8, new_value);
        alloc.free(old_slice);
        switch (field) {
            .data_dir => b_ptr.data_dir = new_slice,
            .file_pattern_in => b_ptr.file_pattern_in = new_slice,
            .file_pattern_out => b_ptr.file_pattern_out = new_slice,
            .xlsx_sheet_name => b_ptr.xlsx_sheet.?.name = new_slice,
            .xlsx_sheet_output_suffix => b_ptr.xlsx_sheet.?.output_suffix = new_slice,
        }
    }

    pub fn setXlsxHeaderRow(self: *AppState, template_idx: usize, new_value: u32) !void {
        const cfg = self.config_owner orelse return error.NoConfigLoaded;
        if (template_idx >= self.template_names.items.len) return error.OutOfRange;
        const name = self.template_names.items[template_idx];
        const b_ptr = cfg.brokers.getPtr(name) orelse return error.TemplateNotFound;
        if (b_ptr.xlsx_sheet == null) return error.NoXlsxSheet;
        b_ptr.xlsx_sheet.?.header_row = new_value;
    }

    fn setStatusFmt(self: *AppState, comptime fmt: []const u8, args: anytype) !void {
        self.status.clearRetainingCapacity();
        try self.status.writer(self.gpa).print(fmt, args);
    }

    pub fn statusText(self: *const AppState) []const u8 {
        return self.status.items;
    }

    pub fn saveConfigAs(self: *AppState, path: []const u8) !void {
        const cfg = self.config_owner orelse return error.NoConfigLoaded;
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        var buf: [8192]u8 = undefined;
        var fw = f.writer(&buf);
        try json5_writer.writeConfig(cfg, &fw.interface);
        try fw.interface.flush();
        try self.setStatusFmt("saved {s}", .{path});
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
