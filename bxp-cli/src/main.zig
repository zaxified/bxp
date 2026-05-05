/// Broker eXchange Parser — CLI entry point.
///
/// Handles argument parsing, config loading, template validation, and dispatches
/// to the processing pipeline (pipeline.zig) for per-broker file conversion.
const std = @import("std");
const config_mod = @import("config");
const diagnostics_mod = @import("diagnostics");
const pipeline = @import("pipeline.zig");
const build_options = @import("build_options");

const SectionStats = pipeline.SectionStats;
const Output = pipeline.Output;

const DEFAULT_CONFIG_PATH: []const u8 = "bxp-cli.json";

/// Help text body. The two stream variants below pick which file
/// descriptor it lands on:
///   * `printHelp` — `--help` requested explicitly: stdout, so callers
///     piping `bxp-cli --help | grep` work without `2>&1`.
///   * `usageErr`  — argument-validation failures: stderr, alongside
///     the error message they accompany.
const USAGE_TEMPLATE =
    \\Broker eXchange Parser (BXP)
    \\
    \\  CLI tool to convert fiscal CSV exports from your favorite brokers to your favorite portfolio trackers.
    \\  If you don't know how to start, just tell your AI agent to generate a JSON template for you.
    \\
    \\Usage:
    \\  {s}                                    process all templates in config file
    \\  {s} --template <id>                    process single template
    \\  {s} --template <id> --data <path>      override templates's data_dir
    \\
    \\Options:
    \\  --config <path>    load custom config instead of default bxp-cli.json
    \\  --template <id>    choose single template
    \\  --data <path>      override templates's data_dir (requires --template)
    \\  --fresh            skip files whose output already exists (atomic O_EXCL)
    \\  --dry-run          run the pipeline in memory without writing output files
    \\  --trace            emit per-row NDJSON events on stdout (forces --quiet; conflicts with --debug)
    \\  --debug            suppresses informational stdout summaries; prints unmatched rows as JSON when row_rules_debug_missing is set
    \\  --quiet            suppress informational stdout (errors still go to stderr)
    \\  --check-fs=N       opt-in: validate data_dir + input-file existence before any processing,
    \\                     with N-second total timeout (e.g. --check-fs=5). Default off.
    \\  --version          print version and exit
    \\  --help             print this help and exit
    \\
    \\Exit codes:
    \\  0 - success
    \\  1 - error
    \\  2 - warnings
    \\
;

/// Print the help text to stdout. Used for `--help`.
fn printHelp(prog: []const u8) void {
    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const w = &fw.interface;
    w.print(USAGE_TEMPLATE, .{ prog, prog, prog }) catch {};
    w.flush() catch {};
}

/// Print the help text to stderr. Used after an argument-validation
/// failure where we want the help to accompany the error message.
fn usageErr(prog: []const u8) void {
    std.debug.print(USAGE_TEMPLATE, .{ prog, prog, prog });
}

/// Rejects paths that contain dangerous shell metacharacters or more than one ".." component.
/// One level up (e.g. "../data/...") is allowed to support the default data_dir layout.
///
/// Rejected characters: $ | ; & > < ` ( ) \n \r \0
/// Reason: prevent CSV formula injection and path traversal attacks on downstream tools.
///
/// The `..` traversal counter consults `std.fs.path.isSep` so the check
/// is platform-aware: on Windows both `/` and `\` are recognised path
/// separators, so `..\foo\..` is counted the same as `../foo/..`.
/// On POSIX only `/` is a separator (the standard behaviour).
fn validatePath(path: []const u8) error{InvalidPath}!void {
    for (path) |c| {
        switch (c) {
            '$', '|', ';', '&', '>', '<', '`', '(', ')', '\n', '\r', 0 => return error.InvalidPath,
            else => {},
        }
    }
    var count: usize = 0;
    var i: usize = 0;
    while (i + 3 <= path.len) : (i += 1) {
        if (path[i] == '.' and path[i + 1] == '.' and std.fs.path.isSep(path[i + 2])) {
            count += 1;
            if (count > 1) return error.InvalidPath;
        }
    }
    // Also catch trailing ".." (path ends with "<sep>.." or is exactly "..").
    const ends_with_dotdot = std.mem.eql(u8, path, "..") or
        (path.len >= 3 and std.fs.path.isSep(path[path.len - 3]) and
            path[path.len - 2] == '.' and path[path.len - 1] == '.');
    if (ends_with_dotdot) {
        if (count + 1 > 1) return error.InvalidPath;
    }
}

