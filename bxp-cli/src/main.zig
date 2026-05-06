/// Broker eXchange Parser — CLI entry point.
///
/// Handles argument parsing, config loading, template validation, and dispatches
/// to the processing pipeline (pipeline.zig) for per-broker file conversion.
const std = @import("std");
const config_mod = @import("config");
const pipeline = @import("pipeline.zig");
const build_options = @import("build_options");

const Stdout = pipeline.Stdout;
const SectionStats = pipeline.SectionStats;
const Output = pipeline.Output;

const DEFAULT_CONFIG_PATH: []const u8 = "bxp-cli.json";

/// Prints CLI help text to stderr.
fn usage(prog: []const u8) void {
    std.debug.print(
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
        \\  --fresh            skip existing files
        \\  --dry-run          run the pipeline in memory without writing output files
        \\  --trace            emit per-row NDJSON events on stdout (forces --quiet; conflicts with --debug)
        \\  --debug            print debugging info and skipped rows as JSON
        \\  --quiet            suppress all output
        \\  --version          print version and exit
        \\  --help             print this help and exit
        \\
        \\Exit codes:
        \\  0 - success
        \\  1 - error
        \\  2 - warnings
        \\
    , .{ prog, prog, prog });
}

/// Rejects paths that contain dangerous shell metacharacters or more than one "../" component.
/// One level up (e.g. "../data/...") is allowed to support the default data_dir layout.
///
/// Rejected characters: $ | ; & > < ` ( ) \n \r \0
/// Reason: prevent CSV formula injection and path traversal attacks on downstream tools.
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
        if (std.mem.eql(u8, path[i .. i + 3], "../")) {
            count += 1;
            if (count > 1) return error.InvalidPath;
        }
    }
    // Also catch trailing ".." (path ends with "/.." or is exactly "..").
    if (std.mem.endsWith(u8, path, "/..") or std.mem.eql(u8, path, "..")) {
        if (count + 1 > 1) return error.InvalidPath;
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
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            stdout.print("bxp-cli {s}\n", .{build_options.version}) catch {};
            stdout.flush() catch {};
            return;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            usage(args[0]);
            return;
        }
        if (std.mem.eql(u8, arg, "--debug")) debug = true;
        if (std.mem.eql(u8, arg, "--quiet")) quiet = true;
        if (std.mem.eql(u8, arg, "--fresh")) fresh = true;
        if (std.mem.eql(u8, arg, "--trace")) trace = true;
        if (std.mem.eql(u8, arg, "--dry-run")) dry_run = true;
    }

    if (quiet and debug) {
        stdout.print("error: --quiet and --debug cannot be used together\n", .{}) catch {};
        stdout.flush() catch {};
        std.process.exit(1);
    }
    if (trace and debug) {
        stdout.print("error: --trace and --debug cannot be used together\n", .{}) catch {};
        stdout.flush() catch {};
        std.process.exit(1);
    }

    const out = Output{ .writer = stdout, .quiet = quiet, .debug = debug, .trace = trace, .dry_run = dry_run };

    const stats = run(args, out, fresh, alloc) catch |err| {
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
fn run(args: [][:0]u8, out: Output, fresh: bool, alloc: std.mem.Allocator) !SectionStats {
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
                    usage(args[0]);
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

    // Parse --template and optional --data override.
    var template_id: ?[]const u8 = null;
    var dir_path_arg: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--template")) {
            i += 1;
            if (i >= args.len) {
                usage(args[0]);
                return error.Fatal;
            }
            template_id = args[i];
        } else if (std.mem.eql(u8, args[i], "--data")) {
            i += 1;
            if (i >= args.len) {
                usage(args[0]);
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
            std.mem.eql(u8, args[i], "--help"))
        {
            // known flags — no action needed here
        } else {
            out.fatal("error: unknown argument: {s}\n", .{args[i]});
            usage(args[0]);
            overall.has_fatal = true;
            return error.Fatal;
        }
    }

    if (dir_path_arg != null and template_id == null) {
        out.fatal("error: --data requires --template\n", .{});
        usage(args[0]);
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
