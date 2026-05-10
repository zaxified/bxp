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
//!
//! Unknown subcommand → exit 2 + diagnostic on stderr so a typo in the
//! test surfaces loudly instead of as "unexplained exit 0".

const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2) {
        try writeStderrLn("test_helper: missing subcommand", .{});
        std.process.exit(2);
    }

    const cmd = argv[1];

    if (std.mem.eql(u8, cmd, "exit")) {
        if (argv.len != 3) return badArgs("exit needs <N>");
        const code = std.fmt.parseInt(u8, argv[2], 10) catch return badArgs("exit code must be u8");
        std.process.exit(code);
    }

    if (std.mem.eql(u8, cmd, "echo")) {
        try writeStdoutJoined(argv[2..]);
        return;
    }

    if (std.mem.eql(u8, cmd, "stderr")) {
        try writeStderrJoined(argv[2..]);
        return;
    }

    if (std.mem.eql(u8, cmd, "both")) {
        try writeStdoutLn("to-stdout", .{});
        try writeStderrLn("to-stderr", .{});
        return;
    }

    if (std.mem.eql(u8, cmd, "sleep")) {
        if (argv.len != 3) return badArgs("sleep needs <seconds>");
        const seconds = std.fmt.parseInt(u32, argv[2], 10) catch return badArgs("sleep seconds must be u32");
        std.Thread.sleep(@as(u64, seconds) * std.time.ns_per_s);
        return;
    }

    if (std.mem.eql(u8, cmd, "stdout-bytes")) {
        if (argv.len != 3) return badArgs("stdout-bytes needs <N>");
        const n = std.fmt.parseInt(usize, argv[2], 10) catch return badArgs("stdout-bytes count must be usize");
        try writeStdoutFill(n, 'a');
        return;
    }

    if (std.mem.eql(u8, cmd, "pwd")) {
        const cwd = try std.process.getCwdAlloc(a);
        try writeStdoutLn("{s}", .{cwd});
        return;
    }

    try writeStderrLn("test_helper: unknown subcommand '{s}'", .{cmd});
    std.process.exit(2);
}

// ── thin wrappers around stdout/stderr writers ─────────────────────────
// Zig 0.15 exposes std.fs.File.stdout() / .stderr() and a buffered writer
// pattern. Each helper function builds a small stack buffer, writes, and
// flushes — tiny outputs (< 8 KB) so a single 1 KB buffer is plenty for
// all subcommands except `stdout-bytes` (which has its own loop).

fn writeStdoutLn(comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt ++ "\n", args);
    try w.interface.flush();
}

fn writeStderrLn(comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    try w.interface.print(fmt ++ "\n", args);
    try w.interface.flush();
}

fn writeStdoutJoined(parts: []const []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    for (parts, 0..) |p, i| {
        if (i > 0) try w.interface.writeAll(" ");
        try w.interface.writeAll(p);
    }
    try w.interface.writeAll("\n");
    try w.interface.flush();
}

fn writeStderrJoined(parts: []const []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    for (parts, 0..) |p, i| {
        if (i > 0) try w.interface.writeAll(" ");
        try w.interface.writeAll(p);
    }
    try w.interface.writeAll("\n");
    try w.interface.flush();
}

fn writeStdoutFill(count: usize, byte: u8) !void {
    var buf: [8192]u8 = undefined;
    @memset(&buf, byte);
    var w = std.fs.File.stdout().writer(&.{});
    var remaining = count;
    while (remaining > 0) {
        const take = @min(remaining, buf.len);
        try w.interface.writeAll(buf[0..take]);
        remaining -= take;
    }
}

fn badArgs(comptime msg: []const u8) noreturn {
    writeStderrLn("test_helper: " ++ msg, .{}) catch {};
    std.process.exit(2);
}
