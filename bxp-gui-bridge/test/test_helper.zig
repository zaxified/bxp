//! bridge-test-helper — controllable child process for bridge unit tests.
//!
//! The bridge tests exercise real subprocess behaviour (spawn, wait, pipe
//! drain, stdout/stderr split, cwd, cancel, truncate). Replacing OS
//! binaries (`/bin/true`, `/bin/echo`, `/bin/sleep`, …) with this helper
//! makes the suite cross-platform — Zig builds the helper for whatever
//! OS the test runs on, no `Platform.isWindows return error.SkipZigTest`
//! escape hatch needed.
//!
//! Subcommand surface, dispatched on argv[1]:
//!
//!   exit <N>           — exit with code N
//!   echo <text>...     — write space-joined args + "\n" to stdout, exit 0
//!   stderr <text>...   — same but on stderr
//!   both               — write "to-stdout\n" + "to-stderr\n" on each stream
//!   sleep <seconds>    — block (used by the cancel test)
//!   stdout-bytes <N>   — write N 'a' bytes to stdout (truncate test)
//!   pwd                — write the process working directory + "\n"
//!   stdin-echo         — read stdin to EOF, write the bytes back to stdout
//!                        (exercises bridge_run stdin pipe)
//!   stdout-binary <N>  — write N bytes 0x00..0xFF cycling (no newlines;
//!                        exercises bridge_run_streaming raw-chunk streaming)
//!
//! Unknown subcommand → exit 2 + diagnostic on stderr so a typo in the
//! test surfaces loudly instead of as "unexplained exit 0".

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Zig 0.16 retired std.process.argsAlloc; collect from Init's iterator.
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer arg_it.deinit();
    var argv_list: std.ArrayList([:0]const u8) = .empty;
    while (arg_it.next()) |arg| try argv_list.append(a, try a.dupeZ(u8, arg));
    const argv = argv_list.items;

    if (argv.len < 2) {
        try writeStderrLn(io, "test_helper: missing subcommand", .{});
        std.process.exit(2);
    }

    const cmd = argv[1];

    if (std.mem.eql(u8, cmd, "exit")) {
        if (argv.len != 3) return badArgs(io, "exit needs <N>");
        const code = std.fmt.parseInt(u8, argv[2], 10) catch return badArgs(io, "exit code must be u8");
        std.process.exit(code);
    }

    if (std.mem.eql(u8, cmd, "echo")) {
        try writeStdoutJoined(io, argv[2..]);
        return;
    }

    if (std.mem.eql(u8, cmd, "stderr")) {
        try writeStderrJoined(io, argv[2..]);
        return;
    }

    if (std.mem.eql(u8, cmd, "both")) {
        // Use raw unbuffered writes here (not writeStdoutLn / writeStderrLn)
        // so neither message can sit in a Zig-side buffer at process exit.
        // The buffered helpers flush before returning, but pairing two
        // independent buffered writers across two streams just before
        // `main()` returns previously surfaced a flake where one of the
        // two messages occasionally never reached the bridge reader. With
        // direct writeStreamingAll the bytes hit the kernel pipe synchronously
        // and the parent test passes without the 3× retry crutch.
        try std.Io.File.stdout().writeStreamingAll(io, "to-stdout\n");
        try std.Io.File.stderr().writeStreamingAll(io, "to-stderr\n");
        return;
    }

    if (std.mem.eql(u8, cmd, "sleep")) {
        if (argv.len != 3) return badArgs(io, "sleep needs <seconds>");
        const seconds = std.fmt.parseInt(u32, argv[2], 10) catch return badArgs(io, "sleep seconds must be u32");
        const dur: std.Io.Clock.Duration = .{ .raw = std.Io.Duration.fromSeconds(seconds), .clock = .awake };
        dur.sleep(io) catch {};
        return;
    }

    if (std.mem.eql(u8, cmd, "stdout-bytes")) {
        if (argv.len != 3) return badArgs(io, "stdout-bytes needs <N>");
        const n = std.fmt.parseInt(usize, argv[2], 10) catch return badArgs(io, "stdout-bytes count must be usize");
        try writeStdoutFill(io, n, 'a');
        return;
    }

    if (std.mem.eql(u8, cmd, "pwd")) {
        const cwd = try std.process.currentPathAlloc(io, a);
        try writeStdoutLn(io, "{s}", .{cwd});
        return;
    }

    if (std.mem.eql(u8, cmd, "stdin-echo")) {
        try copyStdinToStdout(io);
        return;
    }

    if (std.mem.eql(u8, cmd, "stdout-binary")) {
        if (argv.len != 3) return badArgs(io, "stdout-binary needs <N>");
        const n = std.fmt.parseInt(usize, argv[2], 10) catch return badArgs(io, "stdout-binary count must be usize");
        try writeStdoutCyclingBytes(io, n);
        return;
    }

    try writeStderrLn(io, "test_helper: unknown subcommand '{s}'", .{cmd});
    std.process.exit(2);
}

