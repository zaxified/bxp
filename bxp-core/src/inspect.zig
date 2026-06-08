//! inspect — shared stateless inspection core for bxp-fmt and bxp-mcp.
//!
//! These are the bxp operations that inspect/validate without running a
//! conversion: validate a config, evaluate one expression, emit the language
//! docs. "One core, thin adapters": the logic lives here once — bxp-fmt wraps
//! it in a CLI (argv → stdout), bxp-mcp wraps the same calls in an MCP server
//! (JSON-RPC → stdout). Neither owns the logic.
//!
//! Everything here is pure: it never reads argv, never writes to stdout/stderr,
//! never calls std.process.exit. Callers own all I/O and the arena passed in.
//!
//! Moved verbatim out of bxp-fmt/src/main.zig (config annotation pipeline) so
//! the annotated-JSON output stays byte-identical — the GUI and the console
//! readme parse that exact shape.

const std = @import("std");
const config_mod = @import("config");
const expr_mod = @import("expr");
const json5_mod = @import("json5");
const docs_mod = @import("docs");
const diagnostics_mod = @import("diagnostics");

const CONFIG_MAX_FILE_SIZE = 1024 * 1024; // 1 MB

// ── docs ─────────────────────────────────────────────────────────────────────

/// Serialize the full language/schema documentation JSON into an arena-owned
/// slice. Thin wrapper over docs.writeDocs so both the CLI (`--docs`) and the
/// MCP `bxp_docs` tool emit byte-identical output.
pub fn docsJson(a: std.mem.Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    try docs_mod.writeDocs(a, &aw.writer);
    return aw.toOwnedSlice();
}

// ── config annotation ────────────────────────────────────────────────────────

/// Result of annotating a config. `json` is the serialized output (no trailing
/// newline); `exit_code` mirrors what bxp-fmt would exit with (0 = clean,
/// 1 = file/parse/validation error). The arena passed in owns `json`.
pub const AnnotateResult = struct {
    json: []u8,
    exit_code: u8,
};

/// File-loading wrapper around `annotateRaw`. Reads `path`, then runs the same
/// pure pipeline. `check_fs_seconds` is the deadline for the FS validation
/// pass; 0 disables the check.
pub fn annotateConfigFromFile(a: std.mem.Allocator, path: []const u8, check_fs_seconds: u8) !AnnotateResult {
    const raw = readFileCapped(a, path) catch |err| {
        return .{ .json = try formatRootErr(a, @errorName(err)), .exit_code = 1 };
    };
    return annotateRaw(a, raw, path, check_fs_seconds);
}

