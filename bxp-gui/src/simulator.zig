//! Dry-run simulator for one bxp-cli broker template.
//!
//! Mirrors the read-side of `bxp-cli/src/pipeline.zig` (no output is written):
//! picks one input CSV from `broker.data_dir`, builds the pre_pass lookup
//! table, then per row evaluates `input_schema`, `row_rules`, and the resulting
//! output rows. The full trace is kept in memory so the debug UI can step
//! forwards/backwards through rows without re-running expressions.
//!
//! xlsx and JSON inputs are out of scope for the MVP — only `.csv` is loaded.
//! pre_pass entries are kept as a flat slice (not the composite-key hashmap
//! the engine uses) so the debug panel can render them in row form.

const std = @import("std");
const config = @import("config");
const csv = @import("csv");
const expr = @import("expr");

const MAX_COLUMNS: usize = 256;
const MAX_FILE_SIZE: usize = 16 * 1024 * 1024;

pub const VarTrace = struct {
    name: []const u8,
    expr_text: []const u8,
    value: []const u8,
    error_text: []const u8,
};

pub const RuleTrace = struct {
    rule_idx: usize,
    when_text: []const u8,
    when_truthy: bool,
    error_text: []const u8,
    matched: bool,
};

pub const OutputRowTrace = struct {
    cells: [][]const u8,
    overrides: []VarTrace,
};

pub const RowTrace = struct {
    row_index: usize,
    raw_fields: [][]const u8,
    vars: []VarTrace,
    rules: []RuleTrace,
    matched_rule: ?usize,
    output_rows: []OutputRowTrace,
};

pub const PrePassEntry = struct {
    key: []const u8,
    field: []const u8,
    value: []const u8,
};

pub const Simulation = struct {
    arena: *std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    source_path: []const u8,
    headers: [][]const u8,
    output_headers: [][]const u8,
    pre_pass: []PrePassEntry,
    rows: []RowTrace,
    /// Soft-fail message captured before any rows were produced (e.g. directory
    /// missing, no input files). Empty on success.
    error_message: []const u8,

    pub fn deinit(self: *Simulation) void {
        const gpa = self.gpa;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }
};

