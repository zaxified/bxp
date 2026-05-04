/// bxp-fmt — config and expression utility for bxp-cli.
///
/// See `../CLAUDE.md` for the authoritative subcommand reference, exit-code
/// table, and annotated-JSON output spec. Run `bxp-fmt --help` for the
/// runtime usage summary.
const std = @import("std");
const config_mod = @import("config");
const expr_mod = @import("expr");
const json5_mod = @import("json5");
const docs_mod = @import("docs");
const diagnostics_mod = @import("diagnostics");
const build_options = @import("build_options");

const CONFIG_MAX_FILE_SIZE = 1024 * 1024; // 1 MB

fn usage() void {
    std.debug.print(
        \\bxp-fmt — config and expression utility for bxp-cli
        \\
        \\Usage (exactly one action flag):
        \\  bxp-fmt --config <path>                  validate config; emit annotated JSON to stdout
        \\  bxp-fmt --expr '<text>'                  validate one expression; stderr JSON on error
        \\  bxp-fmt --docs                           emit full language/schema documentation as JSON
        \\  bxp-fmt --config <path> --list-templates emit JSON list of templates declared in config
        \\  bxp-fmt --config <path> --fetch-template <id>
        \\                                           emit one template block as JSON
        \\
        \\Options:
        \\  --version                 print version and exit
        \\  --help                    print this help and exit
        \\
        \\Exit codes:
        \\  0 - success
        \\  1 - validation failure / template id not found
        \\  2 - usage error
        \\
    , .{});
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
    var row_headers_json: ?[]const u8 = null;
    var row_fields_json: ?[]const u8 = null;
    var emit_docs = false;
    var list_templates = false;
    var fetch_template_id: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            usage();
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
        if (std.mem.eql(u8, a, "--config")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --config requires a path\n", .{});
                return 2;
            }
            config_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--expr")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --expr requires an expression string\n", .{});
                return 2;
            }
            expr_src = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--expr-trace")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --expr-trace requires an expression string\n", .{});
                return 2;
            }
            expr_trace_src = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--row-headers")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --row-headers requires a JSON array string\n", .{});
                return 2;
            }
            row_headers_json = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--row-fields")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --row-fields requires a JSON array string\n", .{});
                return 2;
            }
            row_fields_json = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--list-templates")) {
            list_templates = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--fetch-template")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --fetch-template requires a template id\n", .{});
                return 2;
            }
            fetch_template_id = args[i];
            continue;
        }
        std.debug.print("error: unknown argument: {s}\n", .{a});
        usage();
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

    const has_config_action = config_path != null and config_modifier_count == 0;
    const action_count = @as(u8, if (has_config_action) 1 else 0) +
        @as(u8, if (expr_src != null) 1 else 0) +
        @as(u8, if (expr_trace_src != null) 1 else 0) +
        @as(u8, if (emit_docs) 1 else 0) +
        @as(u8, if (config_modifier_count > 0) 1 else 0);

    if (action_count > 1) {
        std.debug.print("error: --config, --expr, --expr-trace, --docs, --list-templates, and --fetch-template are mutually exclusive\n", .{});
        return 2;
    }
    if (action_count == 0) {
        usage();
        return 2;
    }

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
        return try runConfig(alloc, p);
    }
    if (expr_src) |e| {
        return try runExpr(alloc, e);
    }
    if (expr_trace_src) |e| {
        return try runExprTrace(alloc, e, row_headers_json, row_fields_json);
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

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_fw.interface;
    try docs_mod.writeDocs(arena.allocator(), stdout);
    try stdout.flush();
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

/// Returns an optional string field from a JSON object — null if missing/wrong type.
fn optString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
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

    var jw: std.json.Stringify = .{ .writer = stdout, .options = .{ .whitespace = .indent_2 } };
    try jw.beginObject();
    try jw.objectField("templates");
    try jw.beginArray();

    if (root == .object) {
        if (root.object.get("conversion_templates")) |ct| {
            if (ct == .object) {
                var it = ct.object.iterator();
                while (it.next()) |entry| {
                    const id = entry.key_ptr.*;
                    try jw.beginObject();
                    try jw.objectField("id"); try jw.write(id);

                    if (entry.value_ptr.* == .object) {
                        const tobj = entry.value_ptr.object;
                        try jw.objectField("data_dir");
                        if (optString(tobj, "data_dir")) |s| try jw.write(s) else try jw.write(null);
                        try jw.objectField("file_pattern_in");
                        if (optString(tobj, "file_pattern_in")) |s| try jw.write(s) else try jw.write(null);
                        try jw.objectField("file_pattern_out");
                        if (optString(tobj, "file_pattern_out")) |s| try jw.write(s) else try jw.write(null);
                        try jw.objectField("file_type_in");
                        try jw.write(optString(tobj, "file_type_in") orelse "csv");
                        try jw.objectField("file_type_out");
                        try jw.write(optString(tobj, "file_type_out") orelse "csv");
                        try jw.objectField("description");
                        if (optString(tobj, "description")) |s| try jw.write(s) else try jw.write(null);
                    } else {
                        try jw.objectField("error"); try jw.write("template entry is not an object");
                    }
                    try jw.endObject();
                }
            }
        }
    }

    try jw.endArray();
    try jw.endObject();
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

    if (root != .object) {
        try emitRootErr(stdout, "config root is not an object");
        return 1;
    }
    const ct = root.object.get("conversion_templates") orelse {
        try emitRootErr(stdout, "no conversion_templates in config");
        return 1;
    };
    if (ct != .object) {
        try emitRootErr(stdout, "conversion_templates is not an object");
        return 1;
    }
    const t = ct.object.get(id) orelse {
        // stderr human message, stdout JSON error so callers can parse either.
        std.debug.print("error: template id '{s}' not found in {s}\n", .{ id, path });
        const msg = try std.fmt.allocPrint(a, "template id '{s}' not found", .{id});
        try emitRootErr(stdout, msg);
        return 1;
    };

    var jw: std.json.Stringify = .{ .writer = stdout, .options = .{ .whitespace = .indent_2 } };
    try jw.write(t);
    try stdout.writeByte('\n');
    try stdout.flush();
    return 0;
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

fn runConfig(alloc: std.mem.Allocator, path: []const u8) !u8 {
    // Arena for all allocations — freed on exit.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_fw.interface;

    const result = try annotateConfigFromFile(a, path);
    try stdout.writeAll(result.json);
    try stdout.writeByte('\n');
    try stdout.flush();
    return result.exit_code;
}

/// Result of annotating a config file. `json` is the serialized output
/// (no trailing newline); `exit_code` mirrors what bxp-fmt would exit with
/// (0 = clean, 1 = file/parse/validation error). Callers own neither
/// allocation — the arena passed in does.
const AnnotateResult = struct {
    json: []u8,
    exit_code: u8,
};

/// File-loading wrapper around `annotateRaw`. Reads `path`, then runs
/// the same pure pipeline as the inline tests use.
fn annotateConfigFromFile(a: std.mem.Allocator, path: []const u8) !AnnotateResult {
    const raw = readFileCapped(a, path) catch |err| {
        return .{ .json = try formatRootErr(a, @errorName(err)), .exit_code = 1 };
    };
    return annotateRaw(a, raw, path);
}

/// Pure annotation pipeline — takes JSON5 source bytes, preserves
/// comments as `$comm_<N>` siblings, injects `$err_<N>` markers for
/// syntax and semantic errors, returns the serialized JSON.
///
/// Never reads files. Never writes to stdout / stderr. Never calls
/// `std.process.exit`. `path_label` is used only in diagnostic
/// messages (the validator embeds it in `<path>: config error: ...`
/// strings) — pass `"<inline>"` or any marker when the source isn't
/// from a real file.
fn annotateRaw(a: std.mem.Allocator, raw: []const u8, path_label: []const u8) !AnnotateResult {
    const ann = json5_mod.preprocessAnnotated(a, raw) catch |err| {
        return .{ .json = try formatRootErr(a, @errorName(err)), .exit_code = 1 };
    };
    var counter: u32 = ann.next_id - 1;

    // If the annotated bytes don't even parse as JSON, that's a regression
    // in `preprocessAnnotated` itself (its output is supposed to be valid
    // JSON modulo the `$comm_*`/`$err_*` keys it injects). We discard the
    // annotated value entirely and emit a standalone root error. The
    // upstream `$err_*` markers in `ann.out` are lost — but they never
    // reach the user because the standalone document replaces them; see
    // `formatRootErr` doc-comment for why this can't collide.
    var value = std.json.parseFromSliceLeaky(std.json.Value, a, ann.out, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| {
        return .{ .json = try formatRootErr(a, @errorName(err)), .exit_code = 1 };
    };

    // Structured diagnostic sink. In Phase A nothing emits to it yet
    // (the parameter is reserved for upcoming path-aware deep-validation
    // sites in config.zig / json5.zig / expr.zig). The bag is created,
    // passed through, and rendered via `injectDiagnostics` after the
    // existing ValidationError path runs — an empty bag is a no-op.
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
    }

    // Cross-template invariants (file_pattern collision today). bxp-cli
    // never calls this — it lives entirely on the bxp-fmt deep path.
    try config_mod.validateCrossTemplate(&cfg, a, &diag);

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

    // Exit 1 if anything in the existing fail-list is non-empty OR if
    // the structured sink contains any error-severity finding.
    const has_error =
        errors.items.len != 0 or diag.countBySeverity(.@"error") != 0;
    return .{ .json = try valueToJsonString(a, value), .exit_code = if (has_error) 1 else 0 };
}

/// Build `{"$err_1":"<msg>"}` as a **standalone** JSON document.
///
/// Used by `annotateRaw`'s three fail paths (file-read fail, json5
/// preprocess fail, post-preprocess JSON parse fail) to produce a clean
/// fallback output when the annotation pipeline cannot proceed. The
/// returned bytes **replace** any annotated value the pipeline may have
/// built so far — they are never merged into a tree that already
/// contains `$comm_<N>` / `$err_<N>` siblings.
///
/// Counter `1` is hard-coded because the output object holds exactly
/// one key. There is no collision with annotated `$err_1` even when
/// `preprocessAnnotated` already emitted a different `$err_1` upstream:
/// the upstream annotated text gets discarded by the caller, so the two
/// `$err_1` strings live on disjoint output paths and never coexist
/// inside a single JSON document.
///
/// In-tree injection (mid-pipeline validation errors) goes through
/// `insertErrBefore` + a shared counter from `preprocessAnnotated`'s
/// `next_id`; that path NEVER calls `formatRootErr`.
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

/// Serialize a Value to stdout with a trailing newline, then flush.
fn serializeValue(stdout: *std.Io.Writer, value: std.json.Value) !void {
    try std.json.Stringify.value(value, .{}, stdout);
    try stdout.writeByte('\n');
    try stdout.flush();
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

/// Inject $err_<N> entries for all validation errors into the Value tree.
/// Each entry is placed immediately before the offending key in its parent
/// object, so UI tooling can render the marker visually in-place.
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

/// Insert "$err_<N>": "<msg>" into `parent` immediately before the entry whose
/// key equals `target_key`. If `target_key` is empty or not present, append at
/// end. The counter is incremented before use, so the new key uses counter.*.
fn insertErrBefore(
    a: std.mem.Allocator,
    parent: *std.json.Value,
    target_key: []const u8,
    msg: []const u8,
    counter: *u32,
) !void {
    return insertNumberedBefore(a, parent, "$err_", target_key, msg, counter);
}

/// Generic prefix-aware variant. Used by `insertErrBefore` (prefix
/// `"$err_"`) and the severity-routed `injectDiagnostics` path
/// (`"$warn_"` / `"$info_"`). Counter is shared across prefixes so all
/// emitted keys are unique within the document.
fn insertNumberedBefore(
    a: std.mem.Allocator,
    parent: *std.json.Value,
    prefix: []const u8,
    target_key: []const u8,
    msg: []const u8,
    counter: *u32,
) !void {
    if (parent.* != .object) return;
    counter.* += 1;
    const new_key = try std.fmt.allocPrint(a, "{s}{d}", .{ prefix, counter.* });
    const duped_msg = try a.dupe(u8, msg);

    if (target_key.len == 0 or !parent.object.contains(target_key)) {
        try parent.object.put(new_key, .{ .string = duped_msg });
        return;
    }

    // Rebuild ordering: collect entries, clear map, re-put with new key
    // inserted immediately before the target.
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
            try parent.object.put(new_key, .{ .string = duped_msg });
        }
        try parent.object.put(e.k, e.v);
    }
}

