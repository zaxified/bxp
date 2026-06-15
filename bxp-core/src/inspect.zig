//! inspect — shared stateless inspection core for bxp-mcp and the GUI bridge.
//!
//! These are the bxp operations that inspect/validate without running a
//! conversion: validate a config, evaluate one expression, emit the language
//! docs. "One core, thin adapters": the logic lives here once — bxp-mcp wraps
//! these calls in an MCP server (JSON-RPC → stdout) and the bxp-gui-bridge FFI
//! exposes them in-process to the Dart GUI. Neither owns the logic. (A former
//! bxp-fmt CLI adapter wrapped the same calls in argv → stdout; it was deleted
//! once the bridge and MCP covered every operation.)
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

// Single source of truth lives in config.zig; alias it here so the read cap can
// never drift between the loader and this path.
const CONFIG_MAX_FILE_SIZE = config_mod.CONFIG_MAX_FILE_SIZE;

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
/// newline); `exit_code` mirrors what the former bxp-fmt CLI exited with (0 = clean,
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
/// shape inspect.evalTrace accepts). Returns one of:
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
/// route it to a separate channel (bxp-fmt routed it to stderr; bxp-mcp → its result).
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
/// Shared by inspect.evalTrace (was `bxp-fmt --expr-trace`) (trace_out = stdout, error → stderr) and the
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
/// appear only when `len > 0`. Mirrors inspect's error sentinel exactly.
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
/// its own channel (was `bxp-fmt --expr` → stderr JSON; the bridge's
/// `bridge_eval_expr` → its out buffer). Mirrors what `BrokerConfig.validate()`
/// checks, keeping editor / Save / CLI diagnostics in sync.
pub fn validateExpr(a: std.mem.Allocator, src: []const u8) !?ExprError {
    var col_index = std.StringHashMap(usize).init(a);
    var detail: []const u8 = "";
    var err_offset: u32 = 0;
    var err_len: u32 = 0;
    const ctx = expr_mod.Context{
        .fields = &.{},
        .col_index = &col_index,
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

/// Validate one expression and serialize the verdict as JSON: `{"ok":true}` when
/// the expression is sound, or `{"ok":false,"error":…,"detail":…,"off"?,"len"?}`
/// for the first finding. Wraps `validateExpr` (the authoring-time check — runtime
/// eval + the static FnArgDoc lint) in the same `{ok,…}` envelope `evalExpr`
/// emits, so a thin adapter (the MCP `bxp_validate_expr` tool, mirroring the
/// bridge's `bridge_eval_expr`) is a one-line passthrough. The distinction from
/// `evalExpr`: this is the *authoring* verdict (catches literal mistakes the
/// lenient runtime would silently turn into ""), not the computed value. The
/// arena passed in owns the result.
pub fn validateExprJson(a: std.mem.Allocator, src: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try jw.beginObject();
    if (try validateExpr(a, src)) |e| {
        try jw.objectField("ok");
        try jw.write(false);
        try jw.objectField("error");
        try jw.write(e.name);
        try jw.objectField("detail");
        try jw.write(e.detail);
        if (e.len > 0) {
            try jw.objectField("off");
            try jw.write(e.off);
            try jw.objectField("len");
            try jw.write(e.len);
        }
    } else {
        try jw.objectField("ok");
        try jw.write(true);
    }
    try jw.endObject();
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

// ── expression batch ──────────────────────────────────────────────────────────

/// Result of an expression batch. On success `json` holds `{"results":[...]}`
/// (no trailing newline) and `error_message` is null. On a malformed request
/// `json` is empty and `error_message` carries a human-readable reason — the
/// caller routes it to stderr (formerly bxp-fmt) or an MCP error response (bxp-mcp).
pub const BatchResult = struct {
    json: []u8,
    error_message: ?[]const u8,
    exit_code: u8,
};

fn batchErr(msg: []const u8) BatchResult {
    return .{ .json = "", .error_message = msg, .exit_code = 1 };
}

/// Evaluate N expressions against one row in a single call. `request` is the
/// already-parsed batch object `{headers, fields, exprs, maps?, lookups?,
/// single_prepass_name?}`. Both live callers share this core: the MCP
/// `bxp_eval_batch` tool and the bridge's `bridge_inspect {op:eval_batch}`
/// hand the already-parsed request straight through. (The removed bxp-fmt
/// `--expr-batch` parsed the same object from stdin.)
///
/// Ragged headers/fields are tolerated (mirrors the runtime engine: field
/// access is by header→index, and missing indices return ""). A well-formed
/// request always returns exit 0 even if individual exprs fail — the per-result
/// `ok` flag carries the per-expr outcome; only a malformed request is an error.
pub fn evalBatch(a: std.mem.Allocator, request: std.json.Value) !BatchResult {
    if (request != .object) return batchErr("eval_batch request must be a JSON object");
    const obj = request.object;

    const headers_v = obj.get("headers") orelse return batchErr("missing 'headers' in eval_batch request");
    const fields_v = obj.get("fields") orelse return batchErr("missing 'fields' in eval_batch request");
    const exprs_v = obj.get("exprs") orelse return batchErr("missing 'exprs' in eval_batch request");
    if (headers_v != .array or fields_v != .array or exprs_v != .array)
        return batchErr("headers/fields/exprs must be JSON arrays");

    // Dupe every string into the arena: the caller may free the source Value
    // (bxp-fmt deferred `parsed.deinit()`) once this returns. Build col_index and
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

    // Optional maps registry: { map_name: { key: value } }. Resolved by REMAP /
    // REPLACE 'name' arguments. Values stored as ordered NamedMaps (insertion
    // order preserved for REPLACE).
    var maps = expr_mod.MapRegistry.init(a);
    if (obj.get("maps")) |mv| {
        if (mv != .object) return batchErr("maps must be a JSON object");
        var m_it = mv.object.iterator();
        while (m_it.next()) |m_entry| {
            if (m_entry.value_ptr.* != .object) return batchErr("maps entries must be JSON objects");
            var nm = expr_mod.NamedMap.init(a);
            var it = m_entry.value_ptr.object.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* != .string) return batchErr("map values must be strings");
                try nm.put(try a.dupe(u8, e.key_ptr.*), try a.dupe(u8, e.value_ptr.string));
            }
            try maps.put(try a.dupe(u8, m_entry.key_ptr.*), nm);
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
            .maps = &maps,
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
/// which receive config *text*; bxp-fmt read from a file path instead and
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
/// them. Indented to stay byte-identical with inspect.listTemplatesValue's.
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
/// for the id-not-found case — bxp-fmt added a stderr line that also named the
/// config path, which this pure core does not know.
pub const TemplateResult = struct {
    json: []u8,
    exit_code: u8,
    not_found: bool,
};

/// Fetch one template's raw JSON by id from an already-parsed config root.
/// Shared by inspect.fetchTemplate (was `bxp-fmt --fetch-template`) and the MCP `bxp_fetch_template` tool.
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

/// File-loading wrappers around `listTemplates` / `fetchTemplate` for callers
/// holding a config path (the bridge's bridge_inspect; the same shape bxp-fmt's
/// `--list-templates` / `--fetch-template` consume). A read failure surfaces as
/// `{"$err_1":"<error>"}`, mirroring `annotateConfigFromFile`.
pub fn listTemplatesFromFile(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = readFileCapped(a, path) catch |err| return formatRootErr(a, @errorName(err));
    return listTemplates(a, raw);
}

pub fn fetchTemplateFromFile(a: std.mem.Allocator, path: []const u8, id: []const u8) !TemplateResult {
    const raw = readFileCapped(a, path) catch |err| {
        return .{ .json = try formatRootErr(a, @errorName(err)), .exit_code = 1, .not_found = false };
    };
    return fetchTemplate(a, raw, id);
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

// ── tests ──────────────────────────────────────────────────────────────────
// Moved verbatim out of bxp-fmt/src/main.zig when that CLI adapter was deleted
// (the v0.3.0 single-backend cleanup). They exercise the shared inspect core
// directly — `annotateRaw` + `evalBatch` and the bxp-core modules behind them
// (`config`, `diagnostics`) — not any CLI plumbing, so this is their natural
// home now that no binary wraps the core in argv.

// Phase letters in test names correspond to validation passes added
// incrementally during the audit:
//   A  — basic structure (comments preserved, missing conversion_templates)
//   B  — per-template hard errors (xlsx_sheet, maps, output_schema)
//   C  — duplicate key detection
//   D  — wrong-type silent warnings (bool/enum fall-throughs)
//   E  — cross-template pattern collision
//   F  — filesystem existence (data_dir missing)
//   G  — deep expr validation (G2 header clustering, G3 LOOKUP,
//          G5 SPLIT_PART, G6 row_rules/pre_pass walker,
//          G7 unknown-key did-you-mean, G8 unused pre_pass/$var)

/// Phase G1 assertion helper: `$err_*` / `$warn_*` / `$info_*` values
/// are now objects `{message, off?, len?, suggest?}` instead of bare
/// strings. This helper reads `value.object.message` (when shape
/// matches) and substring-checks `needle` against it. Returns false
/// for any non-Diagnostic value or non-matching substring.
fn diagHas(v: *const std.json.Value, needle: []const u8) bool {
    if (v.* != .object) return false;
    const m = v.object.get("message") orelse return false;
    if (m != .string) return false;
    return std.mem.indexOf(u8, m.string, needle) != null;
}

test "annotateRaw: comments preserved + missing conversion_templates → \\$err_1" {
    // Replaces the previous shell-driven `Annotated JSON regression`
    // phase in scripts/test.sh + the gitted fixtures under
    // datasets/_annotated_fixtures/. Pure string-in / value-out — no
    // disk involvement.
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // JSON5 fixture mirrors the deleted datasets/_annotated_fixtures/sample.json5:
    // top-of-file line comment, an unquoted key (`xtb` rather than the
    // expected `conversion_templates`), a block comment between key and
    // value, and a line comment inside the array. The deliberate name
    // collision with `xtb` triggers the "no conversion_templates defined"
    // semantic error.
    const fixture =
        \\// top of file
        \\{
        \\  xtb: {
        \\    file_pattern_in: ".csv",
        \\    /* block before key */
        \\    items: [
        \\      // first
        \\      "a",
        \\      "b"
        \\    ]
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 1), result.exit_code);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    try testing.expect(parsed == .object);

    // Original tree shape preserved: `xtb` object with `file_pattern_in`
    // and a 2-element `items` array. JSON5 comments don't break parsing
    // and the unquoted key landed at the right place.
    const xtb = parsed.object.get("xtb") orelse return error.MissingXtb;
    try testing.expect(xtb == .object);
    try testing.expectEqualStrings(".csv", xtb.object.get("file_pattern_in").?.string);
    const items = xtb.object.get("items") orelse return error.MissingItems;
    try testing.expect(items == .array);
    try testing.expectEqual(@as(usize, 2), items.array.items.len);
    try testing.expectEqualStrings("a", items.array.items[0].string);
    try testing.expectEqualStrings("b", items.array.items[1].string);

    // Semantic error injected at root with the expected message.
    // Phase G1: $err_<N> values are objects {message, off?, len?, suggest?}.
    const err1 = parsed.object.get("$err_1") orelse return error.MissingErr1;
    try testing.expect(diagHas(&err1, "no conversion_templates"));
}

test "annotateRaw: clean config exits 0 with no \\$err_* markers" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      input_schema: { $date: "[Date]" },
        \\      output_schema: { date: "$date" },
        \\      row_rules: [
        \\        { when: "1", rows: [ { $action: "'DEPOSIT'" } ] }
        \\      ]
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 0), result.exit_code);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    try testing.expect(parsed == .object);
    var it = parsed.object.iterator();
    while (it.next()) |entry| {
        try testing.expect(!std.mem.startsWith(u8, entry.key_ptr.*, "$err_"));
    }
}

// Phase B — loadFromBytes per-template fail-fast errors are now also
// path-aware in the structured Diagnostics sink. Each test fires a
// single broken input and asserts the resulting `$err_*` marker landed
// inside the offending parent object (not at root) — that's what the
// GUI consumes via `errorsAt(path)` to render an inline banner.

test "annotateRaw Phase B: xlsx_sheet missing 'name' attaches \\$err_ at xlsx_sheet path" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      xlsx_sheet: { header_row: 1, output_suffix: ".csv" },
        \\      input_schema: { $date: "[Date]" },
        \\      output_schema: { date: "$date" },
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 1), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    try testing.expect(parsed == .object);

    // The diagnostic attaches as a sibling of xlsx_sheet (inside the
    // template object). Same placement contract as validateCollect's
    // path-injection — path "X.Y.field" means marker lives under X.Y
    // immediately before the `field` key.
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    const sample = ct.object.get("sample") orelse return error.MissingSample;
    const xlsx = sample.object.get("xlsx_sheet") orelse return error.MissingXlsx;
    try testing.expect(xlsx == .object);

    var has_err = false;
    var it = sample.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$err_") and
            diagHas(kv.value_ptr, "missing required key 'name'"))
        {
            has_err = true;
            break;
        }
    }
    try testing.expect(has_err);
}

