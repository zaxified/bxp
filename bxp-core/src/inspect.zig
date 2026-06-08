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

/// Result of a traced single-expression eval. The per-call NDJSON trace lines
/// (and, on success, the final sentinel) are written to the caller's
/// `trace_out`; only the failure sentinel is returned here, so the caller can
/// route it to a separate channel (bxp-fmt → stderr; bxp-mcp → its result).
pub const TraceResult = struct {
    /// On eval failure: the error-sentinel JSON line (no trailing newline) —
    /// `{"t":"error","error":…,"detail":…,"off"?,"len"?}`. null on success.
    error_json: ?[]u8,
    exit_code: u8, // 0 success, 1 eval error
};

/// Evaluate one expression with per-call NDJSON tracing. The expr engine emits
/// one NDJSON line per function call to `trace_out`; on success this also writes
/// the final sentinel `{"t":"final","value":…}` there (newline-terminated). On
/// failure no final sentinel is written — the error sentinel is returned in
/// `error_json` for the caller to route, and any partial trace lines already on
/// `trace_out` are kept. The caller owns flushing `trace_out`.
///
/// Shared by bxp-fmt `--expr-trace` (trace_out = stdout, error → stderr) and the
/// MCP `bxp_eval_trace` tool (trace_out = a buffer; error appended after). Bad
/// `headers_json`/`fields_json` shape → error.InvalidRowJson.
pub fn evalTrace(
    a: std.mem.Allocator,
    src: []const u8,
    headers_json: ?[]const u8,
    fields_json: ?[]const u8,
    trace_out: *std.Io.Writer,
) !TraceResult {
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
        // One NDJSON line per function call streams here during eval.
        .trace_writer = trace_out,
    };

    if (expr_mod.evalString(src, &ctx)) |result| {
        var jw: std.json.Stringify = .{ .writer = trace_out, .options = .{} };
        try jw.beginObject();
        try jw.objectField("t");
        try jw.write("final");
        try jw.objectField("value");
        try jw.write(result);
        try jw.endObject();
        try trace_out.writeByte('\n');
        return .{ .error_json = null, .exit_code = 0 };
    } else |err| {
        const error_json = try formatExprErrorJson(a, "error", @errorName(err), detail, err_offset, err_len);
        return .{ .error_json = error_json, .exit_code = 1 };
    }
}

/// Serialize an expression error sentinel (no trailing newline) into arena-owned
/// bytes: `{"t":<t>,"error":<name>,"detail":<detail>,"off"?,"len"?}`. `off`/`len`
/// appear only when `len > 0`. Mirrors bxp-fmt's stderr sentinel exactly.
fn formatExprErrorJson(
    a: std.mem.Allocator,
    t: ?[]const u8,
    err_name: []const u8,
    detail: []const u8,
    off: u32,
    len: u32,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try jw.beginObject();
    if (t) |tt| {
        try jw.objectField("t");
        try jw.write(tt);
    }
    try jw.objectField("error");
    try jw.write(err_name);
    try jw.objectField("detail");
    try jw.write(detail);
    if (len > 0) {
        try jw.objectField("off");
        try jw.write(off);
        try jw.objectField("len");
        try jw.write(len);
    }
    try jw.endObject();
    return aw.toOwnedSlice();
}

/// One expression-validation finding. `off`/`len` pin the offending token span
/// (the GUI editor highlights it); `len == 0` means no span was pinned.
pub const ExprError = struct {
    name: []const u8,
    detail: []const u8,
    off: u32,
    len: u32,
};

