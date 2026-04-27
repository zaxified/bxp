/// bxp-fmt — small developer utility binary sibling to bxp-cli.
///
/// Exactly one action flag per invocation:
///   --config <path>  parse JSON5 config, validate, and emit annotated JSON to stdout.
///                    Comments are preserved as "$comm_<N>" sibling entries; syntax
///                    and semantic errors are embedded as "$err_<N>" sibling entries
///                    inserted at their parent object (semantic errors are placed
///                    immediately before the offending key). Exit 0 on success,
///                    exit 1 on any error.
///   --expr '<text>'  parse and validate one expression.
///                    On failure, a single JSON line is written to stderr.
///
/// Exit codes: 0 = OK, 1 = validation failure, 2 = usage error.
const std = @import("std");
const config_mod = @import("config");
const expr_mod = @import("expr");
const json5_mod = @import("json5");
const docs_mod = @import("docs.zig");
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

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var config_path: ?[]const u8 = null;
    var expr_src: ?[]const u8 = null;
    var emit_docs = false;
    var list_templates = false;
    var fetch_template_id: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            usage();
            return;
        }
        if (std.mem.eql(u8, a, "--version")) {
            var buf: [64]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            w.print("bxp-fmt {s}\n", .{build_options.version}) catch {};
            std.debug.print("{s}", .{w.buffered()});
            return;
        }
        if (std.mem.eql(u8, a, "--docs")) {
            emit_docs = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--config")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --config requires a path\n", .{});
                std.process.exit(2);
            }
            config_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--expr")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --expr requires an expression string\n", .{});
                std.process.exit(2);
            }
            expr_src = args[i];
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
                std.process.exit(2);
            }
            fetch_template_id = args[i];
            continue;
        }
        std.debug.print("error: unknown argument: {s}\n", .{a});
        usage();
        std.process.exit(2);
    }

    // --list-templates and --fetch-template are modifiers on --config; the
    // bare --config (with neither modifier) is its own validate-and-emit
    // action. Modifiers are mutually exclusive with each other.
    const fetch_active = fetch_template_id != null;
    const config_modifier_count = @as(u8, if (list_templates) 1 else 0) + @as(u8, if (fetch_active) 1 else 0);
    if (config_modifier_count > 1) {
        std.debug.print("error: --list-templates and --fetch-template are mutually exclusive\n", .{});
        std.process.exit(2);
    }

    const has_config_action = config_path != null and config_modifier_count == 0;
    const action_count = @as(u8, if (has_config_action) 1 else 0) +
        @as(u8, if (expr_src != null) 1 else 0) +
        @as(u8, if (emit_docs) 1 else 0) +
        @as(u8, if (config_modifier_count > 0) 1 else 0);

    if (action_count > 1) {
        std.debug.print("error: --config, --expr, --docs, --list-templates, and --fetch-template are mutually exclusive\n", .{});
        std.process.exit(2);
    }
    if (action_count == 0) {
        usage();
        std.process.exit(2);
    }

    if (config_modifier_count > 0) {
        const path = config_path orelse {
            std.debug.print("error: --list-templates / --fetch-template require --config <path>\n", .{});
            std.process.exit(2);
        };
        if (fetch_active) {
            try runFetchTemplate(alloc, path, fetch_template_id.?);
        } else {
            try runListTemplates(alloc, path);
        }
        return;
    }
    if (emit_docs) {
        try runDocs();
        return;
    }
    if (config_path) |p| {
        try runConfig(alloc, p);
        return;
    }
    if (expr_src) |e| {
        try runExpr(alloc, e);
        return;
    }
}

// ── --docs ──────────────────────────────────────────────────────────────────

fn runDocs() !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_fw.interface;
    try docs_mod.writeDocs(stdout);
    try stdout.flush();
}

// ── --list-templates / --fetch-template ─────────────────────────────────────
//
// Read a JSON5 config, parse it without semantic validation, and emit either
// a summary of every template (--list-templates) or one full template block
// (--fetch-template). Both paths use the same JSON5 → JSON pipeline as
// runConfig but skip the BrokerConfig load — invalid templates still appear
// in the listing so the GUI can show "(broken)" rows.