test "annotateRaw: REMAP referencing an undefined map name is flagged" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No `maps` block defines `missing_named_map`, so the validate-mode
    // whitelist (Context.map_names) flags the REMAP reference — mirroring how
    // a LOOKUP to an undefined pre_pass block is flagged.
    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      input_schema: { $sym: "REMAP([Sym], 'missing_named_map')" },
        \\      output_schema: { symbol: "$sym" },
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 1), result.exit_code);
    // End-to-end: the diagnostic surfaces with the friendly "unknown named map"
    // wording set by expr.resolveNamedMap.
    try testing.expect(std.mem.indexOf(u8, result.json, "unknown named map") != null);
}

test "annotateRaw: REMAP against a defined map loads clean" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fixture =
        \\{
        \\  maps: { syms: { "VOW.DE": "VOW.DE.XETRA" } },
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      input_schema: { $sym: "REMAP([Sym], 'syms')" },
        \\      output_schema: { symbol: "$sym" },
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "annotateRaw Phase C: duplicate top-level key surfaces \\$err_ with key name" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two `data_dir` keys at the same object level — diagDuplicateKey
    // should fire and inspect should still emit a usable annotated tree.
    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: "first",
        \\      file_pattern_in: ".csv",
        \\      data_dir: "second",
        \\      file_pattern_out: ".csvx",
        \\      input_schema: { $date: "[Date]" },
        \\      output_schema: { date: "$date" },
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 1), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    try testing.expect(parsed == .object);

    var has_dup = false;
    var it = parsed.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$err_") and
            diagHas(kv.value_ptr, "duplicate key") and
            diagHas(kv.value_ptr, "data_dir"))
        {
            has_dup = true;
            break;
        }
    }
    try testing.expect(has_dup);
}

