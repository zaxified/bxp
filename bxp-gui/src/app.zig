const std = @import("std");
const config = @import("config");
const json5_writer = @import("json5_writer.zig");

pub const CsvCharField = enum {
    delimiter_in,
    delimiter_out,
    decimal_sep_in,
    decimal_sep_out,
    text_quote_in,
    text_quote_out,
};

pub const BrokerStringField = enum {
    data_dir,
    file_pattern_in,
    file_pattern_out,
    xlsx_sheet_name,
    xlsx_sheet_output_suffix,
    pre_pass_when,
    pre_pass_key,
};

pub const SchemaEntry = struct {
    key: [64]u8 = [_]u8{0} ** 64,
    key_len: usize = 0,
    val: [512]u8 = [_]u8{0} ** 512,
    val_len: usize = 0,

    pub fn set(self: *SchemaEntry, k: []const u8, v: []const u8) void {
        copyInto(&self.key, &self.key_len, k);
        copyInto(&self.val, &self.val_len, v);
    }

    pub fn keyText(self: *const SchemaEntry) []const u8 {
        return self.key[0..self.key_len];
    }

    pub fn valText(self: *const SchemaEntry) []const u8 {
        return self.val[0..self.val_len];
    }
};

pub const RowRuleEdit = struct {
    when: [512]u8 = [_]u8{0} ** 512,
    when_len: usize = 0,
    rows_count: usize = 0,

    pub fn set(self: *RowRuleEdit, rule: config.RowRule) void {
        copyInto(&self.when, &self.when_len, rule.when);
        self.rows_count = rule.rows.len;
    }

    pub fn whenText(self: *const RowRuleEdit) []const u8 {
        return self.when[0..self.when_len];
    }
};

pub const TickerEntry = struct {
    key: [64]u8 = [_]u8{0} ** 64,
    key_len: usize = 0,
    val: [64]u8 = [_]u8{0} ** 64,
    val_len: usize = 0,

    pub fn set(self: *TickerEntry, k: []const u8, v: []const u8) void {
        copyInto(&self.key, &self.key_len, k);
        copyInto(&self.val, &self.val_len, v);
    }

    pub fn keyText(self: *const TickerEntry) []const u8 {
        return self.key[0..self.key_len];
    }

    pub fn valText(self: *const TickerEntry) []const u8 {
        return self.val[0..self.val_len];
    }
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
    input_schema: std.ArrayListUnmanaged(SchemaEntry) = .empty,
    output_schema: std.ArrayListUnmanaged(SchemaEntry) = .empty,
    row_rules: std.ArrayListUnmanaged(RowRuleEdit) = .empty,
    has_row_rules: bool = false,
    ticker_map: std.ArrayListUnmanaged(TickerEntry) = .empty,
    xlsx_header_row_buf: [16]u8 = [_]u8{0} ** 16,
    xlsx_header_row_len: usize = 0,
    has_pre_pass: bool = false,
    pre_pass_when: [512]u8 = [_]u8{0} ** 512,
    pre_pass_when_len: usize = 0,
    pre_pass_key: [512]u8 = [_]u8{0} ** 512,
    pre_pass_key_len: usize = 0,
    pre_pass_values: std.ArrayListUnmanaged(SchemaEntry) = .empty,

    pub fn load(self: *TemplateEdits, gpa: std.mem.Allocator, b: *const config.BrokerConfig) !void {
        copyInto(&self.data_dir, &self.data_dir_len, b.data_dir);
        copyInto(&self.file_pattern_in, &self.file_pattern_in_len, b.file_pattern_in);
        copyInto(&self.file_pattern_out, &self.file_pattern_out_len, b.file_pattern_out);
        if (b.xlsx_sheet) |xs| {
            copyInto(&self.xlsx_name, &self.xlsx_name_len, xs.name);
            copyInto(&self.xlsx_suffix, &self.xlsx_suffix_len, xs.output_suffix);
            const written = std.fmt.bufPrint(&self.xlsx_header_row_buf, "{d}", .{xs.header_row}) catch "";
            self.xlsx_header_row_len = written.len;
        }

        {
            var tit = b.ticker_map.iterator();
            while (tit.next()) |e| {
                var te: TickerEntry = .{};
                te.set(e.key_ptr.*, e.value_ptr.*);
                try self.ticker_map.append(gpa, te);
            }
        }

        {
            var it = b.input_schema.iterator();
            while (it.next()) |e| {
                var se: SchemaEntry = .{};
                se.set(e.key_ptr.*, e.value_ptr.*);
                try self.input_schema.append(gpa, se);
            }
            std.mem.sort(SchemaEntry, self.input_schema.items, {}, schemaLess);
        }
        for (b.output_schema.items) |col| {
            var se: SchemaEntry = .{};
            se.set(col.header, col.variable);
            try self.output_schema.append(gpa, se);
        }
        if (b.pre_pass) |pp| {
            self.has_pre_pass = true;
            copyInto(&self.pre_pass_when, &self.pre_pass_when_len, pp.when);
            copyInto(&self.pre_pass_key, &self.pre_pass_key_len, pp.key);
            var pit = pp.values.iterator();
            while (pit.next()) |e| {
                var se: SchemaEntry = .{};
                se.set(e.key_ptr.*, e.value_ptr.*);
                try self.pre_pass_values.append(gpa, se);
            }
            std.mem.sort(SchemaEntry, self.pre_pass_values.items, {}, schemaLess);
        }
        if (b.row_rules) |rules| {
            self.has_row_rules = true;
            for (rules) |rule| {
                var rre: RowRuleEdit = .{};
                rre.set(rule);
                try self.row_rules.append(gpa, rre);
            }
        }
    }

    pub fn deinit(self: *TemplateEdits, gpa: std.mem.Allocator) void {
        self.input_schema.deinit(gpa);
        self.output_schema.deinit(gpa);
        self.row_rules.deinit(gpa);
        self.ticker_map.deinit(gpa);
        self.pre_pass_values.deinit(gpa);
    }
};

