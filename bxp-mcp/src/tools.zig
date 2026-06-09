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
const Progress = @import("progress.zig").Progress;

pub const Tool = enum {
    bxp_validate,
    bxp_eval,
    bxp_eval_batch,
    bxp_eval_trace,
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
    \\{"name":"bxp_eval_trace","description":"Evaluate one bxp expression with a per-call execution trace. Returns NDJSON (one JSON object per line): one {\"fn\",\"src_start\",\"src_end\",\"value\"} line per function call as the engine evaluates inside-out, then a terminal line — {\"t\":\"final\",\"value\":\"...\"} on success or {\"t\":\"error\",\"error\",\"detail\",\"off\",\"len\"} on failure. Use to debug HOW a complex expression computes its result, beyond bxp_eval's final value.","inputSchema":{"type":"object","properties":{"expr":{"type":"string","description":"The expression text."},"headers":{"type":"string","description":"Optional JSON array of column header names, e.g. [\"Price\",\"Qty\"]."},"fields":{"type":"string","description":"Optional JSON array of row field values (parallel to headers)."}},"required":["expr"]}},
    \\{"name":"bxp_docs","description":"Return the full bxp language/schema documentation as JSON (functions, keywords, operators, tokens, config_schema).","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"bxp_list_templates","description":"List every conversion template declared in a bxp-cli config (JSON5). Returns {templates:[{id,data_dir,file_pattern_in,file_pattern_out,file_type_in,file_type_out,description}, ...]}; no semantic validation, so broken templates still appear with an error field.","inputSchema":{"type":"object","properties":{"config":{"type":"string","description":"The full bxp-cli config text (JSON5)."}},"required":["config"]}},
    \\{"name":"bxp_fetch_template","description":"Fetch one conversion template's raw JSON by id from a bxp-cli config (JSON5). Returns the template object, or {\"$err_1\":\"...\"} if the id is absent.","inputSchema":{"type":"object","properties":{"config":{"type":"string","description":"The full bxp-cli config text (JSON5)."},"id":{"type":"string","description":"The template id to fetch."}},"required":["config","id"]}},
    \\{"name":"bxp_simulate","description":"Run a full conversion end-to-end: stage the config (JSON5) + input CSV in a scratch workspace, run the chosen template through bxp-cli, and return the produced output, a record-count diff, bxp-cli's summary + diagnostics, and a per-row `trace` (BXTB sidecar): for each input row whether it was written, filtered (with reason: rule_skip / no_rule_match), or errored — each carrying the 1-based input-line number. Verifies a config for real (pre_pass/LOOKUP/row_rules) — what bxp_eval/bxp_validate cannot. CSV-input templates only. ok=true means the run happened; consult exit_code/status/diagnostics (0=ok, 2=warnings, 1=error).","inputSchema":{"type":"object","properties":{"config":{"type":"string","description":"The full bxp-cli config text (JSON5)."},"template":{"type":"string","description":"The conversion template id to run."},"csv":{"type":"string","description":"The input CSV content (becomes the single input file for the run)."},"workspace":{"type":"string","description":"Optional scratch-workspace id (defaults to the template id). Reused across calls, so repeated runs don't litter temp with new dirs."}},"required":["config","template","csv"]},"outputSchema":{"type":"object","properties":{"ok":{"type":"boolean"},"template":{"type":"string"},"exit_code":{"type":"integer"},"status":{"type":"string","enum":["ok","warnings","error"]},"input":{"type":"object","properties":{"records":{"type":"integer","description":"Data rows in the input CSV (header excluded), so it lines up with trace.source_rows."},"csv":{"type":"string"}}},"output_records":{"type":"integer","description":"Total data rows across all output files (each file's header excluded), comparable to trace.written_rows."},"outputs":{"type":"array","items":{"type":"object","properties":{"file":{"type":"string"},"records":{"type":"integer"},"csv":{"type":"string"},"error":{"type":"string","description":"Present instead of csv/records when the output file could not be read back (e.g. exceeds the 16 MB cap)."}}}},"summary":{"type":"string"},"diagnostics":{"type":"string"},"trace":{"type":"object","properties":{"available":{"type":"boolean"},"source_rows":{"type":"integer"},"written_rows":{"type":"integer"},"errors":{"type":"integer"},"warnings":{"type":"integer"},"filtered":{"type":"object","properties":{"count":{"type":"integer"},"sample":{"type":"array","items":{"type":"object","properties":{"input_row":{"type":"integer"},"source_offset":{"type":"integer"},"reason":{"type":"string"}}}}}},"row_errors":{"type":"object","properties":{"count":{"type":"integer"},"sample":{"type":"array","items":{"type":"object","properties":{"input_row":{"type":"integer"},"source_offset":{"type":"integer"},"variable":{"type":"string"},"kind":{"type":"string"},"detail":{"type":"string"},"origin":{"type":"string"}}}}}},"output_rows":{"type":"object","properties":{"count":{"type":"integer"},"sample":{"type":"array","items":{"type":"object","properties":{"input_row":{"type":"integer"},"source_offset":{"type":"integer"},"output_idx":{"type":"integer"},"rule":{"type":"integer"},"action":{"type":"string"}}}}}},"prepass_entries":{"type":"integer"}}},"workspace":{"type":"string"},"error":{"type":"string"},"detail":{"type":"string"}}}}
    \\]}
