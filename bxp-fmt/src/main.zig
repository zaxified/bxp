/// bxp-fmt — config and expression utility for bxp-cli.
///
/// See `../CLAUDE.md` for the authoritative subcommand reference, exit-code
/// table, and annotated-JSON output spec. Run `bxp-fmt --help` for the
/// runtime usage summary.
const std = @import("std");
const builtin = @import("builtin");
const config_mod = @import("config");
const expr_mod = @import("expr");
const json5_mod = @import("json5");
const docs_mod = @import("docs");
const diagnostics_mod = @import("diagnostics");
const inspect = @import("inspect");
const build_options = @import("build_options");

// The config-annotation pipeline, single-expression eval, and docs serializer
// were factored into bxp-core's `inspect` module so bxp-fmt (CLI adapter) and
// bxp-mcp (MCP server adapter) share one implementation. This alias keeps the
// inline `annotateRaw` tests below reading naturally.
const annotateRaw = inspect.annotateRaw;

const CONFIG_MAX_FILE_SIZE = 1024 * 1024; // 1 MB

/// Write `bytes` to stdout, handling Windows pipe-overflow correctly.
///
/// Why this exists: when bxp-fmt is launched as a child of bxp-gui (or
/// any Dart `Process.run` consumer on Windows), the parent opens the
/// stdout pipe with `FILE_FLAG_OVERLAPPED`. The kernel then returns
/// `IO_PENDING` from `WriteFile` once the small ~4 KB pipe buffer
/// fills, even though our handle is nominally synchronous. Zig 0.15.x
/// std panics on this path (`std/os/windows.zig:699 IO_PENDING =>
/// unreachable`), so any subcommand that emits more than one buffer's
/// worth of output to a captured stdout would crash the binary with
/// `STATUS_BREAKPOINT` partway through. `--docs` (~30 KB) reproduces
/// this every launch.
///
/// Workaround: bypass `std.fs.File.write` entirely. Provide a real
/// `OVERLAPPED` struct with an event handle on every `WriteFile` call
/// so we can actually wait for `IO_PENDING` to complete via
/// `WaitForSingleObject` + `GetOverlappedResult`. Outside Windows we
/// fall back to the regular blocking write.
fn writeAllToStdoutPipeAware(bytes: []const u8) error{WriteFailed}!void {
    if (bytes.len == 0) return;
    if (builtin.os.tag != .windows) {
        std.fs.File.stdout().writeAll(bytes) catch return error.WriteFailed;
        return;
    }
    const w = std.os.windows;
    const k = w.kernel32;
    const handle = w.GetStdHandle(w.STD_OUTPUT_HANDLE) catch return error.WriteFailed;

    // Auto-reset event, initial state not-signaled. dwFlags = 0,
    // EVENT_ALL_ACCESS = 0x1F0003.
    const ev = k.CreateEventExW(null, null, 0, 0x1F0003) orelse return error.WriteFailed;
    defer w.CloseHandle(ev);

    var written: usize = 0;
    while (written < bytes.len) {
        var ovl: w.OVERLAPPED = std.mem.zeroes(w.OVERLAPPED);
        ovl.hEvent = ev;
        var bw: w.DWORD = 0;
        const remaining = bytes.len - written;
        const chunk_len: u32 = @intCast(@min(remaining, std.math.maxInt(u32)));
        const rc = k.WriteFile(handle, bytes.ptr + written, chunk_len, &bw, &ovl);
        if (rc == 0) {
            const err = k.GetLastError();
            if (err == .IO_PENDING) {
                _ = k.WaitForSingleObject(ev, w.INFINITE);
                if (k.GetOverlappedResult(handle, &ovl, &bw, 0) == 0) {
                    return error.WriteFailed;
                }
            } else {
                return error.WriteFailed;
            }
        }
        if (bw == 0) return error.WriteFailed;
        written += bw;
    }
}