/// Build a Simulation by reading the first matching CSV in `data_dir_resolved`.
/// `data_dir_resolved` must already be an absolute or cwd-relative path that
/// the OS can open — the caller is responsible for resolving any `../` against
/// the loaded config file.
pub fn run(
    gpa: std.mem.Allocator,
    broker: *const config.BrokerConfig,
    data_dir_resolved: []const u8,
) !Simulation {
    const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(gpa);
    errdefer {
        arena_ptr.deinit();
        gpa.destroy(arena_ptr);
    }
    const a = arena_ptr.allocator();

    var sim: Simulation = .{
        .arena = arena_ptr,
        .gpa = gpa,
        .source_path = "",
        .headers = &.{},
        .output_headers = &.{},
        .pre_pass = &.{},
        .rows = &.{},
        .error_message = "",
    };

    var dir = std.fs.cwd().openDir(data_dir_resolved, .{ .iterate = true }) catch |err| {
        sim.error_message = try std.fmt.allocPrint(a, "open data_dir '{s}': {s}", .{ data_dir_resolved, @errorName(err) });
        return sim;
    };
    defer dir.close();

    const filename = pickInputFile(a, dir, broker.file_pattern_in) catch |err| {
        sim.error_message = try std.fmt.allocPrint(a, "scan data_dir: {s}", .{@errorName(err)});
        return sim;
    } orelse {
        sim.error_message = try std.fmt.allocPrint(a, "no input file matching '{s}' in '{s}'", .{ broker.file_pattern_in, data_dir_resolved });
        return sim;
    };
    sim.source_path = filename;

    const f = dir.openFile(filename, .{}) catch |err| {
        sim.error_message = try std.fmt.allocPrint(a, "open '{s}': {s}", .{ filename, @errorName(err) });
        return sim;
    };
    defer f.close();
    const raw = f.readToEndAlloc(a, MAX_FILE_SIZE) catch |err| {
        sim.error_message = try std.fmt.allocPrint(a, "read '{s}': {s}", .{ filename, @errorName(err) });
        return sim;
    };
    const content = if (std.mem.startsWith(u8, raw, "\xEF\xBB\xBF")) raw[3..] else raw;

    const records = csv.splitRecords(content, broker.csv_text_quote_in, a) catch |err| {
        sim.error_message = try std.fmt.allocPrint(a, "split records: {s}", .{@errorName(err)});
        return sim;
    };
    if (records.items.len == 0) {
        sim.error_message = try a.dupe(u8, "input file is empty");
        return sim;
    }

    var col_index = std.StringHashMap(usize).init(a);
    var headers: std.ArrayListUnmanaged([]const u8) = .empty;
    {
        const hdr_buf = try a.alloc([]const u8, MAX_COLUMNS);
        const hdr_fields = csv.splitFields(records.items[0], hdr_buf, broker.csv_delimiter_in, broker.csv_text_quote_in, a) catch |err| {
            sim.error_message = try std.fmt.allocPrint(a, "split header: {s}", .{@errorName(err)});
            return sim;
        };
        for (hdr_fields, 0..) |name, i| {
            const trimmed = std.mem.trim(u8, name, " ");
            try col_index.put(trimmed, i);
            try headers.append(a, trimmed);
        }
    }
    sim.headers = headers.items;

    var data_rows: std.ArrayListUnmanaged([][]const u8) = .empty;
    for (records.items[1..]) |line| {
        const row_buf = try a.alloc([]const u8, MAX_COLUMNS);
        const fields = csv.splitFields(line, row_buf, broker.csv_delimiter_in, broker.csv_text_quote_in, a) catch continue;
        try data_rows.append(a, fields);
    }

    var pre_pass_entries: std.ArrayListUnmanaged(PrePassEntry) = .empty;
    var lookup_table = std.StringHashMap([]const u8).init(a);
    if (broker.pre_pass) |pp| {
        for (data_rows.items) |fields| {
            var detail: []const u8 = "";
            const ctx = expr.Context{
                .fields = fields,
                .col_index = &col_index,
                .quote_out = broker.csv_text_quote_out,
                .ticker_map = &broker.ticker_map,
                .lookup_table = null,
                .alloc = a,
                .decimal_sep_in = broker.csv_decimal_separator_in,
                .error_detail = &detail,
            };
            const when = expr.eval(pp.when, &ctx) catch continue;
            if (!when.toBool()) continue;
            const key_val = expr.evalString(pp.key, &ctx) catch continue;
            if (key_val.len == 0) continue;
            var v_it = pp.values.iterator();
            while (v_it.next()) |ve| {
                const val = expr.evalString(ve.value_ptr.*, &ctx) catch continue;
                const composite = try std.mem.concat(a, u8, &.{ key_val, "\x00", ve.key_ptr.* });
                try lookup_table.put(composite, val);
                try pre_pass_entries.append(a, .{
                    .key = try a.dupe(u8, key_val),
                    .field = ve.key_ptr.*,
                    .value = val,
                });
            }
        }
    }
    sim.pre_pass = pre_pass_entries.items;
    const lookup_ptr: ?*const std.StringHashMap([]const u8) =
        if (broker.pre_pass != null) &lookup_table else null;

    var output_headers: std.ArrayListUnmanaged([]const u8) = .empty;
    for (broker.output_schema.items) |col| {
        try output_headers.append(a, col.header);
    }
    sim.output_headers = output_headers.items;

    var row_traces: std.ArrayListUnmanaged(RowTrace) = .empty;
    for (data_rows.items, 0..) |fields, ri| {
        var detail: []const u8 = "";
        var ctx = expr.Context{
            .fields = fields,
            .col_index = &col_index,
            .quote_out = broker.csv_text_quote_out,
            .ticker_map = &broker.ticker_map,
            .lookup_table = lookup_ptr,
            .alloc = a,
            .decimal_sep_in = broker.csv_decimal_separator_in,
            .error_detail = &detail,
        };

        const var_traces = try evalSchema(a, broker.input_schema, &ctx, &detail);
        const var_map = try varMapFromTraces(a, var_traces);

        var rule_traces: std.ArrayListUnmanaged(RuleTrace) = .empty;
        var output_rows: std.ArrayListUnmanaged(OutputRowTrace) = .empty;
        var matched_rule: ?usize = null;
        if (broker.row_rules) |rules| {
            for (rules, 0..) |rule, idx| {
                detail = "";
                var trace: RuleTrace = .{
                    .rule_idx = idx,
                    .when_text = rule.when,
                    .when_truthy = false,
                    .error_text = "",
                    .matched = false,
                };
                if (matched_rule != null) {
                    try rule_traces.append(a, trace);
                    continue;
                }
                const when_val = expr.eval(rule.when, &ctx) catch |err| {
                    trace.error_text = if (detail.len > 0)
                        try std.fmt.allocPrint(a, "{s}: {s}", .{ @errorName(err), detail })
                    else
                        try a.dupe(u8, @errorName(err));
                    try rule_traces.append(a, trace);
                    continue;
                };
                trace.when_truthy = when_val.toBool();
                if (trace.when_truthy) {
                    trace.matched = true;
                    matched_rule = idx;
                    for (rule.rows) |row_override| {
                        const out_row = try buildOutputRow(a, broker, var_map, row_override, &ctx, &detail);
                        try output_rows.append(a, out_row);
                    }
                }
                try rule_traces.append(a, trace);
            }
        } else {
            // No row_rules: synthesise a single output row from input_schema vars.
            const cells = try buildCellsFromVars(a, broker, var_map);
            try output_rows.append(a, .{ .cells = cells, .overrides = &.{} });
        }

        try row_traces.append(a, .{
            .row_index = ri,
            .raw_fields = fields,
            .vars = var_traces,
            .rules = rule_traces.items,
            .matched_rule = matched_rule,
            .output_rows = output_rows.items,
        });
    }
    sim.rows = row_traces.items;
    return sim;
}

