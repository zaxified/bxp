/// Broker eXchange Parser — CLI entry point.
///
/// Handles argument parsing, config loading, template validation, and dispatches
/// to the processing pipeline (pipeline.zig) for per-broker file conversion.
const std = @import("std");
const config_mod = @import("config");
const diagnostics_mod = @import("diagnostics");
const json5_mod = @import("json5");
const btrace = @import("btrace");
const pipeline = @import("pipeline.zig");
const build_options = @import("build_options");
const builtin = @import("builtin");

const SectionStats = pipeline.SectionStats;
const Output = pipeline.Output;

const DEFAULT_CONFIG_PATH: []const u8 = "bxp-cli.json";

/// `--help` / usage text. The per-flag rows and exit codes are NOT written out
/// by hand — they render from the `flags` / `exit_codes` catalogs below, each
/// co-located with the code it documents (the parser, the exit sites), so the
/// help can never drift from them. Two stream variants pick the descriptor:
///   * `printHelp` — `--help` requested explicitly: stdout, so callers piping
///     `bxp-cli --help | grep` work without `2>&1`.
///   * `usageErr`  — argument-validation failures: stderr, alongside the error.
const USAGE_HEAD =
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
    \\
;

const USAGE_NOTE =
    \\
    \\Value-taking options accept either `--name value` or `--name=value`.
    \\
;

/// One documented CLI flag. Lives next to the argument parser (see `run`); the
/// `--help` / usage renderer is its consumer. `arg` is the value placeholder
/// (`""` = a boolean flag that takes no value).
// The flag table and exit-code catalog live in `cli_docs.zig` so the docs-md
// generator can import them without pulling in the whole CLI. Aliased here so
// the usage renderer below keeps referencing `flags` / `exit_codes` unchanged.
const cli_docs = @import("cli_docs.zig");
const FlagDoc = cli_docs.FlagDoc;
const flags = cli_docs.flags;
const ExitCodeDoc = cli_docs.ExitCodeDoc;
const exit_codes = cli_docs.exit_codes;

/// Render the full usage text — fixed head, then the `flags` rows, then the
/// `exit_codes` rows — into `w`. The single renderer behind both stream variants.
fn writeUsage(w: *std.Io.Writer, prog: []const u8) void {
    const SPACES = " " ** 24;
    w.print(USAGE_HEAD, .{ prog, prog, prog }) catch return;
    for (flags) |f| {
        var label_buf: [48]u8 = undefined;
        const label = if (f.arg.len > 0)
            std.fmt.bufPrint(&label_buf, "{s} {s}", .{ f.flag, f.arg }) catch f.flag
        else
            f.flag;
        const fill = if (label.len < 21) 21 - label.len else 1;
        w.print("  {s}{s}{s}\n", .{ label, SPACES[0..fill], f.description }) catch return;
    }
    w.writeAll(USAGE_NOTE) catch return;
    w.writeAll("\nExit codes:\n") catch return;
    for (exit_codes) |e| {
        w.print("  {d} - {s}\n", .{ e.code, e.meaning }) catch return;
    }
}

/// Print the help text to stdout. Used for `--help`.
fn printHelp(io: std.Io, prog: []const u8) void {
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;
    writeUsage(w, prog);
    w.flush() catch {};
}

/// Print the help text to stderr. Used after an argument-validation
/// failure where we want the help to accompany the error message.
fn usageErr(prog: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    writeUsage(&w, prog);
    std.debug.print("{s}", .{w.buffered()});
}

/// Rejects paths that contain dangerous shell metacharacters or more than one ".." component.
/// One level up (e.g. "../data/...") is allowed to support the default data_dir layout.
///
/// Rejected characters: $ | ; & > < ` ( ) \n \r \0
/// Reason: prevent CSV formula injection and path traversal attacks on downstream tools.
///
/// The `..` traversal counter consults `std.Io.Dir.path.isSep` so the check
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
        if (path[i] == '.' and path[i + 1] == '.' and std.Io.Dir.path.isSep(path[i + 2])) {
            count += 1;
            if (count > 1) return error.InvalidPath;
        }
    }
    // Also catch trailing ".." (path ends with "<sep>.." or is exactly "..").
    const ends_with_dotdot = std.mem.eql(u8, path, "..") or
        (path.len >= 3 and std.Io.Dir.path.isSep(path[path.len - 3]) and
            path[path.len - 2] == '.' and path[path.len - 1] == '.');
    if (ends_with_dotdot) {
        if (count + 1 > 1) return error.InvalidPath;
    }
}