/// Pure annotation pipeline — takes JSON5 source bytes, preserves comments as
/// `$comm_<N>` siblings, injects `$err_<N>`/`$warn_<N>`/`$info_<N>` markers for
/// syntax and semantic errors, returns the serialized JSON + exit code.
///
/// Never reads files. Never writes to stdout/stderr. Never calls exit.
/// `path_label` is used only in diagnostic messages — pass `"<inline>"` or any
/// marker when the source isn't from a real file.
pub fn annotateRaw(a: std.mem.Allocator, raw: []const u8, path_label: []const u8, check_fs_seconds: u8) !AnnotateResult {
    const ann = json5_mod.preprocessAnnotated(a, raw) catch |err| {
        return .{ .json = try formatRootErr(a, @errorName(err)), .exit_code = 1 };
    };
    var counter: u32 = ann.next_id - 1;

    var value = std.json.parseFromSliceLeaky(std.json.Value, a, ann.out, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| {
        return .{ .json = try formatRootErr(a, @errorName(err)), .exit_code = 1 };
    };

    var diag: diagnostics_mod.Diagnostics = .init(a);

    var cfg = config_mod.loadFromBytes(a, raw, path_label, &diag) catch |err| {
        try insertErrBefore(a, &value, "", @errorName(err), &counter);
        try injectDiagnostics(a, &value, diag.items.items, &counter);
        return .{ .json = try valueToJsonString(a, value), .exit_code = 1 };
    };

    var errors: std.ArrayList(config_mod.ValidationError) = .empty;
    var it = cfg.brokers.iterator();
    while (it.next()) |entry| {
        try entry.value_ptr.validateCollect(entry.key_ptr.*, a, &errors);
        try entry.value_ptr.validateExprsCollect(entry.key_ptr.*, a, &diag);
        try config_mod.validateUnusedCollect(entry.value_ptr, entry.key_ptr.*, a, &diag);
    }

    try config_mod.validateCrossTemplate(&cfg, a, &diag);
    try config_mod.validateUnknownKeysCollect(&value, a, &diag);
    try config_mod.validateFilesystemWithTimeout(
        &cfg,
        a,
        &diag,
        @as(u64, check_fs_seconds) * 1000,
    );

    if (cfg.brokers.count() == 0) {
        try insertErrBefore(a, &value, "", "no conversion_templates defined", &counter);
        try injectDiagnostics(a, &value, diag.items.items, &counter);
        return .{ .json = try valueToJsonString(a, value), .exit_code = 1 };
    }

    if (errors.items.len == 0 and diag.count() == 0) {
        return .{ .json = try valueToJsonString(a, value), .exit_code = 0 };
    }

    try injectSemanticErrors(a, &value, errors.items, &counter);
    try injectDiagnostics(a, &value, diag.items.items, &counter);

    const has_error =
        errors.items.len != 0 or diag.countBySeverity(.@"error") != 0;
    return .{ .json = try valueToJsonString(a, value), .exit_code = if (has_error) 1 else 0 };
}

/// Build `{"$err_1":{"message":"<msg>"}}`... actually `{"$err_1":"<msg>"}` as a
/// standalone JSON document. Used by annotateRaw's fail paths.
fn formatRootErr(a: std.mem.Allocator, msg: []const u8) ![]u8 {
    var root: std.json.Value = .{ .object = .init(a) };
    try root.object.put("$err_1", .{ .string = msg });
    return valueToJsonString(a, root);
}

/// Serialize `value` into an arena-owned slice via std.json.Stringify.
fn valueToJsonString(a: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    try std.json.Stringify.value(value, .{}, &aw.writer);
    return aw.toOwnedSlice();
}

/// Read file into arena-allocated buffer, capped at CONFIG_MAX_FILE_SIZE.
fn readFileCapped(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(a, CONFIG_MAX_FILE_SIZE);
}

// ── diagnostic tree injection (moved verbatim from bxp-fmt) ───────────────────

fn injectSemanticErrors(
    a: std.mem.Allocator,
    root: *std.json.Value,
    errors: []const config_mod.ValidationError,
    counter: *u32,
) !void {
    for (errors) |e| {
        const parent_ptr: *std.json.Value = blk: {
            if (e.path.len == 0) break :blk root;
            const last_dot = std.mem.lastIndexOfScalar(u8, e.path, '.') orelse break :blk root;
            const parent_path = e.path[0..last_dot];
            break :blk getPtrAtPath(root, parent_path) orelse root;
        };

        const field_name: []const u8 = blk: {
            const last_dot = std.mem.lastIndexOfScalar(u8, e.path, '.') orelse break :blk e.path;
            break :blk e.path[last_dot + 1 ..];
        };

        const field_val_str = fieldValueStr(a, parent_ptr, field_name) catch "";
        const annotation = try std.fmt.allocPrint(
            a,
            "{s}: '{s}' --> {s}",
            .{ field_name, field_val_str, e.message },
        );

        try insertErrBefore(a, parent_ptr, field_name, annotation, counter);
    }
}

fn insertErrBefore(
    a: std.mem.Allocator,
    parent: *std.json.Value,
    target_key: []const u8,
    msg: []const u8,
    counter: *u32,
) !void {
    var obj = std.json.ObjectMap.init(a);
    try obj.put("message", .{ .string = try a.dupe(u8, msg) });
    return insertNumberedBefore(a, parent, "$err_", target_key, .{ .object = obj }, counter);
}

fn insertNumberedBefore(
    a: std.mem.Allocator,
    parent: *std.json.Value,
    prefix: []const u8,
    target_key: []const u8,
    value: std.json.Value,
    counter: *u32,
) !void {
    if (parent.* != .object) return;
    counter.* += 1;
    const new_key = try std.fmt.allocPrint(a, "{s}{d}", .{ prefix, counter.* });

    if (target_key.len == 0 or !parent.object.contains(target_key)) {
        try parent.object.put(new_key, value);
        return;
    }

    const Entry = struct { k: []const u8, v: std.json.Value };
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(a);
    var it = parent.object.iterator();
    while (it.next()) |kv| {
        try entries.append(a, .{ .k = try a.dupe(u8, kv.key_ptr.*), .v = kv.value_ptr.* });
    }
    parent.object.clearRetainingCapacity();
    for (entries.items) |e| {
        if (std.mem.eql(u8, e.k, target_key)) {
            try parent.object.put(new_key, value);
        }
        try parent.object.put(e.k, e.v);
    }
}

fn injectDiagnostics(
    a: std.mem.Allocator,
    root: *std.json.Value,
    items: []const diagnostics_mod.Diagnostic,
    counter: *u32,
) !void {
    for (items) |d| {
        const parent_ptr: *std.json.Value = blk: {
            if (d.path.len == 0) break :blk root;
            const last_dot = std.mem.lastIndexOfScalar(u8, d.path, '.') orelse break :blk root;
            const parent_path = d.path[0..last_dot];
            break :blk getPtrAtPath(root, parent_path) orelse root;
        };

        const field_name: []const u8 = blk: {
            const last_dot = std.mem.lastIndexOfScalar(u8, d.path, '.') orelse break :blk d.path;
            break :blk d.path[last_dot + 1 ..];
        };

        const prefix: []const u8 = switch (d.severity) {
            .@"error" => "$err_",
            .warning => "$warn_",
            .info => "$info_",
        };

        var obj = std.json.ObjectMap.init(a);
        try obj.put("message", .{ .string = try a.dupe(u8, d.message) });
        if (d.expr_off) |off| try obj.put("off", .{ .integer = @intCast(off) });
        if (d.expr_len) |len| try obj.put("len", .{ .integer = @intCast(len) });
        if (d.suggest) |s| try obj.put("suggest", .{ .string = try a.dupe(u8, s) });
        try insertNumberedBefore(a, parent_ptr, prefix, field_name, .{ .object = obj }, counter);
    }
}

fn getPtrAtPath(root: *std.json.Value, path: []const u8) ?*std.json.Value {
    if (path.len == 0) return root;
    var node = root;
    var parts = std.mem.splitScalar(u8, path, '.');
    while (parts.next()) |seg| {
        switch (node.*) {
            .object => |*obj| {
                node = obj.getPtr(seg) orelse return null;
            },
            .array => |*arr| {
                const idx = std.fmt.parseInt(usize, seg, 10) catch return null;
                if (idx >= arr.items.len) return null;
                node = &arr.items[idx];
            },
            else => return null,
        }
    }
    return node;
}

fn fieldValueStr(a: std.mem.Allocator, parent: *std.json.Value, field: []const u8) ![]const u8 {
    if (parent.* != .object) return "";
    const val = parent.object.get(field) orelse return "";
    return switch (val) {
        .string => |s| escapeForDisplay(a, s),
        .integer => |n| std.fmt.allocPrint(a, "{d}", .{n}),
        .float => |f| std.fmt.allocPrint(a, "{d}", .{f}),
        .bool => |b| a.dupe(u8, if (b) "true" else "false"),
        .null => a.dupe(u8, "null"),
        .array => a.dupe(u8, "[...]"),
        .object => a.dupe(u8, "{...}"),
        else => a.dupe(u8, ""),
    };
}

fn escapeForDisplay(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '\n' => try buf.appendSlice(a, "\\n"),
            '\r' => try buf.appendSlice(a, "\\r"),
            '\t' => try buf.appendSlice(a, "\\t"),
            else => try buf.append(a, c),
        }
    }
    return buf.toOwnedSlice(a);
}