/// Inject `$err_<N>` / `$warn_<N>` / `$info_<N>` entries for every
/// Diagnostic into the Value tree. Each entry sits immediately before
/// the offending key in its parent object (same placement contract as
/// `injectSemanticErrors`). The shared `counter` keeps numbering unique
/// across the existing ValidationError pass and any deep-validation
/// findings, so the GUI can route by prefix without collisions.
///
/// Phase A is a plumbing-only pass: today no emit site populates the
/// Diagnostics bag, so this function is invoked with an empty slice and
/// is a no-op. Phase B+ start filling the bag.
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

        try insertNumberedBefore(a, parent_ptr, prefix, field_name, d.message, counter);
    }
}

/// Navigate the Value tree by dot-separated path, returning a mutable pointer
/// to the node at that path, or null if the path does not exist.
///
/// Segments that are decimal integers index into a `.array` node; everything
/// else looks up a key on a `.object` node. `BrokerConfig.validateCollect`
/// emits paths like `row_rules.0.when` for ordered arrays.
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

/// Return a display string for the value of field_name within parent_node.
/// Newlines and other control chars are escaped. Returns "" if not found.
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

/// Escape control characters for human-readable display in $err_trace messages.
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

    var col_index = std.StringHashMap(usize).init(alloc);
    defer col_index.deinit();
    var ticker_map = std.StringHashMap([]const u8).init(alloc);
    defer ticker_map.deinit();
    var detail: []const u8 = "";
    const ctx = expr_mod.Context{
        .fields = &.{},
        .col_index = &col_index,
        .ticker_map = &ticker_map,
        .lookup_table = null,
        .alloc = alloc,
        .error_detail = &detail,
    };

    _ = expr_mod.eval(src, &ctx) catch |err| {
        var jw: std.json.Stringify = .{ .writer = stderr, .options = .{} };
        jw.beginObject() catch {};
        jw.objectField("error") catch {};
        jw.write(@errorName(err)) catch {};
        jw.objectField("detail") catch {};
        jw.write(detail) catch {};
        jw.endObject() catch {};
        stderr.writeByte('\n') catch {};
        stderr.flush() catch {};
        return 1;
    };
    // Success: no stdout output.
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

    // Arena collects every transient allocation made during JSON arg parsing
    // and expression evaluation. The tool exits immediately after this call,
    // so freeing per-allocation is needless overhead — and DebugAllocator's
    // leak report would mask real bugs if we tracked them individually.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col_index = std.StringHashMap(usize).init(alloc);
    defer col_index.deinit();
    var ticker_map = std.StringHashMap([]const u8).init(alloc);
    defer ticker_map.deinit();

    // Decode headers/fields JSON arrays. Mismatched lengths or non-array
    // shapes are usage errors (exit 2) — the GUI sends a known-good pair.
    var headers_list: std.ArrayList([]const u8) = .empty;
    defer headers_list.deinit(alloc);
    var fields_list: std.ArrayList([]const u8) = .empty;
    defer fields_list.deinit(alloc);
    if (headers_json) |hj| {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, hj, .{}) catch {
            std.debug.print("error: --row-headers must be a JSON array of strings\n", .{});
            return 2;
        };
        defer parsed.deinit();
        if (parsed.value != .array) {
            std.debug.print("error: --row-headers must be a JSON array of strings\n", .{});
            return 2;
        }
        for (parsed.value.array.items) |item| {
            if (item != .string) {
                std.debug.print("error: --row-headers entries must be strings\n", .{});
                return 2;
            }
            // `parsed.deinit()` (deferred above) frees the original
            // string bytes pointed to by `item.string`, so we must dupe
            // the slice into the arena before storing the reference.
            try headers_list.append(alloc, try alloc.dupe(u8, item.string));
        }
    }
    if (fields_json) |fj| {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, fj, .{}) catch {
            std.debug.print("error: --row-fields must be a JSON array of strings\n", .{});
            return 2;
        };
        defer parsed.deinit();
        if (parsed.value != .array) {
            std.debug.print("error: --row-fields must be a JSON array of strings\n", .{});
            return 2;
        }
        for (parsed.value.array.items) |item| {
            if (item != .string) {
                std.debug.print("error: --row-fields entries must be strings\n", .{});
                return 2;
            }
            // See headers_list above — same lifetime caveat applies here.
            try fields_list.append(alloc, try alloc.dupe(u8, item.string));
        }
    }
    if (headers_list.items.len != fields_list.items.len) {
        std.debug.print(
            "error: --row-headers ({d}) and --row-fields ({d}) length mismatch\n",
            .{ headers_list.items.len, fields_list.items.len },
        );
        return 2;
    }
    for (headers_list.items, 0..) |h, idx| {
        try col_index.put(h, idx);
    }

    var detail: []const u8 = "";
    const ctx = expr_mod.Context{
        .fields = fields_list.items,
        .col_index = &col_index,
        .ticker_map = &ticker_map,
        .lookup_table = null,
        .alloc = alloc,
        .error_detail = &detail,
        .trace_writer = stdout,
    };

    const result = expr_mod.evalString(src, &ctx) catch |err| {
        // Emit error sentinel on stderr then exit non-zero. Per-fn traces
        // already on stdout up to the point of failure are kept — the GUI
        // can surface partial results when an outer call blew up.
        var jw: std.json.Stringify = .{ .writer = stderr, .options = .{} };
        jw.beginObject() catch {};
        jw.objectField("t") catch {};
        jw.write("error") catch {};
        jw.objectField("error") catch {};
        jw.write(@errorName(err)) catch {};
        jw.objectField("detail") catch {};
        jw.write(detail) catch {};
        jw.endObject() catch {};
        stderr.writeByte('\n') catch {};
        stderr.flush() catch {};
        return 1;
    };
    var jw: std.json.Stringify = .{ .writer = stdout, .options = .{} };
    jw.beginObject() catch {};
    jw.objectField("t") catch {};
    jw.write("final") catch {};
    jw.objectField("value") catch {};
    jw.write(result) catch {};
    jw.endObject() catch {};
    stdout.writeByte('\n') catch {};
    stdout.flush() catch {};
    return 0;
}