// ── thin wrappers around stdout/stderr writers ─────────────────────────
// Zig 0.16 routes stdout/stderr access through Io: std.Io.File.stdout() /
// .stderr() + the buffered writer pattern. Each helper builds a small stack
// buffer, writes, and flushes — tiny outputs (< 8 KB) so a single 1 KB buffer
// is plenty for all subcommands except `stdout-bytes` (which has its own loop).

fn writeStdoutLn(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(fmt ++ "\n", args);
    try w.interface.flush();
}

fn writeStderrLn(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.print(fmt ++ "\n", args);
    try w.interface.flush();
}

fn writeStdoutJoined(io: std.Io, parts: []const [:0]const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    for (parts, 0..) |p, i| {
        if (i > 0) try w.interface.writeAll(" ");
        try w.interface.writeAll(p);
    }
    try w.interface.writeAll("\n");
    try w.interface.flush();
}

fn writeStderrJoined(io: std.Io, parts: []const [:0]const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    for (parts, 0..) |p, i| {
        if (i > 0) try w.interface.writeAll(" ");
        try w.interface.writeAll(p);
    }
    try w.interface.writeAll("\n");
    try w.interface.flush();
}

fn writeStdoutFill(io: std.Io, count: usize, byte: u8) !void {
    var buf: [8192]u8 = undefined;
    @memset(&buf, byte);
    var fbuf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &fbuf);
    var remaining = count;
    while (remaining > 0) {
        const take = @min(remaining, buf.len);
        try w.interface.writeAll(buf[0..take]);
        remaining -= take;
    }
    try w.interface.flush();
}

/// Read stdin to EOF and write everything received back to stdout
/// verbatim. Used by the `bridge_run` stdin pipe test — the bridge writes
/// a payload to the child's stdin, the child echoes it to stdout, and the
/// bridge captures stdout. Round-trip equality proves the writer thread
/// and pipe wiring work end-to-end.
fn copyStdinToStdout(io: std.Io) !void {
    var read_buf: [8192]u8 = undefined;
    const stdin = std.Io.File.stdin();
    var wbuf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &wbuf);
    while (true) {
        const n = stdin.readStreaming(io, &.{read_buf[0..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        try w.interface.writeAll(read_buf[0..n]);
    }
    try w.interface.flush();
}

/// Write N bytes whose values cycle through 0x00..0xFF (i.e. byte i has
/// value `i & 0xFF`). Exercises `bridge_run_streaming` raw-chunk (binary-
/// safe) streaming: no newlines, full byte range, deterministic content so the test can
/// assert chunk-stream equality against a generated reference. Caller
/// picks N to span multiple read() chunks (>16 KB recommended).
fn writeStdoutCyclingBytes(io: std.Io, count: usize) !void {
    var buf: [8192]u8 = undefined;
    var wbuf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &wbuf);
    var emitted: usize = 0;
    while (emitted < count) {
        const take = @min(buf.len, count - emitted);
        var i: usize = 0;
        while (i < take) : (i += 1) {
            buf[i] = @intCast((emitted + i) & 0xFF);
        }
        try w.interface.writeAll(buf[0..take]);
        emitted += take;
    }
    try w.interface.flush();
}

fn badArgs(io: std.Io, comptime msg: []const u8) noreturn {
    writeStderrLn(io, "test_helper: " ++ msg, .{}) catch {};
    std.process.exit(2);
}