test "annotateRaw Phase D: wrong-type-silent emits \\$warn_ at template" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Three silent fall-through cases that today produce no diagnostic
    // and silently use defaults: bool field gets a number, csv enum
    // gets a typo, file_type enum gets garbage. Phase D surfaces all
    // three as `$warn_<N>` warnings without changing the runtime
    // behavior (still falls back to the default). Includes a clean
    // output_schema so the load doesn't bail early on a hard error.
    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      date_filter_from_filename: 1,
        \\      csv_text_quote_in: "singlle",
        \\      file_type_out: "jsno",
        \\      input_schema: { $date: "[Date]" },
        \\      output_schema: { date: "$date" },
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    // exit 0 — warnings don't fail, only error-severity does
    try testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    const sample = ct.object.get("sample") orelse return error.MissingSample;

    var warn_count: usize = 0;
    var found_bool = false;
    var found_quote = false;
    var found_filetype = false;
    var it = sample.object.iterator();
    while (it.next()) |kv| {
        if (!std.mem.startsWith(u8, kv.key_ptr.*, "$warn_")) continue;
        if (kv.value_ptr.* != .object) continue;
        warn_count += 1;
        if (diagHas(kv.value_ptr, "date_filter_from_filename") and
            diagHas(kv.value_ptr, "boolean")) found_bool = true;
        if (diagHas(kv.value_ptr, "csv_text_quote_in") and
            diagHas(kv.value_ptr, "singlle")) found_quote = true;
        if (diagHas(kv.value_ptr, "file_type_out") and
            diagHas(kv.value_ptr, "jsno")) found_filetype = true;
    }
    try testing.expectEqual(@as(usize, 3), warn_count);
    try testing.expect(found_bool);
    try testing.expect(found_quote);
    try testing.expect(found_filetype);
}