// Pull in pipeline.zig's tests (writeSafeValue). Zig only discovers tests in
// the test root and in files force-referenced here, not in every transitively
// imported file.
test {
    _ = @import("pipeline.zig");
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

/// Result of matching a value-taking flag against `args[i_ptr.*]`.
const ArgMatch = union(enum) {
    no_match,
    missing_value,
    value: []const u8,
};

/// Matches `--name VALUE` (space form, advances `i_ptr` past VALUE) or
/// `--name=VALUE` (equals form, `i_ptr` unchanged). Returns `.missing_value`
/// when the space form matches but no following argument exists; callers
/// surface this as a usage error. Returns `.no_match` when `arg` does not
/// match `name` in either form. The empty-equals form (`--name=`) yields
/// `.value` with an empty slice — semantics of an empty value are left to
/// the caller (e.g. `--trace-file=` is rejected; `--config=` would be too).
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

test "matchValueArg: space form returns value and advances index" {
    var args_buf: [3][:0]u8 = .{
        @constCast(@as([:0]const u8, "prog")),
        @constCast(@as([:0]const u8, "--config")),
        @constCast(@as([:0]const u8, "foo.json")),
    };
    const args: [][:0]u8 = &args_buf;
    var i: usize = 1;
    const r = matchValueArg(args, &i, "--config");
    try std.testing.expect(r == .value);
    try std.testing.expectEqualStrings("foo.json", r.value);
    try std.testing.expectEqual(@as(usize, 2), i);
}

test "matchValueArg: equals form returns value without advancing index" {
    var args_buf: [2][:0]u8 = .{
        @constCast(@as([:0]const u8, "prog")),
        @constCast(@as([:0]const u8, "--config=foo.json")),
    };
    const args: [][:0]u8 = &args_buf;
    var i: usize = 1;
    const r = matchValueArg(args, &i, "--config");
    try std.testing.expect(r == .value);
    try std.testing.expectEqualStrings("foo.json", r.value);
    try std.testing.expectEqual(@as(usize, 1), i);
}

test "matchValueArg: space form with no following arg is missing_value" {
    var args_buf: [2][:0]u8 = .{
        @constCast(@as([:0]const u8, "prog")),
        @constCast(@as([:0]const u8, "--config")),
    };
    const args: [][:0]u8 = &args_buf;
    var i: usize = 1;
    const r = matchValueArg(args, &i, "--config");
    try std.testing.expect(r == .missing_value);
}

test "matchValueArg: unrelated arg is no_match" {
    var args_buf: [2][:0]u8 = .{
        @constCast(@as([:0]const u8, "prog")),
        @constCast(@as([:0]const u8, "--debug")),
    };
    const args: [][:0]u8 = &args_buf;
    var i: usize = 1;
    const r = matchValueArg(args, &i, "--config");
    try std.testing.expect(r == .no_match);
}

test "matchValueArg: prefix-only does not match (--configx)" {
    var args_buf: [2][:0]u8 = .{
        @constCast(@as([:0]const u8, "prog")),
        @constCast(@as([:0]const u8, "--configx")),
    };
    const args: [][:0]u8 = &args_buf;
    var i: usize = 1;
    const r = matchValueArg(args, &i, "--config");
    try std.testing.expect(r == .no_match);
}

test "matchValueArg: empty equals value returns empty slice" {
    var args_buf: [2][:0]u8 = .{
        @constCast(@as([:0]const u8, "prog")),
        @constCast(@as([:0]const u8, "--trace-file=")),
    };
    const args: [][:0]u8 = &args_buf;
    var i: usize = 1;
    const r = matchValueArg(args, &i, "--trace-file");
    try std.testing.expect(r == .value);
    try std.testing.expectEqual(@as(usize, 0), r.value.len);
}

test "validatePath: backslash separator counts as traversal on Windows builds" {
    // On Windows `std.Io.Dir.path.isSep('\\')` is true, so `..\..` should
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

/// Peak resident-set size of the current process, in kilobytes. Backs the
/// opt-in `BXP_METRICS` self-measurement line so the perf-guard suite
/// (`scripts/test-05-bench-guard.sh`) and the bench harness measure wall +
/// peak RSS on every platform without GNU `/usr/bin/time` — which is absent
/// on Windows (Git Bash) and BSD-incompatible on macOS (`-f` is rejected).
/// The process always owns a valid self-handle, so no child-handle plumbing
/// is needed.
// Zig 0.16 dropped the `std.os.windows.GetProcessMemoryInfo` wrapper, so the
// psapi entry point + its counter struct are declared locally for the
// Windows peak-RSS path below (BXP_METRICS opt-in only).
const PROCESS_MEMORY_COUNTERS = extern struct {
    cb: std.os.windows.DWORD,
    PageFaultCount: std.os.windows.DWORD,
    PeakWorkingSetSize: usize,
    WorkingSetSize: usize,
    QuotaPeakPagedPoolUsage: usize,
    QuotaPagedPoolUsage: usize,
    QuotaPeakNonPagedPoolUsage: usize,
    QuotaNonPagedPoolUsage: usize,
    PagefileUsage: usize,
    PeakPagefileUsage: usize,
};
extern "psapi" fn GetProcessMemoryInfo(
    process: std.os.windows.HANDLE,
    counters: *PROCESS_MEMORY_COUNTERS,
    cb: std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;

fn peakRssKb() u64 {
    if (builtin.os.tag == .windows) {
        var pmc: PROCESS_MEMORY_COUNTERS = undefined;
        pmc.cb = @sizeOf(PROCESS_MEMORY_COUNTERS);
        if (!GetProcessMemoryInfo(std.os.windows.GetCurrentProcess(), &pmc, pmc.cb).toBool()) return 0;
        return @intCast(pmc.PeakWorkingSetSize / 1024);
    }
    const ru = std.posix.getrusage(std.posix.rusage.SELF);
    const maxrss: u64 = if (ru.maxrss > 0) @intCast(ru.maxrss) else 0;
    // getrusage reports ru_maxrss in kilobytes on Linux but in bytes on
    // Darwin/macOS — normalise the latter to kilobytes.
    return if (builtin.os.tag == .macos) maxrss / 1024 else maxrss;
}

/// Collect process args into a freshly-allocated `[][:0]u8`. Zig 0.16 removed
/// `std.process.argsAlloc`; the runtime now hands `main` a `process.Args` that
/// we iterate. Each arg is duped (mutable, sentinel-terminated) into `dest` so
/// the existing slice-based parser keeps working unchanged. `gpa` backs the
/// iterator's transient buffers (Windows/WASI); caller frees the result.
fn collectArgs(
    raw: std.process.Args,
    gpa: std.mem.Allocator,
    dest: std.mem.Allocator,
) ![][:0]u8 {
    var it = try std.process.Args.Iterator.initAllocator(raw, gpa);
    defer it.deinit();
    var list: std.ArrayList([:0]u8) = .empty;
    errdefer {
        for (list.items) |a| dest.free(a);
        list.deinit(dest);
    }
    while (it.next()) |a| try list.append(dest, try dest.dupeZ(u8, a));
    return list.toOwnedSlice(dest);
}

pub fn main(init: std.process.Init) !void {
    // Io instance from the runtime entry point — the single handle for all
    // filesystem + timing access (Zig 0.16; `std.fs`/`std.time` no longer have
    // io-free entry points). Threaded into `pipeline.Runtime` below.
    const io = init.io;

    // Opt-in self-measurement: when `BXP_METRICS` is set, emit one
    // `bxp-metrics wall_ms=<N> peak_rss_kb=<N>` line to stderr just before
    // exit. Started first so the wall covers the whole process. See
    // `peakRssKb` for why this lives in the binary rather than a wrapper.
    const proc_start = std.Io.Clock.Timestamp.now(io, .awake);

    // Allocator pick: `DebugAllocator` in Debug builds for leak tracking +
    // double-free detection; `smp_allocator` in ReleaseFast / ReleaseSafe
    // because the per-block parallel pipeline forks N worker threads that
    // all allocate concurrently — `DebugAllocator`'s per-call mutex
    // serialises every allocation across threads and choked S1 2M down to
    // 1.58× speedup (sys time was ~89 s on a 25 s wall). `smp_allocator`
    // is thread-aware with per-thread caches and removes that contention
    // entirely.
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc: std.mem.Allocator = switch (@import("builtin").mode) {
        .Debug => gpa.allocator(),
        else => std.heap.smp_allocator,
    };

    // Resolve the `BXP_METRICS` opt-in. Any non-empty value enables the
    // trailing metrics line; absence disables it. Read from the runtime's
    // pre-built environ map (Zig 0.16 dropped `std.process.getEnvVarOwned`).
    const metrics_enabled = blk: {
        const v = init.environ_map.get("BXP_METRICS") orelse break :blk false;
        break :blk v.len > 0;
    };

    // Per-block worker fan-out count. The parallel pipeline dispatches up to
    // `max_workers` tasks per block via `std.Io.Group.async` and joins on
    // `Group.await`. The worker threads themselves live in the runtime `io`'s
    // own persistent pool (Zig 0.16 — `std.Thread.Pool`/`WaitGroup` were
    // removed in favour of the `Io` async model), so fork cost is enqueue-cost,
    // not OS thread creation. `getCpuCount` respects cpuset affinity on Linux.
    const ncpu = std.Thread.getCpuCount() catch 1;
    // Clamp to the pipeline's per-block worker ceiling. Above it, any block
    // with more records than the limit would otherwise hit
    // `error.TooManyWorkers` and abort the whole run with no output (reachable
    // today on >256-logical-CPU hosts, e.g. dual-socket EPYC). The cap only
    // governs parallel fan-out, so the output is serial-equivalent regardless.
    const max_workers = @min(ncpu, pipeline.MAX_WORKERS_LIMIT);
    const runtime = pipeline.Runtime{
        .max_workers = max_workers,
        .io = io,
    };

    // Buffered stdout writer. 4 KB is enough for --version / --help; the
    // pipeline uses its own per-file OUT_FILE_BUF_SIZE buffer for bulk output.
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_fw.interface;

    // Collect args into a `[][:0]u8` from the runtime's arg iterator (Zig 0.16
    // removed `std.process.argsAlloc`). Duped into `alloc` so the rest of the
    // parser keeps its mutable-slice contract; freed at scope end.
    const args = try collectArgs(init.minimal.args, init.gpa, alloc);
    defer {
        for (args) |a| alloc.free(a);
        alloc.free(args);
    }

    // First pass: scan for flags that need to be known before `run()` is
    // called. --version and --help short-circuit immediately; the rest are
    // stored as booleans and forwarded via the Output struct.
    var debug = false;
    var debug_json = false;
    var quiet = false;
    var fresh = false;
    var trace = false;
    var dry_run = false;
    var check_fs_seconds: u8 = 0;
    var trace_file_path: ?[]const u8 = null;
    // Value-taking flags accept both `--name VALUE` and `--name=VALUE` forms
    // via `matchValueArg`. Pure flags only accept the bare token. Unknown
    // arguments are silently skipped here — they're either consumed by the
    // second pass in `run()` (--config, --template, --data) or rejected
    // there as truly unknown.
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version")) {
            stdout.print("bxp-cli {s}\n", .{build_options.version}) catch {};
            stdout.flush() catch {};
            return;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            printHelp(io, args[0]);
            return;
        }
        if (std.mem.eql(u8, arg, "--debug")) { debug = true; continue; }
        // `--debug=json` is the machine-readable variant: instead of the human
        // stdout summaries + stderr diagnostics, the whole run produces ONE
        // JSON document on stdout (per-template + overall counts + captured
        // message lines). It does NOT enable the per-row unmatched-row dump
        // that bare `--debug` triggers — that would pollute the JSON stream.
        if (std.mem.startsWith(u8, arg, "--debug=")) {
            const val = arg["--debug=".len..];
            if (std.mem.eql(u8, val, "json")) {
                debug_json = true;
            } else {
                std.debug.print("error: --debug value must be 'json': got '{s}'\n", .{val});
                std.process.exit(1);
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet")) { quiet = true; continue; }
        if (std.mem.eql(u8, arg, "--fresh")) { fresh = true; continue; }
        if (std.mem.eql(u8, arg, "--dry-run")) { dry_run = true; continue; }
        // `--trace` and `--trace=bin` are accepted (both produce the binary
        // framed trace stream — the only format since the NDJSON path was
        // removed in v0.3.0). `--trace=<anything else>` is an error; the
        // explicit `=bin` form is kept for users who scripted it against
        // older releases. `--trace` does NOT take a separate space-form value
        // because it's primarily a bare flag — only the historical `=bin`
        // variant is recognised.
        if (std.mem.eql(u8, arg, "--trace")) { trace = true; continue; }
        if (std.mem.startsWith(u8, arg, "--trace=")) {
            const val = arg["--trace=".len..];
            if (std.mem.eql(u8, val, "bin")) {
                trace = true;
            } else {
                std.debug.print("error: --trace value must be 'bin' (NDJSON support was removed): got '{s}'\n", .{val});
                std.process.exit(1);
            }
            continue;
        }
        switch (matchValueArg(args, &i, "--trace-file")) {
            .value => |v| {
                if (v.len == 0) {
                    std.debug.print("error: --trace-file requires a non-empty path\n", .{});
                    std.process.exit(1);
                }
                trace_file_path = v;
                continue;
            },
            .missing_value => {
                std.debug.print("error: --trace-file requires a path argument\n", .{});
                std.process.exit(1);
            },
            .no_match => {},
        }
        switch (matchValueArg(args, &i, "--check-fs")) {
            .value => |v| {
                check_fs_seconds = std.fmt.parseUnsigned(u8, v, 10) catch {
                    std.debug.print("error: --check-fs requires a non-negative integer (seconds): got '{s}'\n", .{v});
                    std.process.exit(1);
                };
                continue;
            },
            .missing_value => {
                std.debug.print("error: --check-fs requires a non-negative integer (seconds) argument\n", .{});
                std.process.exit(1);
            },
            .no_match => {},
        }
        // Fall through: --config / --template / --data and their values, or
        // unknown args, are handled in the `run()` second pass.
    }

    // Conflicting-flag validation. These combinations produce contradictory
    // output semantics and are rejected up-front rather than silently
    // picking a winner: --quiet and --debug are opposites; --trace and
    // --debug both affect raw row output in incompatible ways (binary
    // BXTB stream vs. human-readable JSON dumps).
    if (quiet and (debug or debug_json)) {
        std.debug.print("error: --quiet and --debug cannot be used together\n", .{});
        std.process.exit(1);
    }
    if (trace and (debug or debug_json)) {
        std.debug.print("error: --trace and --debug cannot be used together\n", .{});
        std.process.exit(1);
    }
    if (debug and debug_json) {
        std.debug.print("error: --debug and --debug=json cannot be used together\n", .{});
        std.process.exit(1);
    }

    const trace_mode: pipeline.TraceMode = if (trace) .bin else .off;

    // Bin mode wraps the existing stdout writer in a btrace.Writer that emits
    // magic + version on construction. Allocated on the stack — its address
    // is given to Output via btrace_writer pointer.
    var btw_storage: btrace.Writer = undefined;
    var btw_init_ok = false;
    if (trace_mode == .bin) {
        btw_storage = btrace.Writer.init(stdout) catch |err| {
            std.debug.print("error: --trace=bin init failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        btw_init_ok = true;
    }

    // `--trace-file=<path>` opens a sidecar bin trace file that always
    // receives the full per-row detail stream, independent of --trace= mode.
    // The file writer is kept alive for the whole run via a defer-close
    // here; flush happens in `closeTraceFile` after `run()` returns.
    var trace_file_buf: [65536]u8 = undefined;
    var trace_file_handle: ?std.Io.File = null;
    var trace_file_fw_storage: std.Io.File.Writer = undefined;
    var trace_file_btw_storage: btrace.Writer = undefined;
    var trace_file_btw_init_ok = false;
    if (trace_file_path) |path| {
        validatePath(path) catch {
            std.debug.print("error: --trace-file path rejected: '{s}'\n", .{path});
            std.process.exit(1);
        };
        const f = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
            std.debug.print("error: --trace-file create failed: {s} ({s})\n", .{ @errorName(err), path });
            std.process.exit(1);
        };
        trace_file_handle = f;
        trace_file_fw_storage = f.writer(io, &trace_file_buf);
        trace_file_btw_storage = btrace.Writer.init(&trace_file_fw_storage.interface) catch |err| {
            std.debug.print("error: --trace-file init failed: {s}\n", .{@errorName(err)});
            f.close(io);
            std.process.exit(1);
        };
        trace_file_btw_init_ok = true;
    }

    // `--debug=json` captures every warning/fatal line into this sink instead
    // of stderr, so they can be folded into the single JSON document. Lives
    // for the whole run; strings are allocated from `alloc`.
    var msg_sink = std.array_list.Managed([]const u8).init(alloc);
    defer msg_sink.deinit();

    const out = Output{
        .writer = stdout,
        .quiet = quiet,
        .debug = debug,
        .trace = trace_mode,
        .dry_run = dry_run,
        .json_debug = debug_json,
        .msg_sink = if (debug_json) &msg_sink else null,
        .msg_alloc = alloc,
        .btrace_writer = if (btw_init_ok) &btw_storage else null,
        .btrace_file_writer = if (trace_file_btw_init_ok) &trace_file_btw_storage else null,
    };

    // `run()` returns `error.Fatal` when it has already printed a diagnostic
    // and wants a clean exit-1 — no additional message needed. Any other
    // propagated error is unexpected (e.g. OOM); in release mode we print
    // the error name rather than crashing with an unformatted Zig trace. In
    // --debug mode we re-throw so the Zig runtime prints its full stack trace.
    const stats = run(args, out, fresh, check_fs_seconds, runtime, alloc) catch |err| {
        // `error.Fatal` means a diagnostic was already emitted (printed to
        // stderr, or captured into `msg_sink` under --debug=json). Any other
        // error is unexpected (e.g. OOM): re-throw under --debug for a stack
        // trace, else surface the error name through the same diagnostic sink.
        if (err != error.Fatal) {
            if (debug) return err; // propagate — Zig prints trace
            out.fatal("---\n# fatal error: {s}\n", .{@errorName(err)});
        }
        // --debug=json: the early-exit path has no per-template breakdown, so
        // emit a minimal document — `fatal:true` + the captured message lines
        // carry the reason.
        if (debug_json) {
            emitDebugJson(stdout, &[_]TmplJsonEntry{}, .{ .has_fatal = true }, msg_sink.items, true);
        }
        out.binEmitDone(1);
        closeTraceFile(io, &trace_file_fw_storage, trace_file_handle);
        std.process.exit(1);
    };

    // Exit code precedence: fatal beats warnings beats clean. `run()`
    // can return stats with `has_fatal = true` without raising
    // `error.Fatal` (e.g. `processBroker` flagging a dir-not-found per
    // template and continuing on to the next), so we must check both
    // signals here. Warnings-only configs (no fatal anywhere) still
    // return 2 as documented.
    const exit_code: u8 = if (stats.has_fatal) 1 else if (stats.warnings > 0) 2 else 0;
    out.binEmitDone(@intCast(exit_code));
    closeTraceFile(io, &trace_file_fw_storage, trace_file_handle);

    // Opt-in self-measurement line on stderr (kept off stdout so it never
    // pollutes data/trace output). Parsed by the perf-guard + bench scripts.
    if (metrics_enabled) {
        const wall_ns = proc_start.untilNow(io).raw.nanoseconds;
        const wall_ms: u64 = if (wall_ns > 0) @intCast(@divTrunc(wall_ns, std.time.ns_per_ms)) else 0;
        var mbuf: [128]u8 = undefined;
        var mfw = std.Io.File.stderr().writer(io, &mbuf);
        mfw.interface.print(
            "bxp-metrics wall_ms={d} peak_rss_kb={d}\n",
            .{ wall_ms, peakRssKb() },
        ) catch {};
        mfw.interface.flush() catch {};
    }

    if (exit_code != 0) std.process.exit(exit_code);
    // exit(0) implicit
}

/// Flush + close the `--trace-file` sidecar (no-op when not opened).
/// Mirrors the implicit close that happens for stdout when the process exits.
/// Errors are swallowed — by the time this runs the bin frames are written;
/// a flush failure here just means we lose the trailing buffered bytes,
/// not the run itself.
fn closeTraceFile(io: std.Io, fw: *std.Io.File.Writer, handle: ?std.Io.File) void {
    if (handle) |f| {
        fw.interface.flush() catch {};
        f.close(io);
    }
}

/// One per-template entry in the `--debug=json` run-summary document.
const TmplJsonEntry = struct {
    id: []const u8,
    files: u32,
    rows_in: u64,
    rows_out: u64,
    warnings: u32,
    errors: u32,
    time_ms: u64,
};

/// Appends one template's stats to the `--debug=json` collector. Allocation
/// failure silently drops the entry — a summary line is never worth aborting
/// the run for.
fn appendTemplateJson(list: *std.array_list.Managed(TmplJsonEntry), id: []const u8, stats: SectionStats) void {
    list.append(.{
        .id = id,
        .files = stats.files,
        .rows_in = stats.rows_in,
        .rows_out = stats.rows_out,
        .warnings = stats.warnings,
        .errors = if (stats.has_fatal) 1 else 0,
        .time_ms = stats.time_ns / std.time.ns_per_ms,
    }) catch {};
}

/// Serialises the machine-readable run summary for `--debug=json` to `writer`
/// (stdout) as one JSON object. Stable schema for `bxp_simulate` / CI: counts
/// are structured (robust to wording changes in the human output) and the
/// `messages` array preserves the captured warning/fatal text for detail.
/// `fatal=true` is emitted on the early-exit path where per-template data is
/// unavailable — the `messages` array then carries the failure reason.
fn emitDebugJson(
    writer: *pipeline.Writer,
    templates: []const TmplJsonEntry,
    overall: SectionStats,
    messages: []const []const u8,
    fatal: bool,
) void {
    const Doc = struct {
        fatal: bool,
        templates: []const TmplJsonEntry,
        overall: TmplJsonEntry,
        messages: []const []const u8,
    };
    const doc = Doc{
        .fatal = fatal,
        .templates = templates,
        .overall = .{
            .id = "*",
            .files = overall.files,
            .rows_in = overall.rows_in,
            .rows_out = overall.rows_out,
            .warnings = overall.warnings,
            .errors = if (overall.has_fatal) 1 else 0,
            .time_ms = overall.time_ns / std.time.ns_per_ms,
        },
        .messages = messages,
    };
    std.json.Stringify.value(doc, .{ .whitespace = .indent_2 }, writer) catch {};
    writer.writeAll("\n") catch {};
    writer.flush() catch {};
}

/// Parses CLI arguments, loads config, validates all templates, then dispatches
/// to the processing pipeline for each selected template.
/// Returns overall SectionStats; exit code is determined by the caller.
fn run(args: [][:0]u8, out: Output, fresh: bool, check_fs_seconds: u8, runtime: pipeline.Runtime, alloc: std.mem.Allocator) !SectionStats {
    var overall = SectionStats{};
    var timer = pipeline.Timer.begin(runtime.io);

    // Per-template entries for the `--debug=json` summary (empty otherwise).
    var json_templates = std.array_list.Managed(TmplJsonEntry).init(alloc);
    defer json_templates.deinit();

    // Determine config path from --config before loading.
    var config_path: []const u8 = DEFAULT_CONFIG_PATH;
    var config_explicit = false;
    {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            switch (matchValueArg(args, &i, "--config")) {
                .value => |v| {
                    config_path = v;
                    config_explicit = true;
                },
                .missing_value => {
                    usageErr(args[0]);
                    return error.Fatal;
                },
                .no_match => {},
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
    std.Io.Dir.cwd().access(runtime.io, config_path, .{}) catch {
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

    // `config_mod.load` parses the JSON5 file, resolves the BrokerConfig
    // structs, and validates field types. On failure it has already written
    // a human-readable diagnostic to stderr (`diagJsonError`), so we only
    // need to flush stdout, update stats, and return the sentinel error.
    var cfg = config_mod.load(alloc, config_path) catch |err| {
        // For parse/validation failures `diagJsonError` has already written a
        // human-readable diagnostic to stderr. `FileTooBig` fires inside the
        // initial `readToEndAlloc`, BEFORE any diagnostic is produced, so it
        // would otherwise be a silent fatal — name the cap and the actual size.
        if (err == error.FileTooBig) {
            const on_disk: u64 = if (std.Io.Dir.cwd().statFile(runtime.io, config_path, .{})) |st| st.size else |_| 0;
            out.fatal("fatal error: config '{s}' is {d} bytes, exceeding the {d} MB limit (CONFIG_MAX_FILE_SIZE)\n", .{ config_path, on_disk, config_mod.CONFIG_MAX_FILE_SIZE / (1024 * 1024) });
        }
        out.writer.flush() catch {};
        overall.has_fatal = true;
        out.info("\n=== overall summary ===\n", .{});
        overall.time_ns = timer.read();
        out.overallLine(overall);
        return error.Fatal;
    };
    defer cfg.deinit();

    // Phase G7 unknown-key check promoted to bxp-cli load path. Walks
    // the raw JSON5 tree (not the parsed BrokerConfig) so it can see
    // typos in keys that the loader would otherwise silently ignore
    // (`file_patter_in: ".csv"` → loader uses default empty pattern,
    // pipeline produces empty CSV with no clue what went wrong).
    //
    // Re-reads the config file. The double-read is unavoidable without
    // surgery on `config_mod.load`'s signature; cost is negligible
    // (< 1 MB file, once per startup).
    {
        const file = std.Io.Dir.cwd().openFile(runtime.io, config_path, .{}) catch null;
        if (file) |f| {
            defer f.close(runtime.io);
            var rd_buf: [4096]u8 = undefined;
            var fr = f.reader(runtime.io, &rd_buf);
            const raw = fr.interface.allocRemaining(alloc, .limited(1 << 20)) catch null;
            if (raw) |bytes| {
                defer alloc.free(bytes);
                var keys_arena = std.heap.ArenaAllocator.init(alloc);
                defer keys_arena.deinit();
                const ka = keys_arena.allocator();
                if (json5_mod.preprocess(ka, bytes)) |content| {
                    if (std.json.parseFromSliceLeaky(std.json.Value, ka, content, .{
                        .duplicate_field_behavior = .use_last,
                    })) |raw_tree| {
                        var keys_diag: diagnostics_mod.Diagnostics = .init(ka);
                        try config_mod.validateUnknownKeysCollect(&raw_tree, ka, &keys_diag);
                        var has_keys_fatal = false;
                        for (keys_diag.items.items) |d| {
                            switch (d.severity) {
                                .@"error" => {
                                    // `did you mean ...?` is already
                                    // baked into `d.message`; the
                                    // `suggest` field is for structured
                                    // GUI consumption, skip it here.
                                    out.fatal("error: {s}\n", .{d.message});
                                    has_keys_fatal = true;
                                },
                                .warning => out.warning("warning: {s}\n", .{d.message}),
                                .info => out.info("{s}\n", .{d.message}),
                            }
                        }
                        if (has_keys_fatal) {
                            overall.has_fatal = true;
                            out.info("\n=== overall summary ===\n", .{});
                            overall.time_ns = timer.read();
                            out.overallLine(overall);
                            return error.Fatal;
                        }
                    } else |_| {}
                } else |_| {}
            }
        }
    }

    // Validate all templates before processing any data. Doing this in a
    // dedicated pass (rather than inside processBroker) means a config error
    // in template B surfaces even when template A was selected via --template;
    // it also gives the user a complete list of config problems in one run
    // rather than failing on the first bad template.
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

    // Phase G expression validation promoted to bxp-cli load path: parses
    // every input_schema / row_rules / pre_pass expression and surfaces
    // load-time fatals for unknown functions, unknown LOOKUP block names,
    // wrong arg counts, and `SPLIT_PART` literal indexes ≤ 0. Without
    // this, the same problems would surface as silent `""` substitutions
    // during row processing and produce empty-column output.
    //
    // Arena-scoped: `expr.eval`'s Context.alloc allocates intermediate
    // strings (concat results, error_detail, etc.) that aren't tracked
    // by callers — using the main GPA directly leaks across every
    // expression. The arena is freed once after diagnostics are
    // emitted; messages are printed before teardown so we don't need
    // to dupe them onto the outer allocator.
    {
        var expr_arena = std.heap.ArenaAllocator.init(alloc);
        defer expr_arena.deinit();
        const expr_alloc = expr_arena.allocator();
        var expr_diag: diagnostics_mod.Diagnostics = .init(expr_alloc);
        var b_it = cfg.brokers.iterator();
        while (b_it.next()) |entry| {
            try entry.value_ptr.validateExprsCollect(entry.key_ptr.*, expr_alloc, &expr_diag);
            // Phase G8: dead-config detection. Warning-severity, never
            // blocks load — `unused_pre_pass` and `unused_input_var`
            // are hygiene findings, not bugs that produce wrong output.
            try config_mod.validateUnusedCollect(entry.value_ptr, entry.key_ptr.*, expr_alloc, &expr_diag);
        }
        var has_expr_fatal = false;
        var any_warning = false;
        for (expr_diag.items.items) |d| {
            switch (d.severity) {
                .@"error" => {
                    out.fatal("error: {s}\n", .{d.message});
                    has_expr_fatal = true;
                },
                .warning => {
                    out.warning("warning: {s}\n", .{d.message});
                    any_warning = true;
                },
                .info => out.info("{s}\n", .{d.message}),
            }
        }
        if (any_warning) overall.warnings += 1;
        if (has_expr_fatal) {
            overall.has_fatal = true;
            out.info("\n=== overall summary ===\n", .{});
            overall.time_ns = timer.read();
            out.overallLine(overall);
            return error.Fatal;
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

    // Second argument-parsing pass: extract --template / --data values.
    // These could not be parsed in `main()` because the Output struct (needed
    // for error reporting) isn't available until after the config is loaded.
    // --config is consumed here by skipping its value token; all other flags
    // were already handled in the first pass inside `main()`.
    var template_id: ?[]const u8 = null;
    var dir_path_arg: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        // Value-taking flags: `matchValueArg` consumes both space and equals
        // forms. `--config` / `--trace-file` / `--check-fs` were already
        // applied earlier; we just need to advance past their value token.
        switch (matchValueArg(args, &i, "--template")) {
            .value => |v| { template_id = v; continue; },
            .missing_value => {
                usageErr(args[0]);
                overall.has_fatal = true;
                return error.Fatal;
            },
            .no_match => {},
        }
        switch (matchValueArg(args, &i, "--data")) {
            .value => |v| { dir_path_arg = v; continue; },
            .missing_value => {
                usageErr(args[0]);
                overall.has_fatal = true;
                return error.Fatal;
            },
            .no_match => {},
        }
        switch (matchValueArg(args, &i, "--config")) {
            .value => continue,
            .missing_value => {
                usageErr(args[0]);
                overall.has_fatal = true;
                return error.Fatal;
            },
            .no_match => {},
        }
        switch (matchValueArg(args, &i, "--trace-file")) {
            .value => continue,
            .missing_value => {
                usageErr(args[0]);
                overall.has_fatal = true;
                return error.Fatal;
            },
            .no_match => {},
        }
        switch (matchValueArg(args, &i, "--check-fs")) {
            .value => continue,
            .missing_value => {
                usageErr(args[0]);
                overall.has_fatal = true;
                return error.Fatal;
            },
            .no_match => {},
        }
        // Pure flags (no value).
        const a = args[i];
        if (std.mem.eql(u8, a, "--debug") or
            std.mem.startsWith(u8, a, "--debug=") or
            std.mem.eql(u8, a, "--quiet") or
            std.mem.eql(u8, a, "--fresh") or
            std.mem.eql(u8, a, "--trace") or
            std.mem.startsWith(u8, a, "--trace=") or
            std.mem.eql(u8, a, "--dry-run") or
            std.mem.eql(u8, a, "--help") or
            std.mem.eql(u8, a, "--version"))
        {
            continue;
        }
        out.fatal("error: unknown argument: {s}\n", .{a});
        usageErr(args[0]);
        overall.has_fatal = true;
        return error.Fatal;
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

    // zip pre-pass: unpack each *.zip in a data_dir into flat intermediate CSV
    // files before the xlsx/main passes (a zipped CSV export, e.g. RÚIAN).
    const zip_stats = try pipeline.zipPrePass(&cfg, alloc, out, fresh, template_id, dir_path_arg, runtime);
    if (zip_stats.has_fatal) {
        overall.merge(zip_stats);
        out.info("\n=== overall summary ===\n", .{});
        overall.time_ns = timer.read();
        out.overallLine(overall);
        return error.Fatal;
    }
    overall.merge(zip_stats);

    // xlsx pre-pass: convert xlsx files to intermediate CSV before the main processing loop.
    const xlsx_stats = try pipeline.xlsxPrePass(&cfg, alloc, out, fresh, template_id, dir_path_arg, runtime);
    if (xlsx_stats.has_fatal) {
        overall.merge(xlsx_stats);
        out.info("\n=== overall summary ===\n", .{});
        overall.time_ns = timer.read();
        out.overallLine(overall);
        return error.Fatal;
    }
    overall.merge(xlsx_stats);

    // Dispatch to processBroker for each selected template.
    // When --template is given we look up the BrokerConfig by ID; the
    // `cfg.brokers.getPtr` failure here is distinct from the validation-loop
    // above: the user supplied an ID that exists in the file but is somehow
    // missing from the loaded map (shouldn't happen, but is defensive). When
    // processing all templates we iterate in insertion order (ArrayHashMap).
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
        const template_stats = try pipeline.processBroker(bid, dir_path, bc, fresh, out, runtime, alloc);
        out.summary(template_stats);
        if (out.json_debug) appendTemplateJson(&json_templates, bid, template_stats);
        overall.merge(template_stats);
    } else {
        var it = cfg.brokers.iterator();
        while (it.next()) |entry| {
            const template_stats = try pipeline.processBroker(entry.key_ptr.*, entry.value_ptr.data_dir, entry.value_ptr, fresh, out, runtime, alloc);
            out.summary(template_stats);
            if (out.json_debug) appendTemplateJson(&json_templates, entry.key_ptr.*, template_stats);
            overall.merge(template_stats);
        }
    }

    out.info("\n=== overall summary ===\n", .{});
    overall.time_ns = timer.read();
    out.overallLine(overall);
    if (out.json_debug) {
        emitDebugJson(out.writer, json_templates.items, overall, out.msg_sink.?.items, false);
    }
    return overall;
}