/// Help text body. Two stream variants below pick which file descriptor
/// it lands on — same split as bxp-cli's printHelp / usageErr.
const USAGE_TEMPLATE =
    \\bxp-fmt — config and expression utility for bxp-cli
    \\
    \\Usage (exactly one action flag):
    \\  bxp-fmt --config <path>                  validate config; emit annotated JSON to stdout
    \\  bxp-fmt --expr '<text>'                  validate one expression; stderr JSON on error
    \\  bxp-fmt --expr-trace '<text>'            evaluate one expression and stream NDJSON traces
    \\                                           (optional --row-headers <json>, --row-fields <json>)
    \\  bxp-fmt --expr-batch                     evaluate N expressions against one row from a JSON
    \\                                           request on stdin; emit JSON results array on stdout
    \\  bxp-fmt --docs                           emit full language/schema documentation as JSON
    \\  bxp-fmt --config <path> --list-templates emit JSON list of templates declared in config
    \\  bxp-fmt --config <path> --fetch-template <id>
    \\                                           emit one template block as JSON
    \\
    \\Options:
    \\  --version                 print version and exit
    \\  --help                    print this help and exit
    \\
    \\Value-taking options accept either `--name value` or `--name=value`.
    \\
    \\Exit codes:
    \\  0 - success
    \\  1 - validation failure / template id not found
    \\  2 - usage error
    \\
;

/// Print the help text to stdout. Used for `--help` so callers piping
/// `bxp-fmt --help | grep` work without `2>&1`.
fn printHelp() void {
    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const w = &fw.interface;
    w.writeAll(USAGE_TEMPLATE) catch {};
    w.flush() catch {};
}

/// Print the help text to stderr. Used after an argument-validation
/// failure where we want the usage to accompany the error message.
fn usageErr() void {
    std.debug.print("{s}", .{USAGE_TEMPLATE});
}

/// Result of matching a value-taking flag against `args[i_ptr.*]`. Mirrors
/// the helper in `bxp-cli/src/main.zig` so both binaries accept the same
/// `--name value` / `--name=value` forms.
const ArgMatch = union(enum) {
    no_match,
    missing_value,
    value: []const u8,
};

/// Matches `--name VALUE` (space form, advances `i_ptr` past VALUE) or
/// `--name=VALUE` (equals form, `i_ptr` unchanged). Returns `.missing_value`
/// when the space form matches but no following argument exists; returns
/// `.no_match` when `arg` does not match `name` in either form.
fn matchValueArg(args: [][:0]u8, i_ptr: *usize, name: []const u8) ArgMatch {
    const arg = args[i_ptr.*];
    if (std.mem.eql(u8, arg, name)) {
        if (i_ptr.* + 1 >= args.len) return .missing_value;
        i_ptr.* += 1;
        return .{ .value = args[i_ptr.*] };
    }
    if (arg.len > name.len and arg[name.len] == '=' and std.mem.startsWith(u8, arg, name)) {
        return .{ .value = arg[name.len + 1 ..] };
    }
    return .no_match;
}