test "annotateRaw Phase E: file_pattern_in collision warns at first template" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two clean templates with the same data_dir; pattern of A is a
    // suffix of B (".csv" of "_x.csv"). Both match the same files
    // when scanning the directory — runtime would process them twice.
    // Phase E surfaces this as a `$warn_<N>` at template A.
    const fixture =
        \\{
        \\  conversion_templates: {
        \\    alpha: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: "_a.csvx",
        \\      input_schema: { $date: "[Date]" },
        \\      output_schema: { date: "$date" },
        \\    },
        \\    beta: {
        \\      data_dir: ".",
        \\      file_pattern_in: "_x.csv",
        \\      file_pattern_out: "_b.csvx",
        \\      input_schema: { $date: "[Date]" },
        \\      output_schema: { date: "$date" },
        \\    },
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    const alpha = ct.object.get("alpha") orelse return error.MissingAlpha;

    var has_collision = false;
    var it = alpha.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$warn_") and
            diagHas(kv.value_ptr, "matches the same files as template 'beta'"))
        {
            has_collision = true;
            break;
        }
    }
    try testing.expect(has_collision);
}

test "annotateRaw Phase E: distinct file_pattern_in suffixes do not warn" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Same data_dir but disjoint suffixes ("_closed.csv" vs "_cash.csv")
    // — neither is a suffix of the other. Runtime processes disjoint
    // files; no warning. This mirrors the xtb1/xtb2 layout in
    // DEV/bxp-cli.json so the regression check stays clean.
    const fixture =
        \\{
        \\  conversion_templates: {
        \\    closed: {
        \\      data_dir: ".",
        \\      file_pattern_in: "_closed.csv",
        \\      file_pattern_out: "_closed.csvx",
        \\      input_schema: { $date: "[Date]" },
        \\      output_schema: { date: "$date" },
        \\    },
        \\    cash: {
        \\      data_dir: ".",
        \\      file_pattern_in: "_cash.csv",
        \\      file_pattern_out: "_cash.csvx",
        \\      input_schema: { $date: "[Date]" },
        \\      output_schema: { date: "$date" },
        \\    },
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    inline for (.{ "closed", "cash" }) |name| {
        const tmpl = ct.object.get(name) orelse return error.MissingTemplate;
        var it = tmpl.object.iterator();
        while (it.next()) |kv| {
            try testing.expect(!std.mem.startsWith(u8, kv.key_ptr.*, "$warn_"));
        }
    }
}

test "annotateRaw Phase F: missing data_dir surfaces \\$err_ at template" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Deliberately reference a path that cannot exist on the test
    // machine — the FS check must fire and surface a path-aware error.
    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: "/__bxp_phase_f_must_not_exist__",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      input_schema: { $date: "[Date]" },
        \\      output_schema: { date: "$date" },
        \\    }
        \\  }
        \\}
    ;

    // check_fs_seconds=5: opt-in path. With 0 the FS check is a
    // no-op and this fixture would no longer flag the missing dir.
    const result = try annotateRaw(a, fixture, "<inline>", 5);
    try testing.expectEqual(@as(u8, 1), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    const sample = ct.object.get("sample") orelse return error.MissingSample;

    var has_fs_err = false;
    var it = sample.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$err_") and
            diagHas(kv.value_ptr, "data_dir does not exist"))
        {
            has_fs_err = true;
            break;
        }
    }
    try testing.expect(has_fs_err);
}