;

/// Whether a tool's textual result is a single top-level JSON object eligible
/// for MCP `structuredContent`. `bxp_eval_trace` streams NDJSON (many lines, or
/// a single sentinel line for a function-free expression) — its shape is a
/// stream, not one object, so it stays text-only regardless of how few lines a
/// trivial expression happens to produce. Deciding by tool identity (not by
/// brace-scanning the output) keeps the contract stable.
pub fn allowsStructured(tool: Tool) bool {
    return tool != .bxp_eval_trace;
}

pub fn parse(name: []const u8) ?Tool {
    if (std.mem.eql(u8, name, "bxp_validate")) return .bxp_validate;
    if (std.mem.eql(u8, name, "bxp_eval")) return .bxp_eval;
    if (std.mem.eql(u8, name, "bxp_eval_batch")) return .bxp_eval_batch;
    if (std.mem.eql(u8, name, "bxp_eval_trace")) return .bxp_eval_trace;
    if (std.mem.eql(u8, name, "bxp_docs")) return .bxp_docs;
    if (std.mem.eql(u8, name, "bxp_list_templates")) return .bxp_list_templates;
    if (std.mem.eql(u8, name, "bxp_fetch_template")) return .bxp_fetch_template;
    if (std.mem.eql(u8, name, "bxp_simulate")) return .bxp_simulate;
    return null;
}

/// Dispatch a tool call. `args` is the parsed `arguments` object (or .null).
/// `prog` carries the request's progressToken (null when the client supplied
/// none); only `bxp_simulate` reports progress today.
///
/// Returns `true` when the result is a tool *failure* (a missing required
/// argument, an unexpected Zig error, a spawn/IO failure) so the caller can set
/// MCP `isError:true`. A domain result the tool produced on purpose —
/// `{"ok":false,...}` from an expression error or an orchestration report — is
/// *not* a failure (`false`): it is a valid answer the agent should read.
pub fn dispatch(alloc: std.mem.Allocator, tool: Tool, args: std.json.Value, prog: ?Progress, out: *std.ArrayList(u8)) bool {
    return switch (tool) {
        .bxp_validate => validate(alloc, args, out),
        .bxp_eval => eval(alloc, args, out),
        .bxp_eval_batch => evalBatch(alloc, args, out),
        .bxp_eval_trace => evalTrace(alloc, args, out),
        .bxp_docs => docs(alloc, out),
        .bxp_list_templates => listTemplates(alloc, args, out),
        .bxp_fetch_template => fetchTemplate(alloc, args, out),
        .bxp_simulate => simulate(alloc, args, prog, out),
    };
}

// ── tools ────────────────────────────────────────────────────────────────────

fn validate(alloc: std.mem.Allocator, args: std.json.Value, out: *std.ArrayList(u8)) bool {
    const config = strField(args, "config") orelse return appendErr(alloc, out, "missing 'config'");
    // check_fs = 0: pure structural/expression validation, no filesystem
    // syscalls (the agent is validating config text, not a deployed tree).
    const result = inspect.annotateRaw(alloc, config, "<config>", 0) catch |err|
        return appendErr(alloc, out, @errorName(err));
    out.appendSlice(alloc, result.json) catch {};
    return false;
}

fn eval(alloc: std.mem.Allocator, args: std.json.Value, out: *std.ArrayList(u8)) bool {
    const expr = strField(args, "expr") orelse return appendErr(alloc, out, "missing 'expr'");
    const headers = strField(args, "headers");
    const fields = strField(args, "fields");
    const result = inspect.evalExpr(alloc, expr, headers, fields) catch |err|
        return appendErr(alloc, out, @errorName(err));
    out.appendSlice(alloc, result) catch {};
    return false;
}