test "validatePath rejects shell metacharacters" {
    try std.testing.expectError(error.InvalidPath, validatePath("foo;rm -rf /"));
    try std.testing.expectError(error.InvalidPath, validatePath("a$(b)"));
    try std.testing.expectError(error.InvalidPath, validatePath("a|b"));
}

test "validatePath allows one '..' but not two" {
    try validatePath("../data/x.csv");
    try validatePath("foo/../bar");
    try validatePath("..");
    try validatePath("foo/..");
    try std.testing.expectError(error.InvalidPath, validatePath("../../etc/passwd"));
    try std.testing.expectError(error.InvalidPath, validatePath("../foo/../bar"));
    try std.testing.expectError(error.InvalidPath, validatePath("foo/../bar/.."));
}

test "validatePath: backslash separator counts as traversal on Windows builds" {
    // On Windows `std.fs.path.isSep('\\')` is true, so `..\..` should
    // reject. On POSIX `\\` is just a regular byte, `..\..` collapses
    // to a single token and one `..` is allowed.
    if (@import("builtin").os.tag == .windows) {
        try std.testing.expectError(error.InvalidPath, validatePath("..\\..\\etc\\passwd"));
        try std.testing.expectError(error.InvalidPath, validatePath("foo\\..\\bar\\.."));
    } else {
        // No backslash-separator semantics on POSIX — string is one segment.
        try validatePath("..\\..\\etc\\passwd");
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_fw.interface;

    // Allocate args early so --debug/--quiet can be detected before any error occurs.
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var debug = false;
    var quiet = false;
    var fresh = false;
    var trace = false;
    var dry_run = false;
    var check_fs_seconds: u8 = 0;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            stdout.print("bxp-cli {s}\n", .{build_options.version}) catch {};
            stdout.flush() catch {};
            return;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            printHelp(args[0]);
            return;
        }
        if (std.mem.eql(u8, arg, "--debug")) debug = true;
        if (std.mem.eql(u8, arg, "--quiet")) quiet = true;
        if (std.mem.eql(u8, arg, "--fresh")) fresh = true;
        if (std.mem.eql(u8, arg, "--trace")) trace = true;
        if (std.mem.eql(u8, arg, "--dry-run")) dry_run = true;
        if (std.mem.startsWith(u8, arg, "--check-fs=")) {
            const val = arg["--check-fs=".len..];
            check_fs_seconds = std.fmt.parseUnsigned(u8, val, 10) catch {
                std.debug.print("error: --check-fs requires a non-negative integer (seconds): got '{s}'\n", .{val});
                std.process.exit(1);
            };
        }
    }

    if (quiet and debug) {
        std.debug.print("error: --quiet and --debug cannot be used together\n", .{});
        std.process.exit(1);
    }
    if (trace and debug) {
        std.debug.print("error: --trace and --debug cannot be used together\n", .{});
        std.process.exit(1);
    }

    const out = Output{ .writer = stdout, .quiet = quiet, .debug = debug, .trace = trace, .dry_run = dry_run };

    const stats = run(args, out, fresh, check_fs_seconds, alloc) catch |err| {
        if (err == error.Fatal) {
            out.event("done", .{ .exit_code = @as(u8, 1) });
            std.process.exit(1); // message already printed
        }
        if (debug) return err; // propagate — Zig prints trace
        out.fatal("---\n# fatal error: {s}\n", .{@errorName(err)});
        out.event("done", .{ .exit_code = @as(u8, 1) });
        std.process.exit(1);
    };

    const exit_code: u8 = if (stats.warnings > 0) 2 else 0;
    out.event("done", .{ .exit_code = exit_code });
    if (exit_code != 0) std.process.exit(exit_code);
    // exit(0) implicit
}