test "annotateRaw Phase G: unknown function in input_schema surfaces \\$err_" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // BLAH() is not a builtin — bare-Context eval raises
    // error.UnknownFunction. Phase G must surface that as a path-aware
    // marker on the input_schema entry, not a runtime fail-on-row-1.
    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      input_schema: { $val: "BLAH([Value])" },
        \\      output_schema: { val: "$val" },
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 1), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    const sample = ct.object.get("sample") orelse return error.MissingSample;
    const is = sample.object.get("input_schema") orelse return error.MissingIs;

    var has_unknown_fn = false;
    var it = is.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$err_") and
            diagHas(kv.value_ptr, "unknown function 'BLAH'"))
        {
            has_unknown_fn = true;
            break;
        }
    }
    try testing.expect(has_unknown_fn);
}

test "annotateRaw Phase G: did-you-mean suggests close builtin (LOOKUPP → LOOKUP)" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // LOOKUPP is one edit away from LOOKUP. Levenshtein ≤ 2 should
    // surface a suggest field. Verifies via direct config_mod call so
    // we can read the suggest field (which is internal to Diagnostic
    // and not yet plumbed into the annotated JSON output keys today).
    var diag: config_mod.Diagnostics = .init(a);
    defer diag.deinit();

    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      input_schema: { $key: "LOOKUPP('x', 'y')" },
        \\      output_schema: { key: "$key" },
        \\    }
        \\  }
        \\}
    ;

    var cfg = try config_mod.loadFromBytes(a, fixture, "<inline>", &diag);
    defer cfg.deinit();

    var it = cfg.brokers.iterator();
    while (it.next()) |entry| {
        try entry.value_ptr.validateExprsCollect(entry.key_ptr.*, a, &diag);
    }

    var saw_suggest = false;
    for (diag.items.items) |d| {
        if (std.mem.eql(u8, d.code, "expr.UnknownFunction")) {
            try testing.expect(d.suggest != null);
            try testing.expect(std.mem.indexOf(u8, d.suggest.?, "LOOKUP") != null);
            saw_suggest = true;
        }
    }
    try testing.expect(saw_suggest);
}

test "annotateRaw Phase G6: BLAH() in row_rules.rows.$var override → \\$err_ at deep path" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Override expression typo in row_rules[0].rows[0].$ticker. G6
    // walker must visit this path; without G6 the typo would slip
    // through (only input_schema + row_rules[].when were validated).
    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      input_schema: { $date: "[Date]" },
        \\      row_rules: [
        \\        { when: "true", rows: [ { $ticker: "BLAH([Sym])" } ] },
        \\      ],
        \\      output_schema: { date: "$date" },
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 1), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    const sample = ct.object.get("sample") orelse return error.MissingSample;
    const rules = sample.object.get("row_rules") orelse return error.MissingRules;
    const rule0 = rules.array.items[0];
    const rows = rule0.object.get("rows") orelse return error.MissingRows;
    const row0 = rows.array.items[0];

    var has_err = false;
    var it = row0.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$err_") and
            diagHas(kv.value_ptr, "unknown function 'BLAH'"))
        {
            has_err = true;
            break;
        }
    }
    try testing.expect(has_err);
}