// Returning `!u8` (rather than `!void` + `std.process.exit`) so the
// process exits via main's natural return path. `std.process.exit` is
// `_exit`-style — it skips every deferred cleanup, including
// `gpa.deinit()`'s leak report. Routing failures through return values
// lets the DebugAllocator catch leaks on every error path, not just
// the success path. Subroutines (`runX`) follow the same convention.
pub fn main() !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var config_path: ?[]const u8 = null;
    var expr_src: ?[]const u8 = null;
    var expr_trace_src: ?[]const u8 = null;
    var expr_batch = false;
    var row_headers_json: ?[]const u8 = null;
    var row_fields_json: ?[]const u8 = null;
    var emit_docs = false;
    var list_templates = false;
    var fetch_template_id: ?[]const u8 = null;
    // Filesystem validation timeout in seconds. Zero = disabled (default).
    // GUI passes `--check-fs=2` on every load/save; manual / scripted
    // callers opt in only when they want load-time data_dir + input-file
    // existence diagnostics.
    var check_fs_seconds: u8 = 0;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            printHelp();
            return 0;
        }
        if (std.mem.eql(u8, a, "--version")) {
            // Match bxp-cli: write to stdout, not stderr. Tooling that
            // captures `--version` output (the GUI's runtime info panel)
            // expects stdout per the CLI convention.
            var stdout_buf: [64]u8 = undefined;
            var stdout_fw = std.fs.File.stdout().writer(&stdout_buf);
            const stdout = &stdout_fw.interface;
            stdout.print("bxp-fmt {s}\n", .{build_options.version}) catch {};
            stdout.flush() catch {};
            return 0;
        }
        if (std.mem.eql(u8, a, "--docs")) {
            emit_docs = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--expr-batch")) {
            expr_batch = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--list-templates")) {
            list_templates = true;
            continue;
        }
        // Value-taking flags accept both `--name value` and `--name=value`.
        switch (matchValueArg(args, &i, "--config")) {
            .value => |v| { config_path = v; continue; },
            .missing_value => {
                std.debug.print("error: --config requires a path\n", .{});
                return 2;
            },
            .no_match => {},
        }
        switch (matchValueArg(args, &i, "--expr")) {
            .value => |v| { expr_src = v; continue; },
            .missing_value => {
                std.debug.print("error: --expr requires an expression string\n", .{});
                return 2;
            },
            .no_match => {},
        }
        switch (matchValueArg(args, &i, "--expr-trace")) {
            .value => |v| { expr_trace_src = v; continue; },
            .missing_value => {
                std.debug.print("error: --expr-trace requires an expression string\n", .{});
                return 2;
            },
            .no_match => {},
        }
        switch (matchValueArg(args, &i, "--row-headers")) {
            .value => |v| { row_headers_json = v; continue; },
            .missing_value => {
                std.debug.print("error: --row-headers requires a JSON array string\n", .{});
                return 2;
            },
            .no_match => {},
        }
        switch (matchValueArg(args, &i, "--row-fields")) {
            .value => |v| { row_fields_json = v; continue; },
            .missing_value => {
                std.debug.print("error: --row-fields requires a JSON array string\n", .{});
                return 2;
            },
            .no_match => {},
        }
        switch (matchValueArg(args, &i, "--fetch-template")) {
            .value => |v| { fetch_template_id = v; continue; },
            .missing_value => {
                std.debug.print("error: --fetch-template requires a template id\n", .{});
                return 2;
            },
            .no_match => {},
        }
        switch (matchValueArg(args, &i, "--check-fs")) {
            .value => |v| {
                check_fs_seconds = std.fmt.parseUnsigned(u8, v, 10) catch {
                    std.debug.print("error: --check-fs requires a non-negative integer (seconds): got '{s}'\n", .{v});
                    return 2;
                };
                continue;
            },
            .missing_value => {
                std.debug.print("error: --check-fs requires a non-negative integer (seconds) argument\n", .{});
                return 2;
            },
            .no_match => {},
        }
        std.debug.print("error: unknown argument: {s}\n", .{a});
        usageErr();
        return 2;
    }

    // --list-templates and --fetch-template are modifiers on --config; the
    // bare --config (with neither modifier) is its own validate-and-emit
    // action. Modifiers are mutually exclusive with each other.
    const fetch_active = fetch_template_id != null;
    const config_modifier_count = @as(u8, if (list_templates) 1 else 0) + @as(u8, if (fetch_active) 1 else 0);
    if (config_modifier_count > 1) {
        std.debug.print("error: --list-templates and --fetch-template are mutually exclusive\n", .{});
        return 2;
    }

    // `has_config_action` is true only for bare --config (no modifier),
    // so it counts as exactly one independent action alongside --expr /
    // --docs / etc. A config modifier pair (--config + --list-templates)
    // also counts as exactly one action via `config_modifier_count > 0`.
    const has_config_action = config_path != null and config_modifier_count == 0;
    const action_count = @as(u8, if (has_config_action) 1 else 0) +
        @as(u8, if (expr_src != null) 1 else 0) +
        @as(u8, if (expr_trace_src != null) 1 else 0) +
        @as(u8, if (expr_batch) 1 else 0) +
        @as(u8, if (emit_docs) 1 else 0) +
        @as(u8, if (config_modifier_count > 0) 1 else 0);

    if (action_count > 1) {
        std.debug.print("error: --config, --expr, --expr-trace, --expr-batch, --docs, --list-templates, and --fetch-template are mutually exclusive\n", .{});
        return 2;
    }
    if (action_count == 0) {
        usageErr();
        return 2;
    }

    // Dispatch: modifiers are checked first because they share --config
    // but route to different handlers. Plain --config falls through to
    // the `config_path` branch below.
    if (config_modifier_count > 0) {
        const path = config_path orelse {
            std.debug.print("error: --list-templates / --fetch-template require --config <path>\n", .{});
            return 2;
        };
        if (fetch_active) {
            return try runFetchTemplate(alloc, path, fetch_template_id.?);
        } else {
            return try runListTemplates(alloc, path);
        }
    }
    if (emit_docs) {
        return try runDocs(alloc);
    }
    if (config_path) |p| {
        return try runConfig(alloc, p, check_fs_seconds);
    }
    if (expr_src) |e| {
        return try runExpr(alloc, e);
    }
    if (expr_trace_src) |e| {
        return try runExprTrace(alloc, e, row_headers_json, row_fields_json);
    }
    if (expr_batch) {
        return try runExprBatch(alloc);
    }
    // Unreachable — action_count > 0 ensures one of the above fires, but
    // the compiler needs an explicit return for `!u8` exhaustiveness.
    return 0;
}