fn docs(alloc: std.mem.Allocator, out: *std.ArrayList(u8)) bool {
    const result = inspect.docsJson(alloc) catch |err|
        return appendErr(alloc, out, @errorName(err));
    out.appendSlice(alloc, result) catch {};
    return false;
}

fn evalBatch(alloc: std.mem.Allocator, args: std.json.Value, out: *std.ArrayList(u8)) bool {
    // The call arguments object *is* the batch request {headers, fields, exprs,
    // ...} — pass it straight to the shared core (no stdin/serialize round-trip).
    const result = inspect.evalBatch(alloc, args) catch |err|
        return appendErr(alloc, out, @errorName(err));
    if (result.error_message) |msg| return appendErr(alloc, out, msg);
    out.appendSlice(alloc, result.json) catch {};
    return false;
}

fn evalTrace(alloc: std.mem.Allocator, args: std.json.Value, out: *std.ArrayList(u8)) bool {
    const expr = strField(args, "expr") orelse return appendErr(alloc, out, "missing 'expr'");
    const headers = strField(args, "headers");
    const fields = strField(args, "fields");
    // Collect the NDJSON stream (per-call traces + final sentinel) into a buffer
    // and append the error sentinel (if any) so the agent gets the whole trace
    // plus outcome in one blob — the MCP analogue of fmt's stdout+stderr split.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const result = inspect.evalTrace(alloc, expr, headers, fields, &aw.writer) catch |err|
        return appendErr(alloc, out, @errorName(err));
    const trace = aw.toOwnedSlice() catch return appendErr(alloc, out, "OutOfMemory");
    out.appendSlice(alloc, trace) catch {};
    // An expression-error sentinel is a domain result the agent should read, not
    // a tool failure — the call succeeded in producing the trace.
    if (result.error_json) |ej| {
        out.appendSlice(alloc, ej) catch {};
        out.appendSlice(alloc, "\n") catch {};
    }
    return false;
}

fn listTemplates(alloc: std.mem.Allocator, args: std.json.Value, out: *std.ArrayList(u8)) bool {
    const config = strField(args, "config") orelse return appendErr(alloc, out, "missing 'config'");
    const result = inspect.listTemplates(alloc, config) catch |err|
        return appendErr(alloc, out, @errorName(err));
    out.appendSlice(alloc, result) catch {};
    return false;
}

fn fetchTemplate(alloc: std.mem.Allocator, args: std.json.Value, out: *std.ArrayList(u8)) bool {
    const config = strField(args, "config") orelse return appendErr(alloc, out, "missing 'config'");
    const id = strField(args, "id") orelse return appendErr(alloc, out, "missing 'id'");
    // The result JSON is the template object on success, or {"$err_1":"..."} for
    // a missing id / unparseable config — both are useful agent-facing content
    // (a present-but-not-found id is a domain answer, not a tool failure).
    const result = inspect.fetchTemplate(alloc, config, id) catch |err|
        return appendErr(alloc, out, @errorName(err));
    out.appendSlice(alloc, result.json) catch {};
    return false;
}

fn simulate(alloc: std.mem.Allocator, args: std.json.Value, prog: ?Progress, out: *std.ArrayList(u8)) bool {
    const config = strField(args, "config") orelse return appendErr(alloc, out, "missing 'config'");
    const template = strField(args, "template") orelse return appendErr(alloc, out, "missing 'template'");
    const csv_text = strField(args, "csv") orelse return appendErr(alloc, out, "missing 'csv'");
    const workspace = strField(args, "workspace"); // optional
    // sim.simulate handles its own logical failures as {"ok":false,...} JSON (a
    // domain result, isError:false); only OOM/unexpected surfaces here as a
    // genuine tool failure.
    sim.simulate(alloc, config, template, csv_text, workspace, prog, out) catch |err|
        return appendErr(alloc, out, @errorName(err));
    return false;
}

// ── helpers ──────────────────────────────────────────────────────────────────

fn strField(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    return switch (v.object.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Write a tool-failure message and return `true` (the dispatch `isError` flag),
/// so handlers can `return appendErr(...)` on every failure path.
fn appendErr(alloc: std.mem.Allocator, out: *std.ArrayList(u8), msg: []const u8) bool {
    out.appendSlice(alloc, "error: ") catch {};
    out.appendSlice(alloc, msg) catch {};
    return true;
}
