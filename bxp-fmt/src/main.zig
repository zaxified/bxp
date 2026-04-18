/// bxp-fmt — small developer utility binary sibling to bxp-cli.
///
/// Exactly one action flag per invocation:
///   --config <path>  read JSON5 config, validate structure, emit to stdout
///                    (preserves original key order, comments, and formatting).
///   --expr '<text>'  parse and validate one expression.
///                    On failure, a single JSON line is written to stderr.
///
/// Exit codes: 0 = OK, 1 = validation failure, 2 = usage error.
const std = @import("std");
const config_mod = @import("config");
const expr_mod = @import("expr");
const docs_mod = @import("docs.zig");
const build_options = @import("build_options");

fn usage() void {
    std.debug.print(
        \\bxp-fmt — config and expression utility for bxp-cli
        \\
        \\Usage (exactly one action flag):
        \\  bxp-fmt --config <path>   validate and emit JSON5 config to stdout
        \\  bxp-fmt --expr '<text>'   validate one expression; stderr JSON on error
        \\  bxp-fmt --docs            emit full language/schema documentation as JSON
        \\
        \\Options:
        \\  --version                 print version and exit
        \\  --help                    print this help and exit
        \\
        \\Exit codes:
        \\  0 - success
        \\  1 - validation failure
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
        std.debug.print("error: unknown argument: {s}\n", .{a});
        usage();
        std.process.exit(2);
    }

    const action_count = @as(u8, if (config_path != null) 1 else 0) +
        @as(u8, if (expr_src != null) 1 else 0) +
        @as(u8, if (emit_docs) 1 else 0);

    if (action_count > 1) {
        std.debug.print("error: --config, --expr, and --docs are mutually exclusive\n", .{});
        std.process.exit(2);
    }
    if (action_count == 0) {
        usage();
        std.process.exit(2);
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

/// --docs implementation: emit full language/schema documentation as JSON.
fn runDocs() !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_fw.interface;
    try docs_mod.writeDocs(stdout);
    try stdout.flush();
}

/// --config implementation: load + validate, then emit the source file verbatim.
/// Verbatim emission is the only way to preserve comments, whitespace, and the
/// user's original key order without a full JSON5 AST. A real reformatter may
/// replace this later; idempotency is guaranteed today.
fn runConfig(alloc: std.mem.Allocator, path: []const u8) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_fw = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_fw.interface;

    // config_mod.load prints its own diagnostics to stderr via std.debug.print
    // on parse/structural errors. We surface a trailing line on other failures.
    var cfg = config_mod.load(alloc, path) catch |err| {
        stderr.print("error: failed to load config: {s}\n", .{@errorName(err)}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };
    defer cfg.deinit();

    if (cfg.brokers.count() == 0) {
        stderr.print("error: {s} defines no conversion_templates\n", .{path}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    }

    var it = cfg.brokers.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.validate(entry.key_ptr.*, path, stderr) catch {
            stderr.flush() catch {};
            std.process.exit(1);
        };
    }

    // Validation passed — emit the source file verbatim to stdout.
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(alloc, 16 * 1024 * 1024);
    defer alloc.free(content);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_fw.interface;
    try stdout.writeAll(content);
    try stdout.flush();
}

/// --expr implementation: parse + evaluate the expression with an empty Context.
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