/// Reads the config file and parses it into a std.json.Value tree.
/// On any I/O or JSON5 error, prints `{"error":"<name>"}` and exits 1.
fn loadConfigValue(a: std.mem.Allocator, path: []const u8, stdout: *std.Io.Writer) !std.json.Value {
    const raw = readFileCapped(a, path) catch |err| {
        try emitRootErr(stdout, @errorName(err));
        std.process.exit(1);
    };
    const json_text = json5_mod.preprocess(a, raw) catch |err| {
        try emitRootErr(stdout, @errorName(err));
        std.process.exit(1);
    };
    return std.json.parseFromSliceLeaky(std.json.Value, a, json_text, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| {
        try emitRootErr(stdout, @errorName(err));
        std.process.exit(1);
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

fn runListTemplates(alloc: std.mem.Allocator, path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_fw.interface;

    const root = try loadConfigValue(a, path, stdout);

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
}

fn runFetchTemplate(alloc: std.mem.Allocator, path: []const u8, id: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_fw.interface;

    const root = try loadConfigValue(a, path, stdout);

    if (root != .object) {
        try emitRootErr(stdout, "config root is not an object");
        std.process.exit(1);
    }
    const ct = root.object.get("conversion_templates") orelse {
        try emitRootErr(stdout, "no conversion_templates in config");
        std.process.exit(1);
    };
    if (ct != .object) {
        try emitRootErr(stdout, "conversion_templates is not an object");
        std.process.exit(1);
    }
    const t = ct.object.get(id) orelse {
        // stderr human message, stdout JSON error so callers can parse either.
        std.debug.print("error: template id '{s}' not found in {s}\n", .{ id, path });
        const msg = try std.fmt.allocPrint(a, "template id '{s}' not found", .{id});
        try emitRootErr(stdout, msg);
        std.process.exit(1);
    };

    var jw: std.json.Stringify = .{ .writer = stdout, .options = .{ .whitespace = .indent_2 } };
    try jw.write(t);
    try stdout.writeByte('\n');
    try stdout.flush();
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

fn runConfig(alloc: std.mem.Allocator, path: []const u8) !void {
    // Arena for all allocations — freed on exit.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_fw.interface;

    // Read raw file.
    const raw = readFileCapped(a, path) catch |err| {
        try emitRootErr(stdout, @errorName(err));
        std.process.exit(1);
    };

    // Preprocess JSON5 → annotated JSON (comments preserved as $comm_<N>,
    // recovered syntax errors as $err_<N>).
    const ann = json5_mod.preprocessAnnotated(a, raw) catch |err| {
        try emitRootErr(stdout, @errorName(err));
        std.process.exit(1);
    };
    // Continue numbering: counter holds the last assigned id; insertErrBefore
    // increments before use, so the first new id will equal ann.next_id.
    var counter: u32 = ann.next_id - 1;

    // Parse as dynamic Value for annotation and re-serialization.
    var value = std.json.parseFromSliceLeaky(std.json.Value, a, ann.out, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| {
        try emitRootErr(stdout, @errorName(err));
        try stdout.flush();
        std.process.exit(1);
    };

    // Load typed config for semantic validation.
    // config_mod.load prints diagnostics to stderr.
    var cfg = config_mod.load(a, path) catch |err| {
        try insertErrBefore(a, &value, "", @errorName(err), &counter);
        try serializeValue(stdout, value);
        std.process.exit(1);
    };

    // Collect all semantic validation errors.
    var errors: std.ArrayList(config_mod.ValidationError) = .empty;
    var it = cfg.brokers.iterator();
    while (it.next()) |entry| {
        try entry.value_ptr.validateCollect(entry.key_ptr.*, a, &errors);
    }

    if (cfg.brokers.count() == 0) {
        try insertErrBefore(a, &value, "", "no conversion_templates defined", &counter);
        try serializeValue(stdout, value);
        std.process.exit(1);
    }

    if (errors.items.len == 0) {
        try serializeValue(stdout, value);
        std.process.exit(0);
    }

    try injectSemanticErrors(a, &value, errors.items, &counter);
    try serializeValue(stdout, value);
    std.process.exit(1);
}

/// Serialize a Value to stdout with a trailing newline, then flush.
fn serializeValue(stdout: *std.Io.Writer, value: std.json.Value) !void {
    try std.json.Stringify.value(value, .{}, stdout);
    try stdout.writeByte('\n');
    try stdout.flush();
}

/// Emit {"$err_1":"<msg>"} to stdout with newline + flush, then caller exits.
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
    if (parent.* != .object) return;
    counter.* += 1;
    const err_key = try std.fmt.allocPrint(a, "$err_{d}", .{counter.*});
    const duped_msg = try a.dupe(u8, msg);

    if (target_key.len == 0 or !parent.object.contains(target_key)) {
        try parent.object.put(err_key, .{ .string = duped_msg });
        return;
    }

    // Rebuild ordering: collect entries, clear map, re-put with err key
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
            try parent.object.put(err_key, .{ .string = duped_msg });
        }
        try parent.object.put(e.k, e.v);
    }
}

/// Navigate the Value tree by dot-separated path, returning a mutable pointer
/// to the node at that path, or null if the path does not exist.
fn getPtrAtPath(root: *std.json.Value, path: []const u8) ?*std.json.Value {
    if (path.len == 0) return root;
    var node = root;
    var parts = std.mem.splitScalar(u8, path, '.');
    while (parts.next()) |seg| {
        switch (node.*) {
            .object => |*obj| {
                node = obj.getPtr(seg) orelse return null;
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
fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

// ── --expr ───────────────────────────────────────────────────────────────────

/// Parse + evaluate the expression with an empty Context.
/// Expressions that reference [ColumnName] or $var will fail because the context
/// has no fields — that is the intended behavior for a bare syntax check.
fn runExpr(alloc: std.mem.Allocator, src: []const u8) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_fw = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_fw.interface;

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
        std.process.exit(1);
    };
    // Success: no stdout output; exit 0 implicit.
}