/// Parses CLI arguments, loads config, validates all templates, then dispatches
/// to the processing pipeline for each selected template.
/// Returns overall SectionStats; exit code is determined by the caller.
fn run(args: [][:0]u8, out: Output, fresh: bool, check_fs_seconds: u8, alloc: std.mem.Allocator) !SectionStats {
    var overall = SectionStats{};
    var timer = try std.time.Timer.start();

    // Determine config path from --config before loading.
    var config_path: []const u8 = DEFAULT_CONFIG_PATH;
    var config_explicit = false;
    {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--config")) {
                i += 1;
                if (i >= args.len) {
                    usageErr(args[0]);
                    return error.Fatal;
                }
                config_path = args[i];
                config_explicit = true;
            }
        }
    }

    validatePath(config_path) catch {
        out.fatal("error: --config path contains dangerous characters or too many '../': {s}\n", .{config_path});
        overall.has_fatal = true;
        out.info("\n=== overall summary ===\n", .{});
        overall.time_ns = timer.read();
        out.overallLine(overall);
        return error.Fatal;
    };

    // Check config file exists before attempting to load.
    std.fs.cwd().access(config_path, .{}) catch {
        if (config_explicit) {
            out.fatal("error: configuration file not found: {s}\n", .{config_path});
        } else {
            out.fatal("error: default configuration file {s} missing\n", .{config_path});
        }
        overall.has_fatal = true;
        out.info("\n=== overall summary ===\n", .{});
        overall.time_ns = timer.read();
        out.overallLine(overall);
        return error.Fatal;
    };

    var cfg = config_mod.load(alloc, config_path) catch {
        // diagJsonError already printed the diagnostic to stderr.
        out.writer.flush() catch {};
        overall.has_fatal = true;
        out.info("\n=== overall summary ===\n", .{});
        overall.time_ns = timer.read();
        out.overallLine(overall);
        return error.Fatal;
    };
    defer cfg.deinit();

    // Validate all templates before processing any data.
    if (cfg.brokers.count() == 0) {
        out.fatal("error: {s} defines no conversion_templates\n", .{config_path});
        overall.has_fatal = true;
        out.info("\n=== overall summary ===\n", .{});
        overall.time_ns = timer.read();
        out.overallLine(overall);
        return error.Fatal;
    }
    {
        var it = cfg.brokers.iterator();
        while (it.next()) |entry| {
            // validate() prints its own error message directly to out.writer.
            // Quiet mode does not suppress this message (config errors are fatal startup failures).
            entry.value_ptr.validate(entry.key_ptr.*, config_path, out.writer) catch {
                out.writer.flush() catch {};
                overall.has_fatal = true;
                out.info("\n=== overall summary ===\n", .{});
                overall.time_ns = timer.read();
                out.overallLine(overall);
                return error.Fatal;
            };
        }
    }

    // Opt-in filesystem check: verifies data_dir existence + at least
    // one input file matching file_pattern_in for every template, with
    // a total deadline of `check_fs_seconds`. Errors → fatal startup
    // failure (silent empty-CSV is the alternative); warnings → print
    // and continue. `check_fs_seconds == 0` (default) skips entirely.
    if (check_fs_seconds > 0) {
        var fs_diag: diagnostics_mod.Diagnostics = .init(alloc);
        defer fs_diag.deinit();
        try config_mod.validateFilesystemWithTimeout(
            &cfg,
            alloc,
            &fs_diag,
            @as(u64, check_fs_seconds) * 1000,
        );
        var has_fs_fatal = false;
        for (fs_diag.items.items) |d| {
            switch (d.severity) {
                .@"error" => {
                    out.fatal("error: {s}\n", .{d.message});
                    has_fs_fatal = true;
                },
                .warning => out.warning("warning: {s}\n", .{d.message}),
                .info => out.info("{s}\n", .{d.message}),
            }
        }
        if (has_fs_fatal) {
            overall.has_fatal = true;
            out.info("\n=== overall summary ===\n", .{});
            overall.time_ns = timer.read();
            out.overallLine(overall);
            return error.Fatal;
        }
    }

    // Parse --template and optional --data override.
    var template_id: ?[]const u8 = null;
    var dir_path_arg: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--template")) {
            i += 1;
            if (i >= args.len) {
                usageErr(args[0]);
                return error.Fatal;
            }
            template_id = args[i];
        } else if (std.mem.eql(u8, args[i], "--data")) {
            i += 1;
            if (i >= args.len) {
                usageErr(args[0]);
                return error.Fatal;
            }
            dir_path_arg = args[i];
        } else if (std.mem.eql(u8, args[i], "--config")) {
            i += 1; // value already consumed above — skip it here
        } else if (std.mem.eql(u8, args[i], "--debug") or
            std.mem.eql(u8, args[i], "--quiet") or
            std.mem.eql(u8, args[i], "--fresh") or
            std.mem.eql(u8, args[i], "--trace") or
            std.mem.eql(u8, args[i], "--dry-run") or
            std.mem.eql(u8, args[i], "--help") or
            std.mem.startsWith(u8, args[i], "--check-fs="))
        {
            // known flags — no action needed here
        } else {
            out.fatal("error: unknown argument: {s}\n", .{args[i]});
            usageErr(args[0]);
            overall.has_fatal = true;
            return error.Fatal;
        }
    }

    if (dir_path_arg != null and template_id == null) {
        out.fatal("error: --data requires --template\n", .{});
        usageErr(args[0]);
        overall.has_fatal = true;
        return error.Fatal;
    }

    if (dir_path_arg) |p| {
        validatePath(p) catch {
            out.fatal("error: path argument contains dangerous characters or too many '../': {s}\n", .{p});
            overall.has_fatal = true;
            out.info("\n=== overall summary ===\n", .{});
            overall.time_ns = timer.read();
            out.overallLine(overall);
            return error.Fatal;
        };
    }

    // Emit 'start' trace event once templates are resolved.
    if (template_id) |bid| {
        const templates_arr = [_][]const u8{bid};
        out.event("start", .{ .schema_version = @as(u32, 1), .config = config_path, .templates = templates_arr[0..] });
    } else {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(alloc);
        var it2 = cfg.brokers.iterator();
        while (it2.next()) |entry| {
            try names.append(alloc, entry.key_ptr.*);
        }
        out.event("start", .{ .schema_version = @as(u32, 1), .config = config_path, .templates = names.items });
    }

    // xlsx pre-pass: convert xlsx files to intermediate CSV before the main processing loop.
    const xlsx_stats = try pipeline.xlsxPrePass(&cfg, alloc, out, fresh, template_id, dir_path_arg);
    if (xlsx_stats.has_fatal) {
        overall.merge(xlsx_stats);
        out.info("\n=== overall summary ===\n", .{});
        overall.time_ns = timer.read();
        out.overallLine(overall);
        return error.Fatal;
    }
    overall.merge(xlsx_stats);

    // Dispatch to processBroker for each selected template.
    if (template_id) |bid| {
        const bc = cfg.brokers.getPtr(bid) orelse {
            out.fatal("error: template '{s}' is not defined in {s}\n", .{ bid, config_path });
            overall.has_fatal = true;
            out.info("\n=== overall summary ===\n", .{});
            overall.time_ns = timer.read();
            out.overallLine(overall);
            return error.Fatal;
        };
        const dir_path = dir_path_arg orelse bc.data_dir;
        const template_stats = try pipeline.processBroker(bid, dir_path, bc, fresh, out, alloc);
        out.summary(template_stats);
        overall.merge(template_stats);
    } else {
        var it = cfg.brokers.iterator();
        while (it.next()) |entry| {
            const template_stats = try pipeline.processBroker(entry.key_ptr.*, entry.value_ptr.data_dir, entry.value_ptr, fresh, out, alloc);
            out.summary(template_stats);
            overall.merge(template_stats);
        }
    }

    out.info("\n=== overall summary ===\n", .{});
    overall.time_ns = timer.read();
    out.overallLine(overall);
    return overall;
}