test "annotateRaw Phase G6: BLAH() in pre_pass.values → \\$err_ at deep path" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      pre_pass: {
        \\        fees: { when: "true", key: "[ID]", values: { fee: "BLAH([F])" } }
        \\      },
        \\      input_schema: { $date: "[Date]" },
        \\      output_schema: { date: "$date" },
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 1), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    const sample = ct.object.get("sample") orelse return error.MissingSample;
    const pp = sample.object.get("pre_pass") orelse return error.MissingPP;
    const fees = pp.object.get("fees") orelse return error.MissingFees;
    const values = fees.object.get("values") orelse return error.MissingValues;

    var has_err = false;
    var it = values.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$err_") and
            diagHas(kv.value_ptr, "unknown function 'BLAH'"))
        {
            has_err = true;
            break;
        }
    }
    try testing.expect(has_err);
}

test "annotateRaw Phase G3: LOOKUP unknown pre_pass name → \\$err_ at expression leaf" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      pre_pass: {
        \\        real_name: { when: "true", key: "[ID]", values: { x: "[X]" } }
        \\      },
        \\      input_schema: { $bad: "LOOKUP('typo_name', [ID], 'x')" },
        \\      output_schema: { bad: "$bad" },
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 1), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    const sample = ct.object.get("sample") orelse return error.MissingSample;
    const is = sample.object.get("input_schema") orelse return error.MissingIs;

    var has_err = false;
    var it = is.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$err_") and
            diagHas(kv.value_ptr, "unknown pre_pass 'typo_name'"))
        {
            has_err = true;
            break;
        }
    }
    try testing.expect(has_err);
}

test "annotateRaw Phase G5: SPLIT_PART literal-zero index → \\$err_ at expression leaf" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      input_schema: {
        \\        $bad:  "SPLIT_PART([X], '-', 0)",
        \\        $good: "SPLIT_PART([X], '-', 1)",
        \\      },
        \\      output_schema: { bad: "$bad" },
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    // Severity is `.error` (1-based index typo is a hard config bug,
    // not a hint), so the marker is `$err_` and exit code is 1.
    try testing.expectEqual(@as(u8, 1), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    const sample = ct.object.get("sample") orelse return error.MissingSample;
    const is = sample.object.get("input_schema") orelse return error.MissingIs;

    var saw_bad_err = false;
    var it = is.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$err_") and
            diagHas(kv.value_ptr, "index argument is 1-based"))
        {
            saw_bad_err = true;
        }
    }
    try testing.expect(saw_bad_err);
}

test "annotateRaw Phase G4: DATE_CONVERT format with bare non-vocab letter → \\$err_" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `MN` is a typo (user meant `MM`). The strict walker must flag
    // any letter outside `[...]` not in the date-format vocabulary.
    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      input_schema: {
        \\        $bad: "DATE_CONVERT([X], 'YYYY-MN-DD', 'YYYY-MM-DD')",
        \\      },
        \\      output_schema: { bad: "$bad" },
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 1), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    const sample = ct.object.get("sample") orelse return error.MissingSample;
    const is = sample.object.get("input_schema") orelse return error.MissingIs;

    var saw = false;
    var it = is.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$err_") and
            diagHas(kv.value_ptr, "unrecognized letter 'N'"))
        {
            saw = true;
        }
    }
    try testing.expect(saw);
}

test "annotateRaw Phase G4: DATE_CONVERT with bracketed literal → no \\$err_" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Real-world ISO format with bracketed `T` literal must NOT flag.
    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      input_schema: {
        \\        $ok: "DATE_CONVERT([X], 'YYYY-MM-DD[T]hh:mm:ss[*]', 'YYYY-MM-DD hh:mm:ss')",
        \\      },
        \\      output_schema: { ok: "$ok" },
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "annotateRaw Phase G7: unknown config key → \\$err_ at offending path" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Typo in `file_pattern_in` → `file_patter_in`. G7 walker must
    // surface this as `config.unknown_key` error at the broker level
    // with a did-you-mean hint baked into the message. Severity is
    // `.error` because typo'd keys silently use defaults — wrong
    // output without a diagnostic the user can act on.
    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      file_patter_in: "typo",
        \\      input_schema: { $a: "[X]" },
        \\      output_schema: { a: "$a" },
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 1), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    const sample = ct.object.get("sample") orelse return error.MissingSample;

    var saw_err = false;
    var it = sample.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$err_") and
            diagHas(kv.value_ptr, "unknown config key 'file_patter_in'") and
            diagHas(kv.value_ptr, "did you mean 'file_pattern_in'?"))
        {
            saw_err = true;
        }
    }
    try testing.expect(saw_err);
}