fn pickInputFile(
    a: std.mem.Allocator,
    dir: std.fs.Dir,
    file_pattern_in: []const u8,
) !?[]const u8 {
    var it = dir.iterate();
    var best: ?[]const u8 = null;
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (file_pattern_in.len > 0 and !std.mem.endsWith(u8, entry.name, file_pattern_in)) continue;
        if (!std.mem.endsWith(u8, entry.name, ".csv")) continue;
        if (best) |b| {
            if (std.mem.order(u8, entry.name, b) == .lt) {
                best = try a.dupe(u8, entry.name);
            }
        } else {
            best = try a.dupe(u8, entry.name);
        }
    }
    return best;
}

fn evalSchema(
    a: std.mem.Allocator,
    schema: std.StringHashMap([]const u8),
    ctx: *expr.Context,
    detail: *[]const u8,
) ![]VarTrace {
    var out: std.ArrayListUnmanaged(VarTrace) = .empty;
    var it = schema.iterator();
    while (it.next()) |e| {
        detail.* = "";
        var trace: VarTrace = .{
            .name = e.key_ptr.*,
            .expr_text = e.value_ptr.*,
            .value = "",
            .error_text = "",
        };
        if (expr.evalString(e.value_ptr.*, ctx)) |val| {
            trace.value = val;
        } else |err| {
            trace.error_text = if (detail.len > 0)
                try std.fmt.allocPrint(a, "{s}: {s}", .{ @errorName(err), detail.* })
            else
                try a.dupe(u8, @errorName(err));
        }
        try out.append(a, trace);
    }
    std.mem.sort(VarTrace, out.items, {}, struct {
        fn lessThan(_: void, x: VarTrace, y: VarTrace) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lessThan);
    return out.items;
}

fn varMapFromTraces(a: std.mem.Allocator, traces: []const VarTrace) !std.StringHashMap([]const u8) {
    var m = std.StringHashMap([]const u8).init(a);
    for (traces) |t| try m.put(t.name, t.value);
    return m;
}

fn buildOutputRow(
    a: std.mem.Allocator,
    broker: *const config.BrokerConfig,
    base_vars: std.StringHashMap([]const u8),
    row_override: config.RowOverride,
    ctx: *expr.Context,
    detail: *[]const u8,
) !OutputRowTrace {
    var merged = std.StringHashMap([]const u8).init(a);
    var b_it = base_vars.iterator();
    while (b_it.next()) |e| try merged.put(e.key_ptr.*, e.value_ptr.*);

    var override_traces: std.ArrayListUnmanaged(VarTrace) = .empty;
    var ov_it = row_override.iterator();
    while (ov_it.next()) |e| {
        detail.* = "";
        var trace: VarTrace = .{
            .name = e.key_ptr.*,
            .expr_text = e.value_ptr.*,
            .value = "",
            .error_text = "",
        };
        if (expr.evalString(e.value_ptr.*, ctx)) |val| {
            trace.value = val;
            try merged.put(e.key_ptr.*, val);
        } else |err| {
            trace.error_text = if (detail.len > 0)
                try std.fmt.allocPrint(a, "{s}: {s}", .{ @errorName(err), detail.* })
            else
                try a.dupe(u8, @errorName(err));
        }
        try override_traces.append(a, trace);
    }

    const cells = try buildCellsFromVars(a, broker, merged);
    return .{ .cells = cells, .overrides = override_traces.items };
}

fn buildCellsFromVars(
    a: std.mem.Allocator,
    broker: *const config.BrokerConfig,
    vars: std.StringHashMap([]const u8),
) ![][]const u8 {
    const cells = try a.alloc([]const u8, broker.output_schema.items.len);
    for (broker.output_schema.items, 0..) |col, i| {
        cells[i] = vars.get(col.variable) orelse "";
    }
    return cells;
}