/// Validate one expression against an empty row context: runtime eval (syntax +
/// semantics) followed by the static FnArgDoc checks (literal-only mistakes the
/// runtime skips when a call never executes, e.g. SPLIT_PART(…, 0)). Returns the
/// first error, or null when valid. Pure — the caller marshals the finding to
/// its own channel (bxp-fmt `--expr` → stderr JSON; the bridge's
/// `bridge_eval_expr` → its out buffer). Mirrors what `BrokerConfig.validate()`
/// checks, keeping editor / Save / CLI diagnostics in sync.
pub fn validateExpr(a: std.mem.Allocator, src: []const u8) !?ExprError {
    var col_index = std.StringHashMap(usize).init(a);
    var ticker_map = std.StringHashMap([]const u8).init(a);
    var detail: []const u8 = "";
    var err_offset: u32 = 0;
    var err_len: u32 = 0;
    const ctx = expr_mod.Context{
        .fields = &.{},
        .col_index = &col_index,
        .ticker_map = &ticker_map,
        .lookup_table = null,
        .alloc = a,
        .error_detail = &detail,
        .error_offset = &err_offset,
        .error_len = &err_len,
    };

    _ = expr_mod.eval(src, &ctx) catch |err| {
        return ExprError{ .name = @errorName(err), .detail = detail, .off = err_offset, .len = err_len };
    };

    const sc = expr_mod.staticCheckCalls(src);
    if (sc.split_part) |bad| {
        const msg = try std.fmt.allocPrint(a, "index argument is 1-based; literal {d} always returns \"\"", .{bad.bad_idx});
        return ExprError{ .name = "SplitPartBadIndex", .detail = msg, .off = bad.off, .len = bad.len };
    }
    if (sc.date_format) |bad| {
        const msg = try std.fmt.allocPrint(a, "DATE_CONVERT format '{s}' has unrecognized letter '{c}' at offset {d} — wrap any literal letters in brackets, e.g. '[T]'", .{ bad.fmt, bad.fmt[bad.pos], bad.pos });
        return ExprError{ .name = "DateFormatBadToken", .detail = msg, .off = bad.off, .len = bad.len };
    }
    return null;
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

// ── expression batch ──────────────────────────────────────────────────────────

/// Result of an expression batch. On success `json` holds `{"results":[...]}`
/// (no trailing newline) and `error_message` is null. On a malformed request
/// `json` is empty and `error_message` carries a human-readable reason — the
/// caller routes it to stderr (bxp-fmt) or an MCP error response (bxp-mcp).
pub const BatchResult = struct {
    json: []u8,
    error_message: ?[]const u8,
    exit_code: u8,
};

fn batchErr(msg: []const u8) BatchResult {
    return .{ .json = "", .error_message = msg, .exit_code = 1 };
}

/// Evaluate N expressions against one row in a single call. `request` is the
/// already-parsed batch object `{headers, fields, exprs, ticker_map?, lookups?,
/// single_prepass_name?}`. Both adapters share this core: bxp-fmt's
/// `--expr-batch` parses stdin into a Value and hands it here; the MCP
/// `bxp_eval_batch` tool passes the call arguments straight through.
///
/// Ragged headers/fields are tolerated (mirrors the runtime engine: field
/// access is by header→index, and missing indices return ""). A well-formed
/// request always returns exit 0 even if individual exprs fail — the per-result
/// `ok` flag carries the per-expr outcome; only a malformed request is an error.
pub fn evalBatch(a: std.mem.Allocator, request: std.json.Value) !BatchResult {
    if (request != .object) return batchErr("--expr-batch stdin must be a JSON object");
    const obj = request.object;

    const headers_v = obj.get("headers") orelse return batchErr("missing 'headers' in --expr-batch request");
    const fields_v = obj.get("fields") orelse return batchErr("missing 'fields' in --expr-batch request");
    const exprs_v = obj.get("exprs") orelse return batchErr("missing 'exprs' in --expr-batch request");
    if (headers_v != .array or fields_v != .array or exprs_v != .array)
        return batchErr("headers/fields/exprs must be JSON arrays");

    // Dupe every string into the arena: the caller may free the source Value
    // (bxp-fmt defers `parsed.deinit()`) once this returns. Build col_index and
    // the field slice independently — never zip them, so ragged rows survive.
    var col_index = std.StringHashMap(usize).init(a);
    for (headers_v.array.items, 0..) |h, idx| {
        if (h != .string) return batchErr("headers entries must be strings");
        try col_index.put(try a.dupe(u8, h.string), idx);
    }
    var fields: std.ArrayList([]const u8) = .empty;
    for (fields_v.array.items) |f| {
        if (f != .string) return batchErr("fields entries must be strings");
        try fields.append(a, try a.dupe(u8, f.string));
    }

    // Optional ticker_map.
    var ticker_map = std.StringHashMap([]const u8).init(a);
    if (obj.get("ticker_map")) |tm| {
        if (tm != .object) return batchErr("ticker_map must be a JSON object");
        var it = tm.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .string) return batchErr("ticker_map values must be strings");
            try ticker_map.put(try a.dupe(u8, e.key_ptr.*), try a.dupe(u8, e.value_ptr.string));
        }
    }

    // Optional flat lookups blob ("name\x00key\x00field" → value). We only pass
    // a non-null lookup_table when entries exist — a null table makes LOOKUP()
    // resolve to "" instead of erroring on an empty map.
    var lookups = std.StringHashMap([]const u8).init(a);
    var have_lookups = false;
    if (obj.get("lookups")) |lk| {
        if (lk != .object) return batchErr("lookups must be a JSON object");
        var it = lk.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .string) return batchErr("lookups values must be strings");
            try lookups.put(try a.dupe(u8, e.key_ptr.*), try a.dupe(u8, e.value_ptr.string));
            have_lookups = true;
        }
    }

    // Optional single_prepass_name: enables 2-arg LOOKUP(key, field) when the
    // template's pre_pass section has exactly one block.
    var single_prepass_name: ?[]const u8 = null;
    if (obj.get("single_prepass_name")) |sp| {
        switch (sp) {
            .string => |s| if (s.len > 0) {
                single_prepass_name = try a.dupe(u8, s);
            },
            .null => {},
            else => return batchErr("single_prepass_name must be a string"),
        }
    }

    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("results");
    try jw.beginArray();

    for (exprs_v.array.items) |e_v| {
        if (e_v != .string) {
            // Keep the result array aligned with the caller's input order.
            try jw.beginObject();
            try jw.objectField("ok");
            try jw.write(false);
            try jw.objectField("error");
            try jw.write("BadInput");
            try jw.objectField("detail");
            try jw.write("exprs entries must be strings");
            try jw.endObject();
            continue;
        }
        const src = e_v.string;

        var detail: []const u8 = "";
        var err_off: u32 = 0;
        var err_len: u32 = 0;
        const ctx = expr_mod.Context{
            .fields = fields.items,
            .col_index = &col_index,
            .ticker_map = &ticker_map,
            .lookup_table = if (have_lookups) &lookups else null,
            .single_prepass_name = single_prepass_name,
            .alloc = a,
            .error_detail = &detail,
            .error_offset = &err_off,
            .error_len = &err_len,
        };

        const result = expr_mod.evalString(src, &ctx);
        try jw.beginObject();
        if (result) |val| {
            try jw.objectField("ok");
            try jw.write(true);
            try jw.objectField("value");
            try jw.write(val);
        } else |err| {
            try jw.objectField("ok");
            try jw.write(false);
            try jw.objectField("error");
            try jw.write(@errorName(err));
            try jw.objectField("detail");
            try jw.write(detail);
            if (err_len > 0) {
                try jw.objectField("off");
                try jw.write(err_off);
                try jw.objectField("len");
                try jw.write(err_len);
            }
        }
        try jw.endObject();
    }

    try jw.endArray();
    try jw.endObject();
    return .{ .json = try aw.toOwnedSlice(), .error_message = null, .exit_code = 0 };
}