test "annotateRaw Phase G7: $variable keys in input_schema are NOT flagged" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // input_schema is user-defined-key territory — every $variable
    // is valid. Walker must skip the whole sub-tree.
    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      input_schema: { $weird_name_user_picked: "[X]" },
        \\      output_schema: { x: "$weird_name_user_picked" },
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    const sample = ct.object.get("sample") orelse return error.MissingSample;
    const is = sample.object.get("input_schema") orelse return error.MissingIs;

    // No $err_* / $warn_* under input_schema referencing the user variable.
    var found_false_positive = false;
    var it = is.object.iterator();
    while (it.next()) |kv| {
        const k = kv.key_ptr.*;
        if ((std.mem.startsWith(u8, k, "$err_") or std.mem.startsWith(u8, k, "$warn_")) and
            diagHas(kv.value_ptr, "$weird_name_user_picked"))
        {
            found_false_positive = true;
        }
    }
    try testing.expect(!found_false_positive);
}

test "annotateRaw Phase G2 layer B: clustering flags low-frequency outlier" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // [Symbol] used 3 times (high-frequency cluster), [Symbo] used
    // once (low-frequency outlier, distance 1) → warning.
    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      input_schema: {
        \\        $a: "[Symbol]",
        \\        $b: "[Symbol]",
        \\        $c: "[Symbol]",
        \\        $d: "[Symbo]"
        \\      },
        \\      output_schema: { a: "$a", b: "$b", c: "$c", d: "$d" }
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    // Warning severity → exit 0 from inspect.annotateRaw (warnings don't
    // flip exit code; only $err_* does).
    try testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    const sample = ct.object.get("sample") orelse return error.MissingSample;

    var saw = false;
    var it = sample.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$warn_") and
            diagHas(kv.value_ptr, "field 'Symbo' is referenced once"))
        {
            saw = true;
        }
    }
    try testing.expect(saw);
}

test "annotateRaw Phase G2 layer B: high-distance optional column NOT flagged" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // [Symbol] used 3 times (cluster), [Stamp duty reserve tax] once
    // — distance ≫ 2 from any cluster name, must NOT be flagged.
    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      input_schema: {
        \\        $a: "[Symbol]",
        \\        $b: "[Symbol]",
        \\        $c: "[Symbol]",
        \\        $d: "[Stamp duty reserve tax]"
        \\      },
        \\      output_schema: { a: "$a", b: "$b", c: "$c", d: "$d" }
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    const sample = ct.object.get("sample") orelse return error.MissingSample;

    var false_positive = false;
    var it = sample.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$warn_") and
            diagHas(kv.value_ptr, "Stamp duty"))
        {
            false_positive = true;
        }
    }
    try testing.expect(!false_positive);
}

test "annotateRaw Phase G8: unused pre_pass block → \\$warn_ at pre_pass.<name>" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two named pre_pass blocks; only `used` is referenced via LOOKUP.
    // G8 must surface `unused_block` as a warning at the
    // `pre_pass.unused_block` path.
    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      pre_pass: {
        \\        used: { when: "true", key: "[ID]", values: { x: "[X]" } },
        \\        unused_block: { when: "true", key: "[Y]", values: { y: "[Y]" } }
        \\      },
        \\      input_schema: { $a: "LOOKUP('used', [ID], 'x')" },
        \\      output_schema: { a: "$a" },
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    const sample = ct.object.get("sample") orelse return error.MissingSample;
    const pp = sample.object.get("pre_pass") orelse return error.MissingPP;

    var saw_unused = false;
    var saw_used_warn = false;
    var it = pp.object.iterator();
    while (it.next()) |kv| {
        if (!std.mem.startsWith(u8, kv.key_ptr.*, "$warn_")) continue;
        if (diagHas(kv.value_ptr, "'unused_block'") and
            diagHas(kv.value_ptr, "never referenced"))
        {
            saw_unused = true;
        }
        if (diagHas(kv.value_ptr, "'used'") and
            diagHas(kv.value_ptr, "never referenced"))
        {
            saw_used_warn = true;
        }
    }
    try testing.expect(saw_unused);
    try testing.expect(!saw_used_warn);
}

