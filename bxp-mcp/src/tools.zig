// bxp-mcp — tool handlers (in-process, no spawn)
//
// Each tool calls the shared bxp-core `inspect` module directly — the same
// stateless action core bxp-fmt's CLI wraps. No subprocess: a tool call is a
// function call, so latency is microseconds, not a process spawn.
//
// Handlers take the already-parsed `arguments` object (std.json.Value) and
// write the tool's textual result into `out`.

const std = @import("std");
const inspect = @import("inspect");

pub const Tool = enum { bxp_validate, bxp_eval, bxp_docs };

/// Tool catalog as a JSON-RPC `tools/list` result.
pub const tools_list =
    \\{"tools":[
    \\{"name":"bxp_validate","description":"Validate a bxp-cli config (JSON5). Returns annotated JSON with $err_/$warn/$info diagnostics inserted before each offending key.","inputSchema":{"type":"object","properties":{"config":{"type":"string","description":"The full bxp-cli config text (JSON5)."}},"required":["config"]}},
    \\{"name":"bxp_eval","description":"Evaluate one bxp expression against an optional row context. Returns {ok,value} or {ok:false,error,detail,off,len}.","inputSchema":{"type":"object","properties":{"expr":{"type":"string","description":"The expression text, e.g. UPPER('hi') or [Price]*[Qty]."},"headers":{"type":"string","description":"Optional JSON array of column header names, e.g. [\"Price\",\"Qty\"]."},"fields":{"type":"string","description":"Optional JSON array of row field values (parallel to headers)."}},"required":["expr"]}},
    \\{"name":"bxp_docs","description":"Return the full bxp language/schema documentation as JSON (functions, keywords, operators, tokens, config_schema).","inputSchema":{"type":"object","properties":{},"required":[]}}
    \\]}
;

pub fn parse(name: []const u8) ?Tool {
    if (std.mem.eql(u8, name, "bxp_validate")) return .bxp_validate;
    if (std.mem.eql(u8, name, "bxp_eval")) return .bxp_eval;
    if (std.mem.eql(u8, name, "bxp_docs")) return .bxp_docs;
    return null;
}

/// Dispatch a tool call. `args` is the parsed `arguments` object (or .null).
pub fn dispatch(alloc: std.mem.Allocator, tool: Tool, args: std.json.Value, out: *std.ArrayList(u8)) void {
    switch (tool) {
        .bxp_validate => validate(alloc, args, out),
        .bxp_eval => eval(alloc, args, out),
        .bxp_docs => docs(alloc, out),
    }
}

// ── tools ────────────────────────────────────────────────────────────────────

fn validate(alloc: std.mem.Allocator, args: std.json.Value, out: *std.ArrayList(u8)) void {
    const config = strField(args, "config") orelse {
        appendErr(alloc, out, "missing 'config'");
        return;
    };
    // check_fs = 0: pure structural/expression validation, no filesystem
    // syscalls (the agent is validating config text, not a deployed tree).
    const result = inspect.annotateRaw(alloc, config, "<config>", 0) catch |err| {
        appendErr(alloc, out, @errorName(err));
        return;
    };
    out.appendSlice(alloc, result.json) catch {};
}

fn eval(alloc: std.mem.Allocator, args: std.json.Value, out: *std.ArrayList(u8)) void {
    const expr = strField(args, "expr") orelse {
        appendErr(alloc, out, "missing 'expr'");
        return;
    };
    const headers = strField(args, "headers");
    const fields = strField(args, "fields");
    const result = inspect.evalExpr(alloc, expr, headers, fields) catch |err| {
        appendErr(alloc, out, @errorName(err));
        return;
    };
    out.appendSlice(alloc, result) catch {};
}

fn docs(alloc: std.mem.Allocator, out: *std.ArrayList(u8)) void {
    const result = inspect.docsJson(alloc) catch |err| {
        appendErr(alloc, out, @errorName(err));
        return;
    };
    out.appendSlice(alloc, result) catch {};
}

// ── helpers ──────────────────────────────────────────────────────────────────

fn strField(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    return switch (v.object.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn appendErr(alloc: std.mem.Allocator, out: *std.ArrayList(u8), msg: []const u8) void {
    out.appendSlice(alloc, "error: ") catch {};
    out.appendSlice(alloc, msg) catch {};
}