// ── --docs ──────────────────────────────────────────────────────────────────

fn runDocs(gpa: std.mem.Allocator) !u8 {
    // Arena owns the json5/parseFromSlice scratch space for every
    // insert_template snippet. Freed wholesale on return.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // Buffer the entire ~30 KB --docs JSON in memory before writing
    // it to stdout. The single-shot dump goes through
    // `writeAllToStdoutPipeAware`, which handles the Windows
    // overlapped-pipe `IO_PENDING` case that std's buffered file
    // writer panics on (see helper at the top of this file).
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try docs_mod.writeDocs(arena.allocator(), &aw.writer);
    try writeAllToStdoutPipeAware(aw.writer.buffered());
    return 0;
}

// ── --list-templates / --fetch-template ─────────────────────────────────────
//
// Read a JSON5 config, parse it without semantic validation, and emit either
// a summary of every template (--list-templates) or one full template block
// (--fetch-template). Both paths use the same JSON5 → JSON pipeline as
// runConfig but skip the BrokerConfig load — invalid templates still appear
// in the listing so the GUI can show "(broken)" rows.

/// Reads the config file and parses it into a std.json.Value tree.
/// On any I/O or JSON5 error, prints `{"error":"<name>"}` to `stdout`
/// and returns `error.ConfigLoadFailed`. Callers translate that error
/// into exit code 1 — propagating via error union (rather than calling
/// `std.process.exit`) keeps `gpa.deinit()` in the picture.
fn loadConfigValue(a: std.mem.Allocator, path: []const u8, stdout: *std.Io.Writer) !std.json.Value {
    const raw = readFileCapped(a, path) catch |err| {
        try emitRootErr(stdout, @errorName(err));
        return error.ConfigLoadFailed;
    };
    const json_text = json5_mod.preprocess(a, raw) catch |err| {
        try emitRootErr(stdout, @errorName(err));
        return error.ConfigLoadFailed;
    };
    return std.json.parseFromSliceLeaky(std.json.Value, a, json_text, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| {
        try emitRootErr(stdout, @errorName(err));
        return error.ConfigLoadFailed;
    };
}

fn runListTemplates(alloc: std.mem.Allocator, path: []const u8) !u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_fw.interface;

    const root = loadConfigValue(a, path, stdout) catch |err| switch (err) {
        error.ConfigLoadFailed => return 1,
        else => return err,
    };

    // Listing logic lives in `inspect` (shared with the MCP bxp_list_templates
    // tool); this handler only owns file load + stdout.
    const json = try inspect.listTemplatesValue(a, root);
    try stdout.writeAll(json);
    try stdout.writeByte('\n');
    try stdout.flush();
    return 0;
}

fn runFetchTemplate(alloc: std.mem.Allocator, path: []const u8, id: []const u8) !u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_fw.interface;

    const root = loadConfigValue(a, path, stdout) catch |err| switch (err) {
        error.ConfigLoadFailed => return 1,
        else => return err,
    };

    // Fetch logic lives in `inspect` (shared with the MCP bxp_fetch_template
    // tool). The id-not-found case additionally gets a stderr line that names
    // the config path here — the pure core does not know it. stdout carries the
    // machine-parseable JSON (template, or {"$err_1":...}) bxp-gui reads.
    const r = try inspect.fetchTemplateValue(a, root, id);
    if (r.not_found) {
        std.debug.print("error: template id '{s}' not found in {s}\n", .{ id, path });
    }
    try stdout.writeAll(r.json);
    try stdout.writeByte('\n');
    try stdout.flush();
    return r.exit_code;
}