test "annotateRaw Phase G8: unused $variable in input_schema → \\$warn_" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // $unused_var is declared but never referenced anywhere.
    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      input_schema: {
        \\        $a: "[X]",
        \\        $unused_var: "[Y]",
        \\      },
        \\      output_schema: { a: "$a" },
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    const sample = ct.object.get("sample") orelse return error.MissingSample;
    const is = sample.object.get("input_schema") orelse return error.MissingIs;

    var saw_unused = false;
    var saw_a_warn = false;
    var it = is.object.iterator();
    while (it.next()) |kv| {
        if (!std.mem.startsWith(u8, kv.key_ptr.*, "$warn_")) continue;
        if (diagHas(kv.value_ptr, "'$unused_var'")) saw_unused = true;
        if (diagHas(kv.value_ptr, "'$a'")) saw_a_warn = true;
    }
    try testing.expect(saw_unused);
    try testing.expect(!saw_a_warn);
}

test "annotateRaw Phase G8: 2-arg LOOKUP with single block → no false positive" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Legacy single-block pre_pass + 2-arg LOOKUP. Walker must
    // recognise the implicit `_default` namespace and not flag the
    // block as unused.
    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      pre_pass: { when: "true", key: "[ID]", values: { x: "[X]" } },
        \\      input_schema: { $a: "LOOKUP([ID], 'x')" },
        \\      output_schema: { a: "$a" },
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    const sample = ct.object.get("sample") orelse return error.MissingSample;

    // No unused-pre_pass warning anywhere under sample.
    var saw_unused = false;
    const Walker = struct {
        fn walk(node: std.json.Value, found: *bool) void {
            switch (node) {
                .object => |obj| {
                    var it = obj.iterator();
                    while (it.next()) |kv| {
                        if (std.mem.startsWith(u8, kv.key_ptr.*, "$warn_") and
                            diagHas(kv.value_ptr, "never referenced"))
                        {
                            found.* = true;
                        }
                        walk(kv.value_ptr.*, found);
                    }
                },
                .array => |arr| for (arr.items) |child| walk(child, found),
                else => {},
            }
        }
    };
    Walker.walk(sample, &saw_unused);
    try testing.expect(!saw_unused);
}

test "annotateRaw Phase B: output_schema missing attaches at template path" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fixture =
        \\{
        \\  conversion_templates: {
        \\    sample: {
        \\      data_dir: ".",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: ".csvx",
        \\      input_schema: { $date: "[Date]" },
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>", 0);
    try testing.expectEqual(@as(u8, 1), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    const sample = ct.object.get("sample") orelse return error.MissingSample;

    var has_err = false;
    var it = sample.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$err_") and
            diagHas(kv.value_ptr, "output_schema is required"))
        {
            has_err = true;
            break;
        }
    }
    try testing.expect(has_err);
}

/// Drive `evalBatch` over an in-memory JSON request body and return the
/// `{exit, json}` pair so tests can assert without stdin/stdout. Mirrors the
/// bytes path inspect.evalBatch's used to expose (parse stdin → Value →
/// `evalBatch`) before that adapter was deleted.
fn batchOnBytes(a: std.mem.Allocator, body: []const u8) !struct { exit: u8, json: []const u8 } {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    const r = try evalBatch(a, parsed);
    return .{ .exit = r.exit_code, .json = r.json };
}

test "expr-batch: more fields than headers is tolerated (xlsx trailing comma)" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 2 headers, 3 fields (trailing-comma data row). The runtime engine
    // accesses fields by header→index and ignores the unaddressed extra,
    // so the batch must NOT error — erroring here used to blank the GUI
    // drill-down (no vars, no rules) for valid xlsx-derived rows.
    const r = try batchOnBytes(a,
        \\{"headers":["A","B"],"fields":["1","2","x"],"exprs":["[A]","[B]"]}
    );
    try testing.expectEqual(@as(u8, 0), r.exit);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, r.json, .{});
    const results = parsed.object.get("results").?.array;
    try testing.expectEqual(@as(usize, 2), results.items.len);
    try testing.expectEqualStrings("1", results.items[0].object.get("value").?.string);
    try testing.expectEqualStrings("2", results.items[1].object.get("value").?.string);
}

test "expr-batch: fewer fields than headers yields empty for missing column" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 3 headers, 1 field: [B]/[C] resolve to indices past the row → "".
    const r = try batchOnBytes(a,
        \\{"headers":["A","B","C"],"fields":["1"],"exprs":["[A]","[B]","[C]"]}
    );
    try testing.expectEqual(@as(u8, 0), r.exit);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, r.json, .{});
    const results = parsed.object.get("results").?.array;
    try testing.expectEqual(@as(usize, 3), results.items.len);
    try testing.expectEqualStrings("1", results.items[0].object.get("value").?.string);
    try testing.expectEqualStrings("", results.items[1].object.get("value").?.string);
    try testing.expectEqualStrings("", results.items[2].object.get("value").?.string);
}
