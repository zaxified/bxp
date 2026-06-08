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
const sim = @import("sim.zig");

pub const Tool = enum {
    bxp_validate,
    bxp_eval,
    bxp_eval_batch,
    bxp_docs,
    bxp_list_templates,
    bxp_fetch_template,
    bxp_simulate,
};

/// Tool catalog as a JSON-RPC `tools/list` result.
pub const tools_list =
    \\{"tools":[
    \\{"name":"bxp_validate","description":"Validate a bxp-cli config (JSON5). Returns annotated JSON with $err_/$warn/$info diagnostics inserted before each offending key.","inputSchema":{"type":"object","properties":{"config":{"type":"string","description":"The full bxp-cli config text (JSON5)."}},"required":["config"]}},
    \\{"name":"bxp_eval","description":"Evaluate one bxp expression against an optional row context. Returns {ok,value} or {ok:false,error,detail,off,len}.","inputSchema":{"type":"object","properties":{"expr":{"type":"string","description":"The expression text, e.g. UPPER('hi') or [Price]*[Qty]."},"headers":{"type":"string","description":"Optional JSON array of column header names, e.g. [\"Price\",\"Qty\"]."},"fields":{"type":"string","description":"Optional JSON array of row field values (parallel to headers)."}},"required":["expr"]}},
    \\{"name":"bxp_eval_batch","description":"Evaluate many bxp expressions against one row in a single call. Returns {results:[{ok,value}|{ok:false,error,detail,off,len}, ...]} aligned to the input order. A well-formed request always succeeds; per-expr failures are carried by each result's ok flag.","inputSchema":{"type":"object","properties":{"headers":{"type":"array","items":{"type":"string"},"description":"Column header names."},"fields":{"type":"array","items":{"type":"string"},"description":"Row field values (parallel to headers; ragged rows tolerated)."},"exprs":{"type":"array","items":{"type":"string"},"description":"Expressions to evaluate against the row."},"ticker_map":{"type":"object","description":"Optional symbol-to-ticker overrides consulted by TICKER()."},"lookups":{"type":"object","description":"Optional flat pre_pass lookup blob for LOOKUP() (NUL-separated name/key/field keys)."},"single_prepass_name":{"type":"string","description":"Optional implicit pre_pass name enabling 2-arg LOOKUP(key, field)."}},"required":["headers","fields","exprs"]}},
    \\{"name":"bxp_docs","description":"Return the full bxp language/schema documentation as JSON (functions, keywords, operators, tokens, config_schema).","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"bxp_list_templates","description":"List every conversion template declared in a bxp-cli config (JSON5). Returns {templates:[{id,data_dir,file_pattern_in,file_pattern_out,file_type_in,file_type_out,description}, ...]}; no semantic validation, so broken templates still appear with an error field.","inputSchema":{"type":"object","properties":{"config":{"type":"string","description":"The full bxp-cli config text (JSON5)."}},"required":["config"]}},
    \\{"name":"bxp_fetch_template","description":"Fetch one conversion template's raw JSON by id from a bxp-cli config (JSON5). Returns the template object, or {\"$err_1\":\"...\"} if the id is absent.","inputSchema":{"type":"object","properties":{"config":{"type":"string","description":"The full bxp-cli config text (JSON5)."},"id":{"type":"string","description":"The template id to fetch."}},"required":["config","id"]}},
    \\{"name":"bxp_simulate","description":"Run a full conversion end-to-end: stage the config (JSON5) + input CSV in a scratch workspace, run the chosen template through bxp-cli, and return the produced output, a record-count diff, and bxp-cli's summary + diagnostics. Verifies a config for real (pre_pass/LOOKUP/row_rules) — what bxp_eval/bxp_validate cannot. CSV-input templates only. ok=true means the run happened; consult exit_code/status/diagnostics (0=ok, 2=warnings, 1=error).","inputSchema":{"type":"object","properties":{"config":{"type":"string","description":"The full bxp-cli config text (JSON5)."},"template":{"type":"string","description":"The conversion template id to run."},"csv":{"type":"string","description":"The input CSV content (becomes the single input file for the run)."},"workspace":{"type":"string","description":"Optional scratch-workspace id (defaults to the template id). Reused across calls, so repeated runs don't litter temp with new dirs."}},"required":["config","template","csv"]}}
    \\]}
;

pub fn parse(name: []const u8) ?Tool {
    if (std.mem.eql(u8, name, "bxp_validate")) return .bxp_validate;
    if (std.mem.eql(u8, name, "bxp_eval")) return .bxp_eval;
    if (std.mem.eql(u8, name, "bxp_eval_batch")) return .bxp_eval_batch;
    if (std.mem.eql(u8, name, "bxp_docs")) return .bxp_docs;
    if (std.mem.eql(u8, name, "bxp_list_templates")) return .bxp_list_templates;
    if (std.mem.eql(u8, name, "bxp_fetch_template")) return .bxp_fetch_template;
    if (std.mem.eql(u8, name, "bxp_simulate")) return .bxp_simulate;
    return null;
}

/// Dispatch a tool call. `args` is the parsed `arguments` object (or .null).
pub fn dispatch(alloc: std.mem.Allocator, tool: Tool, args: std.json.Value, out: *std.ArrayList(u8)) void {
    switch (tool) {
        .bxp_validate => validate(alloc, args, out),
        .bxp_eval => eval(alloc, args, out),
        .bxp_eval_batch => evalBatch(alloc, args, out),
        .bxp_docs => docs(alloc, out),
        .bxp_list_templates => listTemplates(alloc, args, out),
        .bxp_fetch_template => fetchTemplate(alloc, args, out),
        .bxp_simulate => simulate(alloc, args, out),
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

fn evalBatch(alloc: std.mem.Allocator, args: std.json.Value, out: *std.ArrayList(u8)) void {
    // The call arguments object *is* the batch request {headers, fields, exprs,
    // ...} — pass it straight to the shared core (no stdin/serialize round-trip).
    const result = inspect.evalBatch(alloc, args) catch |err| {
        appendErr(alloc, out, @errorName(err));
        return;
    };
    if (result.error_message) |msg| {
        appendErr(alloc, out, msg);
        return;
    }
    out.appendSlice(alloc, result.json) catch {};
}

fn listTemplates(alloc: std.mem.Allocator, args: std.json.Value, out: *std.ArrayList(u8)) void {
    const config = strField(args, "config") orelse {
        appendErr(alloc, out, "missing 'config'");
        return;
    };
    const result = inspect.listTemplates(alloc, config) catch |err| {
        appendErr(alloc, out, @errorName(err));
        return;
    };
    out.appendSlice(alloc, result) catch {};
}

fn fetchTemplate(alloc: std.mem.Allocator, args: std.json.Value, out: *std.ArrayList(u8)) void {
    const config = strField(args, "config") orelse {
        appendErr(alloc, out, "missing 'config'");
        return;
    };
    const id = strField(args, "id") orelse {
        appendErr(alloc, out, "missing 'id'");
        return;
    };
    // The result JSON is the template object on success, or {"$err_1":"..."} for
    // a missing id / unparseable config — both are useful agent-facing content.
    const result = inspect.fetchTemplate(alloc, config, id) catch |err| {
        appendErr(alloc, out, @errorName(err));
        return;
    };
    out.appendSlice(alloc, result.json) catch {};
}

fn simulate(alloc: std.mem.Allocator, args: std.json.Value, out: *std.ArrayList(u8)) void {
    const config = strField(args, "config") orelse {
        appendErr(alloc, out, "missing 'config'");
        return;
    };
    const template = strField(args, "template") orelse {
        appendErr(alloc, out, "missing 'template'");
        return;
    };
    const csv_text = strField(args, "csv") orelse {
        appendErr(alloc, out, "missing 'csv'");
        return;
    };
    const workspace = strField(args, "workspace"); // optional
    // sim.simulate handles its own logical failures as {"ok":false,...} JSON;
    // only OOM/unexpected surfaces here.
    sim.simulate(alloc, config, template, csv_text, workspace, out) catch |err| {
        appendErr(alloc, out, @errorName(err));
    };
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