// ── --config ─────────────────────────────────────────────────────────────────
//
// Outputs annotated JSON to stdout:
//   - Valid config   → full parsed JSON with $comm_<N> entries for comments, exit 0
//   - Syntax error   → {"$err_1":"<message>"}, exit 1
//   - Semantic error → full parsed JSON with $err_<N> sibling entries inserted
//                      immediately before each offending key, exit 1
//
// $comm_<N> and $err_<N> share a single monotonically-increasing counter so all
// keys are unique. stderr still receives human-readable diagnostics from the
// JSON5/config parser.

fn runConfig(alloc: std.mem.Allocator, path: []const u8, check_fs_seconds: u8) !u8 {
    // Arena for all allocations — freed on exit.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_fw.interface;

    const result = try inspect.annotateConfigFromFile(a, path, check_fs_seconds);
    try stdout.writeAll(result.json);
    try stdout.writeByte('\n');
    try stdout.flush();
    return result.exit_code;
}

/// Emit a structured expression-error JSON line to stderr (with trailing
/// newline + flush). Used by `runExpr` (eval failure + SPLIT_PART /
/// DATE_CONVERT static-check failures) and `runExprTrace` (error sentinel).
///
/// `t` is null for `runExpr` (plain `{error, detail, off?, len?}`) and
/// `"error"` for `runExprTrace` (NDJSON sentinel `{t:"error", error, detail,
/// off?, len?}`). `off`/`len` are emitted only when `len > 0` — mirrors the
/// bridge's `writeExprErrorJson` / `writeStaticErrorJson` shape so editor
/// highlight behaves identically across all four entry points.
///
/// All writes use `catch {}` because the caller is already on an error path
/// and the non-zero exit code is the authoritative signal.
fn writeExprErrorJsonToStderr(
    stderr: *std.Io.Writer,
    t: ?[]const u8,
    err_name: []const u8,
    detail: []const u8,
    off: u32,
    len: u32,
) void {
    var jw: std.json.Stringify = .{ .writer = stderr, .options = .{} };
    jw.beginObject() catch {};
    if (t) |tt| {
        jw.objectField("t") catch {};
        jw.write(tt) catch {};
    }
    jw.objectField("error") catch {};
    jw.write(err_name) catch {};
    jw.objectField("detail") catch {};
    jw.write(detail) catch {};
    if (len > 0) {
        jw.objectField("off") catch {};
        jw.write(off) catch {};
        jw.objectField("len") catch {};
        jw.write(len) catch {};
    }
    jw.endObject() catch {};
    stderr.writeByte('\n') catch {};
    stderr.flush() catch {};
}

/// Emit `{"$err_1":"<msg>"}` to stdout with newline + flush, then caller
/// exits. Used by non-`--config` actions (`--list-templates`,
/// `--fetch-template`, `--expr-trace` config-loading guard) where the
/// output never contains annotated `$comm_*`/`$err_*` siblings — this is
/// the **only** entry in the emitted document, so counter `1` cannot
/// collide with anything. Mirrors `formatRootErr`'s contract on the
/// stdout-writer side.
fn emitRootErr(stdout: *std.Io.Writer, msg: []const u8) !void {
    try stdout.print("{{\"$err_1\":", .{});
    try writeJsonString(stdout, msg);
    try stdout.print("}}\n", .{});
    try stdout.flush();
}

/// Read file into arena-allocated buffer, capped at CONFIG_MAX_FILE_SIZE.
fn readFileCapped(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(a, CONFIG_MAX_FILE_SIZE);
}

/// Write a JSON-encoded string (with surrounding quotes and escaped special chars).
/// Per RFC 8259 §7, control characters U+0000..U+001F MUST be escaped — broker CSV
/// exports occasionally carry stray bytes (e.g. `\x07` bell) and emitting them raw
/// would produce invalid JSON for the GUI to consume.
fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

// ── --expr ───────────────────────────────────────────────────────────────────