fn schemaLess(_: void, a: SchemaEntry, b: SchemaEntry) bool {
    return std.mem.lessThan(u8, a.keyText(), b.keyText());
}

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
    validation: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)) = .empty,

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
        for (self.edits.items) |*e| e.deinit(self.gpa);
        self.edits.deinit(self.gpa);
        self.edits = .empty;
        for (self.validation.items) |*v| v.deinit(self.gpa);
        self.validation.deinit(self.gpa);
        self.validation = .empty;
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
        try self.validation.ensureTotalCapacity(self.gpa, self.template_names.items.len);
        for (self.template_names.items) |name| {
            var e: TemplateEdits = .{};
            if (cfg_ptr.brokers.get(name)) |b| try e.load(self.gpa, &b);
            self.edits.appendAssumeCapacity(e);
            self.validation.appendAssumeCapacity(.empty);
        }
        try self.revalidateAll();

        try self.setStatusFmt("loaded {s} ({d} templates)", .{ path, self.template_names.items.len });
    }

    pub fn revalidateAll(self: *AppState) !void {
        const cfg = self.config_owner orelse return;
        const cfg_path = self.loaded_path orelse "bxp.json";
        for (self.template_names.items, 0..) |name, i| {
            try self.revalidateOne(cfg, cfg_path, name, i);
        }
    }

    pub fn revalidateTemplate(self: *AppState, template_idx: usize) !void {
        const cfg = self.config_owner orelse return;
        if (template_idx >= self.template_names.items.len) return;
        const cfg_path = self.loaded_path orelse "bxp.json";
        const name = self.template_names.items[template_idx];
        try self.revalidateOne(cfg, cfg_path, name, template_idx);
    }

    fn revalidateOne(self: *AppState, cfg: *config.Config, cfg_path: []const u8, name: []const u8, idx: usize) !void {
        const b = cfg.brokers.get(name) orelse return;
        var msg = &self.validation.items[idx];
        msg.clearRetainingCapacity();
        var aw = std.Io.Writer.Allocating.fromArrayList(self.gpa, msg);
        defer msg.* = aw.toArrayList();
        b.validate(name, cfg_path, &aw.writer) catch {};
    }

    pub fn validationText(self: *const AppState, template_idx: usize) []const u8 {
        if (template_idx >= self.validation.items.len) return "";
        return self.validation.items[template_idx].items;
    }

    pub fn isValid(self: *const AppState, template_idx: usize) bool {
        return self.validationText(template_idx).len == 0;
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
            .pre_pass_when => if (b_ptr.pre_pass) |pp| pp.when else return error.NoPrePass,
            .pre_pass_key => if (b_ptr.pre_pass) |pp| pp.key else return error.NoPrePass,
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
            .pre_pass_when => b_ptr.pre_pass.?.when = new_slice,
            .pre_pass_key => b_ptr.pre_pass.?.key = new_slice,
        }
        self.revalidateTemplate(template_idx) catch {};
    }

    /// Rebuild broker.pre_pass.values from edits, freeing old entries via cfg._alloc.
    pub fn commitPrePassValues(self: *AppState, template_idx: usize) !void {
        const cfg = self.config_owner orelse return error.NoConfigLoaded;
        if (template_idx >= self.template_names.items.len) return error.OutOfRange;
        const name = self.template_names.items[template_idx];
        const b_ptr = cfg.brokers.getPtr(name) orelse return error.TemplateNotFound;
        const alloc = cfg._alloc;
        if (b_ptr.pre_pass == null) return error.NoPrePass;

        var values = &b_ptr.pre_pass.?.values;
        var it = values.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        values.clearRetainingCapacity();

        for (self.edits.items[template_idx].pre_pass_values.items) |se| {
            const k = se.keyText();
            if (k.len == 0) continue;
            const dk = try alloc.dupe(u8, k);
            const dv = try alloc.dupe(u8, se.valText());
            try values.put(dk, dv);
        }
        self.revalidateTemplate(template_idx) catch {};
    }

    /// Rebuild broker.input_schema from edits, freeing old entries via cfg._alloc.
    pub fn commitInputSchema(self: *AppState, template_idx: usize) !void {
        const cfg = self.config_owner orelse return error.NoConfigLoaded;
        if (template_idx >= self.template_names.items.len) return error.OutOfRange;
        const name = self.template_names.items[template_idx];
        const b_ptr = cfg.brokers.getPtr(name) orelse return error.TemplateNotFound;
        const alloc = cfg._alloc;

        var it = b_ptr.input_schema.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        b_ptr.input_schema.clearRetainingCapacity();

        for (self.edits.items[template_idx].input_schema.items) |se| {
            const k = se.keyText();
            if (k.len == 0) continue;
            const dk = try alloc.dupe(u8, k);
            const dv = try alloc.dupe(u8, se.valText());
            try b_ptr.input_schema.put(dk, dv);
        }

        self.revalidateTemplate(template_idx) catch {};
    }

    /// Rebuild broker.output_schema from edits, freeing old entries via cfg._alloc.
    pub fn commitOutputSchema(self: *AppState, template_idx: usize) !void {
        const cfg = self.config_owner orelse return error.NoConfigLoaded;
        if (template_idx >= self.template_names.items.len) return error.OutOfRange;
        const name = self.template_names.items[template_idx];
        const b_ptr = cfg.brokers.getPtr(name) orelse return error.TemplateNotFound;
        const alloc = cfg._alloc;

        for (b_ptr.output_schema.items) |col| {
            alloc.free(col.header);
            alloc.free(col.variable);
        }
        b_ptr.output_schema.clearRetainingCapacity();

        for (self.edits.items[template_idx].output_schema.items) |se| {
            const k = se.keyText();
            if (k.len == 0) continue;
            const dk = try alloc.dupe(u8, k);
            const dv = try alloc.dupe(u8, se.valText());
            try b_ptr.output_schema.append(.{ .header = dk, .variable = dv });
        }

        self.revalidateTemplate(template_idx) catch {};
    }

    /// Update only the `when` expressions for existing row_rules.
    pub fn commitRowRulesWhen(self: *AppState, template_idx: usize) !void {
        const cfg = self.config_owner orelse return error.NoConfigLoaded;
        if (template_idx >= self.template_names.items.len) return error.OutOfRange;
        const name = self.template_names.items[template_idx];
        const b_ptr = cfg.brokers.getPtr(name) orelse return error.TemplateNotFound;
        const alloc = cfg._alloc;
        const rules = b_ptr.row_rules orelse return;
        const edits_rr = self.edits.items[template_idx].row_rules.items;

        for (rules, 0..) |*rule, i| {
            if (i >= edits_rr.len) break;
            const new_when = edits_rr[i].whenText();
            if (!std.mem.eql(u8, rule.when, new_when)) {
                alloc.free(rule.when);
                rule.when = try alloc.dupe(u8, new_when);
            }
        }
        self.revalidateTemplate(template_idx) catch {};
    }

    /// Rebuild broker.ticker_map from edits, freeing old entries via cfg._alloc.
    pub fn commitTickerMap(self: *AppState, template_idx: usize) !void {
        const cfg = self.config_owner orelse return error.NoConfigLoaded;
        if (template_idx >= self.template_names.items.len) return error.OutOfRange;
        const name = self.template_names.items[template_idx];
        const b_ptr = cfg.brokers.getPtr(name) orelse return error.TemplateNotFound;
        const alloc = cfg._alloc;

        var it = b_ptr.ticker_map.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        b_ptr.ticker_map.clearRetainingCapacity();

        for (self.edits.items[template_idx].ticker_map.items) |te| {
            const k = te.keyText();
            if (k.len == 0) continue;
            const dk = try alloc.dupe(u8, k);
            const dv = try alloc.dupe(u8, te.valText());
            try b_ptr.ticker_map.put(dk, dv);
        }

        self.revalidateTemplate(template_idx) catch {};
    }

    /// Append an empty row rule.
    pub fn addRowRule(self: *AppState, template_idx: usize) !void {
        const cfg = self.config_owner orelse return error.NoConfigLoaded;
        if (template_idx >= self.template_names.items.len) return error.OutOfRange;
        const name = self.template_names.items[template_idx];
        const b_ptr = cfg.brokers.getPtr(name) orelse return error.TemplateNotFound;
        const alloc = cfg._alloc;

        const old_rules = b_ptr.row_rules orelse &[_]config.RowRule{};
        var new_rules = try alloc.alloc(config.RowRule, old_rules.len + 1);
        @memcpy(new_rules[0..old_rules.len], old_rules);
        new_rules[old_rules.len] = .{
            .when = try alloc.dupe(u8, ""),
            .rows = try alloc.alloc(config.RowOverride, 0),
        };
        if (b_ptr.row_rules) |r| alloc.free(r);
        b_ptr.row_rules = new_rules;

        try self.edits.items[template_idx].row_rules.append(self.gpa, .{});
        self.edits.items[template_idx].has_row_rules = true;
        self.revalidateTemplate(template_idx) catch {};
    }

    /// Remove the row rule at `rule_idx`.
    pub fn deleteRowRule(self: *AppState, template_idx: usize, rule_idx: usize) !void {
        const cfg = self.config_owner orelse return error.NoConfigLoaded;
        if (template_idx >= self.template_names.items.len) return error.OutOfRange;
        const name = self.template_names.items[template_idx];
        const b_ptr = cfg.brokers.getPtr(name) orelse return error.TemplateNotFound;
        const alloc = cfg._alloc;

        const rules = b_ptr.row_rules orelse return;
        if (rule_idx >= rules.len) return;

        const r = rules[rule_idx];
        alloc.free(r.when);
        for (r.rows) |*ro| {
            var ovit = ro.iterator();
            while (ovit.next()) |e| {
                alloc.free(e.key_ptr.*);
                alloc.free(e.value_ptr.*);
            }
            ro.deinit();
        }
        alloc.free(r.rows);

        if (rules.len == 1) {
            alloc.free(rules);
            b_ptr.row_rules = null;
            self.edits.items[template_idx].has_row_rules = false;
        } else {
            var new_rules = try alloc.alloc(config.RowRule, rules.len - 1);
            @memcpy(new_rules[0..rule_idx], rules[0..rule_idx]);
            @memcpy(new_rules[rule_idx..], rules[rule_idx + 1 ..]);
            alloc.free(rules);
            b_ptr.row_rules = new_rules;
        }

        _ = self.edits.items[template_idx].row_rules.orderedRemove(rule_idx);
        self.revalidateTemplate(template_idx) catch {};
    }

    pub fn setCsvChar(self: *AppState, template_idx: usize, field: CsvCharField, new_value: u8) !void {
        const cfg = self.config_owner orelse return error.NoConfigLoaded;
        if (template_idx >= self.template_names.items.len) return error.OutOfRange;
        const name = self.template_names.items[template_idx];
        const b_ptr = cfg.brokers.getPtr(name) orelse return error.TemplateNotFound;
        switch (field) {
            .delimiter_in => b_ptr.csv_delimiter_in = new_value,
            .delimiter_out => b_ptr.csv_delimiter_out = new_value,
            .decimal_sep_in => b_ptr.csv_decimal_separator_in = new_value,
            .decimal_sep_out => b_ptr.csv_decimal_separator_out = new_value,
            .text_quote_in => b_ptr.csv_text_quote_in = new_value,
            .text_quote_out => b_ptr.csv_text_quote_out = new_value,
        }
        self.revalidateTemplate(template_idx) catch {};
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