// ── templates ─────────────────────────────────────────────────────────────────

/// JSON5 config text → parsed Value (preprocess + parse). For the MCP tools,
/// which receive config *text*; bxp-fmt reads from a file path instead and
/// passes the parsed root straight to the *Value variants below.
fn parseConfigText(a: std.mem.Allocator, text: []const u8) !std.json.Value {
    const json_text = try json5_mod.preprocess(a, text);
    return std.json.parseFromSliceLeaky(std.json.Value, a, json_text, .{
        .duplicate_field_behavior = .use_last,
    });
}

/// Optional string field from a JSON object — null if missing/wrong type.
fn optString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Emit `{"templates":[...]}` listing every template id plus selected metadata.
/// No semantic validation: structurally broken templates still appear (with an
/// `error` field) so the GUI picker can badge them rather than silently omit
/// them. Indented to stay byte-identical with bxp-fmt's `--list-templates`.
pub fn listTemplatesValue(a: std.mem.Allocator, root: std.json.Value) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try jw.beginObject();
    try jw.objectField("templates");
    try jw.beginArray();

    // Intentional double-guard (root shape + ct shape) so a partial config
    // doesn't crash the listing.
    if (root == .object) {
        if (root.object.get("conversion_templates")) |ct| {
            if (ct == .object) {
                var it = ct.object.iterator();
                while (it.next()) |entry| {
                    try jw.beginObject();
                    try jw.objectField("id");
                    try jw.write(entry.key_ptr.*);

                    if (entry.value_ptr.* == .object) {
                        const tobj = entry.value_ptr.object;
                        // Nullable fields emit JSON null when absent so the GUI
                        // can tell "not set" from "empty string".
                        try jw.objectField("data_dir");
                        if (optString(tobj, "data_dir")) |s| try jw.write(s) else try jw.write(null);
                        try jw.objectField("file_pattern_in");
                        if (optString(tobj, "file_pattern_in")) |s| try jw.write(s) else try jw.write(null);
                        try jw.objectField("file_pattern_out");
                        if (optString(tobj, "file_pattern_out")) |s| try jw.write(s) else try jw.write(null);
                        // file_type_{in,out} default to "csv" so the GUI picker
                        // always shows a concrete value.
                        try jw.objectField("file_type_in");
                        try jw.write(optString(tobj, "file_type_in") orelse "csv");
                        try jw.objectField("file_type_out");
                        try jw.write(optString(tobj, "file_type_out") orelse "csv");
                        try jw.objectField("description");
                        if (optString(tobj, "description")) |s| try jw.write(s) else try jw.write(null);
                    } else {
                        try jw.objectField("error");
                        try jw.write("template entry is not an object");
                    }
                    try jw.endObject();
                }
            }
        }
    }

    try jw.endArray();
    try jw.endObject();
    return aw.toOwnedSlice();
}