/// Parse + evaluate the expression with an empty Context.
/// Expressions that reference [ColumnName] or $var will fail because the context
/// has no fields — that is the intended behavior for a bare syntax check.
fn runExpr(gpa: std.mem.Allocator, src: []const u8) !u8 {
    var stdout_buf: [64]u8 = undefined;
    var stdout_fw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_fw.interface;
    var stderr_buf: [4096]u8 = undefined;
    var stderr_fw = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_fw.interface;

    // Arena collects every transient allocation made during expression
    // evaluation (string concat, error_detail formatting, ...). The tool
    // exits immediately after this call, so freeing per-allocation is
    // needless overhead — and DebugAllocator's leak report would mask
    // real bugs if we tracked them individually.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Validation core (runtime eval + static FnArgDoc checks) lives in
    // inspect.validateExpr, shared with the bridge's bridge_eval_expr so
    // editor-time and CLI diagnostics stay in sync. This handler only routes:
    // error JSON → stderr (stdout stays empty on failure so callers can check
    // the exit code without parsing); token off/len highlight the offending
    // span in the GUI ExprPanel, emitted only when the parser pinned one.
    if (try inspect.validateExpr(alloc, src)) |e| {
        writeExprErrorJsonToStderr(stderr, null, e.name, e.detail, e.off, e.len);
        return 1;
    }
    // Success: emit a one-line `{"ok":true}` on stdout so callers can
    // confirm a clean validation without relying on the exit code alone
    // (error path keeps stdout empty + writes JSON to stderr).
    try stdout.writeAll("{\"ok\":true}\n");
    try stdout.flush();
    return 0;
}

// ── --expr-trace ─────────────────────────────────────────────────────────────

/// Parse + evaluate an expression with a per-call trace writer attached to
/// stdout. Each successful function call emits one NDJSON line:
///   {"fn":"ABS","src_start":0,"src_end":7,"value":"1.50"}
/// Final result (or error) is emitted as a sentinel line so the GUI can tell
/// the run finished:
///   {"t":"final","value":"..."}        on success
///   {"t":"error","error":"X","detail":"..."}  on failure (also exit 1)
///
/// `headers_json` and `fields_json` are JSON arrays of strings of equal
/// length; together they reconstruct a CSV row context so `[ColumnName]` and
/// `[n]` references resolve to real values during the re-evaluation. Both
/// are optional — a null pair means an empty row context (column refs throw).
fn runExprTrace(
    gpa: std.mem.Allocator,
    src: []const u8,
    headers_json: ?[]const u8,
    fields_json: ?[]const u8,
) !u8 {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_fw.interface;
    var stderr_buf: [4096]u8 = undefined;
    var stderr_fw = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_fw.interface;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The trace stream (per-call NDJSON + final sentinel) and the eval itself
    // live in inspect.evalTrace, shared with the MCP bxp_eval_trace tool. This
    // handler only owns stdout/stderr routing: traces → stdout, error → stderr.
    const result = inspect.evalTrace(alloc, src, headers_json, fields_json, stdout) catch |err| switch (err) {
        // The GUI always sends a known-good headers/fields pair; a bad shape is
        // a usage error.
        error.InvalidRowJson => {
            std.debug.print("error: --row-headers / --row-fields must be JSON arrays of strings\n", .{});
            return 2;
        },
        else => return err,
    };
    // Flush partial traces on both paths — on failure they're kept up to the
    // point the outer call blew up so the GUI can surface partial results.
    stdout.flush() catch {};
    if (result.error_json) |ej| {
        stderr.writeAll(ej) catch {};
        stderr.writeByte('\n') catch {};
        stderr.flush() catch {};
    }
    return result.exit_code;
}

// ── --expr-batch ─────────────────────────────────────────────────────────────

