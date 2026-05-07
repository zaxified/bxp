//! bxp-gui-bridge — Dart FFI shim that proxies bxp-fmt / bxp-cli calls.
//!
//! Why this exists: Dart's Process.start on Windows hits a deterministic
//! ~8 KB cutoff when reading subprocess stdout — bxp-fmt's --docs (~30 KB)
//! never makes it back through the pipe and the GUI startup fails with
//! "error: WriteFailed". The root cause is in the dart:io C++ pipe layer
//! (see dart-lang/sdk#1727 + #51273, both still open). Three Dart-side
//! approaches (direct Process.start, runInShell, Process.run) all hit the
//! same 8150 B cutoff because they share that one C++ pipe path.
//!
//! This bridge is a runtime-loaded shared library (DynamicLibrary.open
//! from dart:ffi). It reads pipes from native code, so the drain happens
//! synchronously without depending on the Dart event loop being ready —
//! no spawn-vs-attach race, no Flutter UI competition. Single exported
//! function `bridge_run` takes a JSON request, spawns the requested
//! child, captures stdout/stderr/exit, and writes a JSON response into
//! a caller-provided buffer.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// Hard cap on combined stdout+stderr per call. ~30 KB --docs is the
/// largest realistic payload today; 4 MB leaves headroom for big
/// `--config` annotations or future commands without giving runaway
/// children unbounded RAM.
const max_output_bytes: usize = 4 * 1024 * 1024;

/// Request shape: which executable to run with which arguments.
/// Caller (Dart) is responsible for resolving the absolute path to
/// bxp-fmt.exe / bxp-cli.exe; we don't probe PATH.
const Request = struct {
    exe: []const u8,
    args: []const []const u8 = &.{},
};

/// Response shape mirrors dart:io ProcessResult conceptually:
/// exit code + captured stdout + stderr. `err` carries a bridge-level
/// failure (spawn failed, output too large, …) so the Dart side can
/// distinguish "child exited nonzero" from "we never got to run it".
const Response = struct {
    exit_code: i32,
    stdout: []const u8,
    stderr: []const u8,
    err: ?[]const u8 = null,
};

/// Probe entry point — Dart can call this on load to confirm the DLL
/// is the right one (version match) before issuing real requests.
const version_z: [:0]const u8 = build_options.version ++ "";
export fn bridge_version() [*:0]const u8 {
    return version_z.ptr;
}

/// Run `exe` with `args` and capture its output. Caller provides a
/// pre-allocated response buffer; the bridge writes a JSON document
/// `{"exit_code":N,"stdout":"...","stderr":"...","err":null}` into it
/// and returns the byte length on success. Returns -1 if the buffer is
/// too small (caller can retry with a larger one) or if a bridge-level
/// failure (e.g. malformed request) prevented spawning the child.
///
/// Memory: all internal allocations go through std.heap.c_allocator and
/// are released before returning. The response_buf is owned by the
/// caller — Dart side typically allocates from `malloc` via dart:ffi
/// and frees it after parsing the JSON.
export fn bridge_run(
    request_json: [*:0]const u8,
    response_buf: [*]u8,
    response_buf_size: i32,
) i32 {
    if (response_buf_size <= 0) return -1;
    const buf_size: usize = @intCast(response_buf_size);
    const out_buf = response_buf[0..buf_size];

    const gpa = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const req_bytes = std.mem.span(request_json);

    // Parse the request. Anything unexpected -> bridge-level error
    // response so the Dart side has actionable diagnostics.
    const req = std.json.parseFromSliceLeaky(Request, a, req_bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        return writeErr(out_buf, "request parse failed: {s}", .{@errorName(err)});
    };

    if (req.exe.len == 0) {
        return writeErr(out_buf, "request.exe is empty", .{});
    }

    // Build argv: [exe, ...args]. std.process.Child takes a slice of
    // []const u8 where index 0 is the executable path.
    var argv = std.ArrayList([]const u8).empty;
    argv.append(a, req.exe) catch return writeErr(out_buf, "OOM building argv", .{});
    for (req.args) |arg| {
        argv.append(a, arg) catch return writeErr(out_buf, "OOM building argv", .{});
    }

    var child = std.process.Child.init(argv.items, a);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.stdin_behavior = .Close;

    child.spawn() catch |err| {
        return writeErr(out_buf, "spawn failed: {s}", .{@errorName(err)});
    };

    // collectOutput drains both pipes concurrently from native code,
    // which is the whole point of this bridge — Dart's own Process API
    // chokes here on Windows because the drain hand-off goes through
    // its event loop. Zig's collectOutput uses platform-appropriate
    // primitives (poll on POSIX, threaded reads on Windows) so the
    // child can flush ~30 KB without tripping its own WriteFile error.
    var stdout_buf = std.ArrayList(u8).empty;
    var stderr_buf = std.ArrayList(u8).empty;
    defer stdout_buf.deinit(a);
    defer stderr_buf.deinit(a);

    child.collectOutput(a, &stdout_buf, &stderr_buf, max_output_bytes) catch |err| {
        _ = child.kill() catch {};
        return writeErr(out_buf, "collectOutput failed: {s}", .{@errorName(err)});
    };

    const term = child.wait() catch |err| {
        return writeErr(out_buf, "wait failed: {s}", .{@errorName(err)});
    };

    const exit_code: i32 = switch (term) {
        .Exited => |c| @intCast(c),
        .Signal => |s| -@as(i32, @intCast(s)),
        .Stopped, .Unknown => -1,
    };

    const resp: Response = .{
        .exit_code = exit_code,
        .stdout = stdout_buf.items,
        .stderr = stderr_buf.items,
    };

    return writeResponse(out_buf, resp);
}

/// Stringify a successful Response into the caller's buffer.
/// Returns the byte length on success or -1 if the buffer is too small.
fn writeResponse(out_buf: []u8, resp: Response) i32 {
    var w: std.Io.Writer = .fixed(out_buf);
    std.json.Stringify.value(resp, .{}, &w) catch {
        // Fixed writer overflowed — caller must retry with a bigger
        // buffer. Don't try to write a partial error message into the
        // already-overflowed buffer.
        return -1;
    };
    return @intCast(w.buffered().len);
}

/// Build a bridge-level failure JSON: exit_code -1, empty stdout/stderr,
/// human-readable err string. Used when we couldn't even run the child.
fn writeErr(out_buf: []u8, comptime fmt: []const u8, args: anytype) i32 {
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "error formatting failure";
    const resp: Response = .{
        .exit_code = -1,
        .stdout = "",
        .stderr = "",
        .err = msg,
    };
    return writeResponse(out_buf, resp);
}