// ── single-expression eval ───────────────────────────────────────────────────

/// Evaluate one expression against an optional row context and return a JSON
/// result string. New shared primitive (not moved from fmt — fmt's --expr-trace
/// keeps its GUI NDJSON streaming contract). Used by the MCP `bxp_eval` tool.
///
/// `headers_json` / `fields_json` are optional JSON arrays of strings (the same
/// shape bxp-fmt --expr-trace accepts). Returns one of:
///   {"ok":true,"value":"..."}
///   {"ok":false,"error":"X","detail":"...","off":N,"len":N}
/// Never throws on an expression error — only on OOM / malformed row JSON.
pub fn evalExpr(
    a: std.mem.Allocator,
    src: []const u8,
    headers_json: ?[]const u8,
    fields_json: ?[]const u8,
) ![]u8 {
    var col_index = std.StringHashMap(usize).init(a);
    var ticker_map = std.StringHashMap([]const u8).init(a);

    var headers_list: std.ArrayList([]const u8) = .empty;
    var fields_list: std.ArrayList([]const u8) = .empty;
    if (headers_json) |hj| try parseStringArray(a, hj, &headers_list);
    if (fields_json) |fj| try parseStringArray(a, fj, &fields_list);
    for (headers_list.items, 0..) |h, idx| try col_index.put(h, idx);

    var detail: []const u8 = "";
    var err_offset: u32 = 0;
    var err_len: u32 = 0;
    const ctx = expr_mod.Context{
        .fields = fields_list.items,
        .col_index = &col_index,
        .ticker_map = &ticker_map,
        .lookup_table = null,
        .alloc = a,
        .error_detail = &detail,
        .error_offset = &err_offset,
        .error_len = &err_len,
    };

    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

    if (expr_mod.evalString(src, &ctx)) |result| {
        try jw.beginObject();
        try jw.objectField("ok");
        try jw.write(true);
        try jw.objectField("value");
        try jw.write(result);
        try jw.endObject();
    } else |err| {
        try jw.beginObject();
        try jw.objectField("ok");
        try jw.write(false);
        try jw.objectField("error");
        try jw.write(@errorName(err));
        try jw.objectField("detail");
        try jw.write(detail);
        if (err_len > 0) {
            try jw.objectField("off");
            try jw.write(err_offset);
            try jw.objectField("len");
            try jw.write(err_len);
        }
        try jw.endObject();
    }
    return aw.toOwnedSlice();
}

/// Parse a JSON array of strings into `list` (arena-duped). Returns
/// error.InvalidRowJson on any shape mismatch.
fn parseStringArray(a: std.mem.Allocator, json_text: []const u8, list: *std.ArrayList([]const u8)) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, a, json_text, .{}) catch
        return error.InvalidRowJson;
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidRowJson;
    for (parsed.value.array.items) |item| {
        if (item != .string) return error.InvalidRowJson;
        try list.append(a, try a.dupe(u8, item.string));
    }
}