/// Read a JSON request from stdin describing N expressions to evaluate against
/// a single row context, evaluate each, and emit a JSON results array on stdout.
/// Drill-down companion to `--expr-trace`: amortises subprocess-spawn latency
/// across all expressions for one row (typical: ~14 input_schema vars + a few
/// rule.when probes per GUI click).
///
/// Request shape (stdin, JSON):
///   {
///     "headers":     ["Action", "Time", ...],              // CSV column names
///     "fields":      ["Dividend (Dividend)", "2024-...", ...], // row values (parallel)
///     "ticker_map":  {"PFE.US": "PFE", ...},               // optional
///     "lookups":     {"<name> <key> <field>": "value"}, // optional pre_pass blob
///     "exprs":       ["[Time]", "TICKER([Ticker])", ...]   // expressions to eval
///   }
///
/// Response shape (stdout, JSON):
///   {"results":[
///      {"ok":true,  "value":"..."},
///      {"ok":false, "error":"ColumnNotFound", "detail":"...", "off":0, "len":5}
///   ]}
///
/// Exit code 0 on a well-formed request (even if individual exprs fail; that
/// surfaces per-result via `ok:false`). Exit 1 on malformed input.
fn runExprBatch(gpa: std.mem.Allocator) !u8 {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_fw.interface;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Read stdin in full. 4 MiB cap matches the order-of-magnitude of a
    // realistic per-row request: ~14 vars × ~200 bytes/expr + row fields
    // ≈ a few KB. The cap is a safety net, not a tuning knob.
    const STDIN_MAX: usize = 4 * 1024 * 1024;
    var stdin_reader_buf: [4096]u8 = undefined;
    var stdin_fr = std.fs.File.stdin().reader(&stdin_reader_buf);
    const stdin_reader = &stdin_fr.interface;
    const body = stdin_reader.allocRemaining(alloc, .limited(STDIN_MAX)) catch |err| {
        std.debug.print("error: failed to read stdin: {s}\n", .{@errorName(err)});
        return 1;
    };

    const code = try runExprBatchBytes(alloc, body, stdout);
    try stdout.flush();
    return code;
}

/// Pure core of [runExprBatch]: parse one JSON request from `body`, evaluate
/// every expr against the row via `inspect.evalBatch`, and write the
/// `{results:[...]}` JSON to `out` (no flush — the caller owns that). Split out
/// so inline tests can drive it without stdin/stdout. The batch logic itself
/// lives in `inspect` so bxp-mcp's `bxp_eval_batch` shares it exactly.
fn runExprBatchBytes(
    alloc: std.mem.Allocator,
    body: []const u8,
    out: *std.Io.Writer,
) !u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        std.debug.print("error: --expr-batch stdin must be a JSON object\n", .{});
        return 1;
    };
    defer parsed.deinit();

    const r = try inspect.evalBatch(alloc, parsed.value);
    if (r.error_message) |msg| {
        std.debug.print("error: {s}\n", .{msg});
        return r.exit_code;
    }
    try out.writeAll(r.json);
    try out.writeByte('\n');
    return r.exit_code;
}

// ── Tests ────────────────────────────────────────────────────────────────────
//
// All tests call `annotateRaw` directly (no disk I/O, no subprocess).
// Phase letters in test names correspond to validation passes added
// incrementally during the audit:
//   A  — basic structure (comments preserved, missing conversion_templates)
//   B  — per-template hard errors (xlsx_sheet, ticker_map, output_schema)
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

test "annotateRaw Phase B: ticker_map unknown named ref attaches at ticker_map path" {
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
        \\      ticker_map: "missing_named_map",
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

    // For an "unknown named ref" the value is a string, so the
    // diagnostic attaches to the parent (sample) immediately before the
    // `ticker_map` field — same placement contract as
    // `injectSemanticErrors`.
    var has_err = false;
    var it = sample.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$err_") and
            diagHas(kv.value_ptr, "unknown named map"))
        {
            has_err = true;
            break;
        }
    }
    try testing.expect(has_err);
}

test "annotateRaw Phase C: duplicate top-level key surfaces \\$err_ with key name" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two `data_dir` keys at the same object level — diagDuplicateKey
    // should fire and bxp-fmt should still emit a usable annotated tree.
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
    // Warning severity → exit 0 from bxp-fmt --config (warnings don't
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

/// Drive `runExprBatchBytes` over an in-memory buffer and return the
/// `{exit, json}` pair so tests can assert without stdin/stdout.
fn batchOnBytes(a: std.mem.Allocator, body: []const u8) !struct { exit: u8, json: []const u8 } {
    var buf: std.Io.Writer.Allocating = .init(a);
    const code = try runExprBatchBytes(a, body, &buf.writer);
    return .{ .exit = code, .json = buf.written() };
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