/// Config-text wrapper around `listTemplatesValue` for the MCP `bxp_list_templates`
/// tool. A JSON5 parse failure surfaces as `{"$err_1":"<error>"}` — the same
/// shape the GUI already sees from the CLI.
pub fn listTemplates(a: std.mem.Allocator, config_text: []const u8) ![]u8 {
    const root = parseConfigText(a, config_text) catch |err| {
        return formatRootErr(a, @errorName(err));
    };
    return listTemplatesValue(a, root);
}

/// Result of a template fetch. `json` is the template JSON (success) or
/// `{"$err_1":"<msg>"}` (error), no trailing newline. `not_found` is true only
/// for the id-not-found case — bxp-fmt adds a stderr line that also names the
/// config path, which this pure core does not know.
pub const TemplateResult = struct {
    json: []u8,
    exit_code: u8,
    not_found: bool,
};

/// Fetch one template's raw JSON by id from an already-parsed config root.
/// Shared by bxp-fmt `--fetch-template` and the MCP `bxp_fetch_template` tool.
pub fn fetchTemplateValue(a: std.mem.Allocator, root: std.json.Value, id: []const u8) !TemplateResult {
    if (root != .object)
        return .{ .json = try formatRootErr(a, "config root is not an object"), .exit_code = 1, .not_found = false };
    const ct = root.object.get("conversion_templates") orelse
        return .{ .json = try formatRootErr(a, "no conversion_templates in config"), .exit_code = 1, .not_found = false };
    if (ct != .object)
        return .{ .json = try formatRootErr(a, "conversion_templates is not an object"), .exit_code = 1, .not_found = false };
    const t = ct.object.get(id) orelse {
        const msg = try std.fmt.allocPrint(a, "template id '{s}' not found", .{id});
        return .{ .json = try formatRootErr(a, msg), .exit_code = 1, .not_found = true };
    };

    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    try std.json.Stringify.value(t, .{ .whitespace = .indent_2 }, &aw.writer);
    return .{ .json = try aw.toOwnedSlice(), .exit_code = 0, .not_found = false };
}

/// Config-text wrapper around `fetchTemplateValue` for the MCP `bxp_fetch_template`
/// tool. A JSON5 parse failure surfaces as `{"$err_1":"<error>"}`.
pub fn fetchTemplate(a: std.mem.Allocator, config_text: []const u8, id: []const u8) !TemplateResult {
    const root = parseConfigText(a, config_text) catch |err| {
        return .{ .json = try formatRootErr(a, @errorName(err)), .exit_code = 1, .not_found = false };
    };
    return fetchTemplateValue(a, root, id);
}

/// One template's input shape, for a caller that wants to *stage* a real run
/// (e.g. bxp-mcp's `bxp_simulate`). Pure introspection — never reads files.
pub const TemplateIo = struct {
    /// false when the id is absent or the config is unparseable.
    found: bool,
    /// Input-file suffix filter (e.g. ".csv", "_cash.csv"); "" if absent.
    file_pattern_in: []const u8,
    /// file_type_in is absent or "csv" (so the input is a plain CSV file).
    csv_input: bool,
    /// Template declares an xlsx_sheet — its input is xlsx, not feedable as
    /// inline CSV text.
    has_xlsx_sheet: bool,
};

/// Introspect one template's input shape. Returns `found = false` (with safe
/// defaults) when the id is missing or the config can't be parsed — the caller
/// turns that into a user-facing error. The returned `file_pattern_in` is owned
/// by the arena `a`.
pub fn templateIo(a: std.mem.Allocator, config_text: []const u8, id: []const u8) !TemplateIo {
    const not_found: TemplateIo = .{ .found = false, .file_pattern_in = "", .csv_input = true, .has_xlsx_sheet = false };
    const root = parseConfigText(a, config_text) catch return not_found;
    if (root != .object) return not_found;
    const ct = root.object.get("conversion_templates") orelse return not_found;
    if (ct != .object) return not_found;
    const t = ct.object.get(id) orelse return not_found;
    if (t != .object) return not_found;
    const tobj = t.object;
    const fti = optString(tobj, "file_type_in") orelse "csv";
    const has_xlsx = if (tobj.get("xlsx_sheet")) |xs| xs == .object else false;
    return .{
        .found = true,
        .file_pattern_in = optString(tobj, "file_pattern_in") orelse "",
        .csv_input = std.mem.eql(u8, fti, "csv"),
        .has_xlsx_sheet = has_xlsx,
    };
}