// ── Tests ────────────────────────────────────────────────────────────────────

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

    const result = try annotateRaw(a, fixture, "<inline>");
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
    const err1 = parsed.object.get("$err_1") orelse return error.MissingErr1;
    try testing.expect(err1 == .string);
    try testing.expect(std.mem.indexOf(u8, err1.string, "no conversion_templates") != null);
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
        \\        { when: "true", rows: [ { $action: "'DEPOSIT'" } ] }
        \\      ]
        \\    }
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>");
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

    const result = try annotateRaw(a, fixture, "<inline>");
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
            kv.value_ptr.* == .string and
            std.mem.indexOf(u8, kv.value_ptr.string, "missing required key 'name'") != null)
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

    const result = try annotateRaw(a, fixture, "<inline>");
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
            kv.value_ptr.* == .string and
            std.mem.indexOf(u8, kv.value_ptr.string, "unknown named map") != null)
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

    const result = try annotateRaw(a, fixture, "<inline>");
    try testing.expectEqual(@as(u8, 1), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    try testing.expect(parsed == .object);

    var has_dup = false;
    var it = parsed.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$err_") and
            kv.value_ptr.* == .string and
            std.mem.indexOf(u8, kv.value_ptr.string, "duplicate key") != null and
            std.mem.indexOf(u8, kv.value_ptr.string, "data_dir") != null)
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

    const result = try annotateRaw(a, fixture, "<inline>");
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
        if (kv.value_ptr.* != .string) continue;
        warn_count += 1;
        const m = kv.value_ptr.string;
        if (std.mem.indexOf(u8, m, "date_filter_from_filename") != null and
            std.mem.indexOf(u8, m, "boolean") != null) found_bool = true;
        if (std.mem.indexOf(u8, m, "csv_text_quote_in") != null and
            std.mem.indexOf(u8, m, "singlle") != null) found_quote = true;
        if (std.mem.indexOf(u8, m, "file_type_out") != null and
            std.mem.indexOf(u8, m, "jsno") != null) found_filetype = true;
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
        \\      data_dir: "shared",
        \\      file_pattern_in: ".csv",
        \\      file_pattern_out: "_a.csvx",
        \\      input_schema: { $date: "[Date]" },
        \\      output_schema: { date: "$date" },
        \\    },
        \\    beta: {
        \\      data_dir: "shared",
        \\      file_pattern_in: "_x.csv",
        \\      file_pattern_out: "_b.csvx",
        \\      input_schema: { $date: "[Date]" },
        \\      output_schema: { date: "$date" },
        \\    },
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>");
    try testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    const alpha = ct.object.get("alpha") orelse return error.MissingAlpha;

    var has_collision = false;
    var it = alpha.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$warn_") and
            kv.value_ptr.* == .string and
            std.mem.indexOf(u8, kv.value_ptr.string, "matches the same files as template 'beta'") != null)
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
        \\      data_dir: "xtb",
        \\      file_pattern_in: "_closed.csv",
        \\      file_pattern_out: "_closed.csvx",
        \\      input_schema: { $date: "[Date]" },
        \\      output_schema: { date: "$date" },
        \\    },
        \\    cash: {
        \\      data_dir: "xtb",
        \\      file_pattern_in: "_cash.csv",
        \\      file_pattern_out: "_cash.csvx",
        \\      input_schema: { $date: "[Date]" },
        \\      output_schema: { date: "$date" },
        \\    },
        \\  }
        \\}
    ;

    const result = try annotateRaw(a, fixture, "<inline>");
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

    const result = try annotateRaw(a, fixture, "<inline>");
    try testing.expectEqual(@as(u8, 1), result.exit_code);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.json, .{});
    const ct = parsed.object.get("conversion_templates") orelse return error.MissingCT;
    const sample = ct.object.get("sample") orelse return error.MissingSample;

    var has_err = false;
    var it = sample.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$err_") and
            kv.value_ptr.* == .string and
            std.mem.indexOf(u8, kv.value_ptr.string, "output_schema is required") != null)
        {
            has_err = true;
            break;
        }
    }
    try testing.expect(has_err);
}
