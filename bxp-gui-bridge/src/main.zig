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

/// Hard cap on combined stdout+stderr per call. Large enough to hold
/// a full dry-run NDJSON stream for most realistic datasets without
/// tripping the cap (one event per CSV row, ~200 B each → ~64 MB
/// covers ~300 K rows). bxp-fmt outputs (--docs ~30 KB, --config ~MB)
/// are well below this. The buffer is only allocated for the duration
/// of one bridge_run call and freed when the response is written, so
/// the steady-state RAM cost is zero.
const max_output_bytes: usize = 64 * 1024 * 1024;

/// Request shape: which executable to run with which arguments.
/// Caller (Dart) is responsible for resolving the absolute path to
/// bxp-fmt.exe / bxp-cli.exe; we don't probe PATH.
///
/// `cwd` is optional — when non-null the child runs with that working
/// directory. Used by the streaming dry-run path so relative
/// `data_dir` entries in the user's config resolve against the config
/// file's directory instead of bxp-gui's own CWD (Program Files).
const Request = struct {
    exe: []const u8,
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
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
    if (req.cwd) |cwd| {
        if (cwd.len > 0) child.cwd = cwd;
    }
    // Suppress the briefly-visible cmd.exe window that Windows pops up
    // when a GUI parent (bxp-gui.exe) spawns a console-subsystem child
    // (bxp-fmt.exe). On non-Windows the field is a no-op. Maps to the
    // CREATE_NO_WINDOW flag in CreateProcessW.
    child.create_no_window = true;

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

// ── Streaming variant ────────────────────────────────────────────────────
//
// `bridge_run_streaming` is a non-blocking sibling of `bridge_run`: it spawns
// the child + reader threads, returns immediately, and reports stdout / stderr
// / exit progressively via Dart-side callbacks. The motivation is the GUI's
// `--trace` dry-run path — with the batch entrypoint, every NDJSON event
// arrived only after the child exited, so file-list + per-row counters never
// updated mid-run. With this entrypoint, batches of 1000 stdout lines stream
// up in real time (plus a final flush at EOF for the trailing partial batch).
//
// Memory ownership across the FFI boundary: each batch / chunk is heap-
// allocated on the bridge side via `c_allocator` and handed to Dart as a raw
// pointer + length. Dart MUST call `bridge_free(ptr, len)` once it's copied
// the bytes — same C runtime malloc/free on both sides keeps the contract
// simple. The on_exit callback fires after both reader threads have flushed
// their pipes, so no callback ever fires after on_exit.

/// Per-stream batch callback. Invoked from a bridge-owned thread; the data
/// pointer becomes Dart's responsibility (call bridge_free).
const StreamCallback = ?*const fn (data: [*]const u8, len: u32) callconv(.c) void;

/// Final exit notification. Fires once, after all stream callbacks have
/// drained. Releases the bridge's hold on the streaming context — Dart can
/// safely close NativeCallables in the same handler.
const ExitCallback = ?*const fn (exit_code: i32) callconv(.c) void;

/// How many lines of stdout to buffer in the bridge before flushing a batch
/// to Dart. Picked as a compromise: low enough that the user sees mid-run
/// progress, high enough that a multi-thousand-line trace doesn't flood the
/// Dart event loop with one message per line.
const stdout_batch_lines: usize = 1000;

/// State shared between the bridge_run_streaming spawner and the three
/// long-lived helper threads (stdout reader, stderr reader, wait thread).
/// All allocations live in `arena` for a single deinit at teardown; the
/// Child + thread handles need explicit cleanup as they own OS resources.
const StreamingCtx = struct {
    arena: std.heap.ArenaAllocator,
    child: std.process.Child,
    on_stdout_batch: StreamCallback,
    on_stderr_chunk: StreamCallback,
    on_exit: ExitCallback,
    stdout_thread: std.Thread,
    stderr_thread: std.Thread,
};

/// Stdout reader: drain pipe in 8 KB chunks, accumulate, emit a batch to
/// Dart every `stdout_batch_lines` newlines. On EOF, flush any leftover
/// (which includes a possibly-unterminated final line).
fn streamingStdoutLoop(ctx: *StreamingCtx) void {
    const a = std.heap.c_allocator;
    var stdout = ctx.child.stdout orelse return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var pending_newlines: usize = 0;

    var read_buf: [8192]u8 = undefined;
    while (true) {
        const n = stdout.read(&read_buf) catch break;
        if (n == 0) break;
        const chunk = read_buf[0..n];
        buf.appendSlice(a, chunk) catch return;
        for (chunk) |c| {
            if (c == '\n') pending_newlines += 1;
        }
        // Emit as many full batches as we can. Each iteration peels off
        // `stdout_batch_lines` newline-terminated lines from the front
        // of `buf` and ships a heap copy to Dart.
        while (pending_newlines >= stdout_batch_lines) {
            var nl_seen: usize = 0;
            var pos: usize = 0;
            while (pos < buf.items.len and nl_seen < stdout_batch_lines) : (pos += 1) {
                if (buf.items[pos] == '\n') nl_seen += 1;
            }
            const batch_copy = a.dupe(u8, buf.items[0..pos]) catch return;
            if (ctx.on_stdout_batch) |cb| cb(batch_copy.ptr, @intCast(batch_copy.len));
            const remaining = buf.items[pos..];
            std.mem.copyForwards(u8, buf.items[0..remaining.len], remaining);
            buf.shrinkRetainingCapacity(remaining.len);
            pending_newlines -= stdout_batch_lines;
        }
    }
    // EOF flush — final batch may be < stdout_batch_lines or have a partial
    // unterminated line at the tail. Dart's LineSplitter handles both.
    if (buf.items.len > 0) {
        const tail_copy = a.dupe(u8, buf.items) catch return;
        if (ctx.on_stdout_batch) |cb| cb(tail_copy.ptr, @intCast(tail_copy.len));
    }
}

/// Stderr reader: pass through chunks as-is. bxp-cli's stderr is low-volume
/// (occasional warnings, no per-row stream), so chunk-level callbacks won't
/// flood the event loop the way a per-line stdout would.
fn streamingStderrLoop(ctx: *StreamingCtx) void {
    const a = std.heap.c_allocator;
    var stderr = ctx.child.stderr orelse return;

    var read_buf: [8192]u8 = undefined;
    while (true) {
        const n = stderr.read(&read_buf) catch break;
        if (n == 0) break;
        const chunk_copy = a.dupe(u8, read_buf[0..n]) catch return;
        if (ctx.on_stderr_chunk) |cb| cb(chunk_copy.ptr, @intCast(chunk_copy.len));
    }
}

/// Wait thread: blocks on child.wait(), then joins both reader threads to
/// guarantee any in-flight callbacks have drained, calls on_exit, and frees
/// the streaming context. Must run detached because bridge_run_streaming
/// returns to Dart immediately after spawn.
fn streamingWaitLoop(ctx: *StreamingCtx) void {
    const term_or_err = ctx.child.wait();

    // Whether wait succeeded or not, reader threads will exit on pipe EOF
    // (the child's exit closed the write ends). Joining is the synchronisation
    // point that guarantees no callback fires after on_exit.
    ctx.stdout_thread.join();
    ctx.stderr_thread.join();

    const exit_code: i32 = if (term_or_err) |term|
        switch (term) {
            .Exited => |c| @intCast(c),
            .Signal => |s| -@as(i32, @intCast(s)),
            .Stopped, .Unknown => -1,
        }
    else |_| -1;

    // Snapshot the callback before tearing down the context — Dart's handler
    // may not access ctx, but defensive: we read everything we need first.
    const exit_cb = ctx.on_exit;
    ctx.arena.deinit();
    std.heap.c_allocator.destroy(ctx);

    if (exit_cb) |cb| cb(exit_code);
}

/// Spawn `exe` with `args` (and optional `cwd`) and stream output back to
/// Dart via callbacks. Returns 0 on a successful start, -1 on any pre-spawn
/// failure (bad request JSON, OOM, child spawn failure, thread spawn
/// failure). The on_exit callback is the canonical "stream is done" signal;
/// no other callback fires after it.
export fn bridge_run_streaming(
    request_json: [*:0]const u8,
    on_stdout_batch: StreamCallback,
    on_stderr_chunk: StreamCallback,
    on_exit: ExitCallback,
) i32 {
    const gpa = std.heap.c_allocator;

    const ctx = gpa.create(StreamingCtx) catch return -1;
    var ctx_ok = false;
    defer if (!ctx_ok) gpa.destroy(ctx);

    ctx.arena = std.heap.ArenaAllocator.init(gpa);
    var arena_ok = false;
    defer if (!arena_ok) ctx.arena.deinit();

    const a = ctx.arena.allocator();

    const req_bytes = std.mem.span(request_json);
    const req = std.json.parseFromSliceLeaky(Request, a, req_bytes, .{
        .ignore_unknown_fields = true,
    }) catch return -1;
    if (req.exe.len == 0) return -1;

    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(a, req.exe) catch return -1;
    for (req.args) |arg| {
        argv.append(a, arg) catch return -1;
    }

    ctx.child = std.process.Child.init(argv.items, a);
    ctx.child.stdout_behavior = .Pipe;
    ctx.child.stderr_behavior = .Pipe;
    ctx.child.stdin_behavior = .Close;
    if (req.cwd) |cwd_str| {
        if (cwd_str.len > 0) ctx.child.cwd = cwd_str;
    }
    ctx.child.create_no_window = true;

    ctx.on_stdout_batch = on_stdout_batch;
    ctx.on_stderr_chunk = on_stderr_chunk;
    ctx.on_exit = on_exit;

    ctx.child.spawn() catch return -1;
    var child_ok = false;
    defer if (!child_ok) {
        _ = ctx.child.kill() catch {};
    };

    ctx.stdout_thread = std.Thread.spawn(.{}, streamingStdoutLoop, .{ctx}) catch return -1;
    var stdout_ok = false;
    defer if (!stdout_ok) ctx.stdout_thread.join();

    ctx.stderr_thread = std.Thread.spawn(.{}, streamingStderrLoop, .{ctx}) catch return -1;
    var stderr_ok = false;
    defer if (!stderr_ok) ctx.stderr_thread.join();

    var wait_thread = std.Thread.spawn(.{}, streamingWaitLoop, .{ctx}) catch return -1;
    wait_thread.detach();

    // All resources handed off to threads; cancel rollback defers.
    ctx_ok = true;
    arena_ok = true;
    child_ok = true;
    stdout_ok = true;
    stderr_ok = true;

    return 0;
}

/// Release a buffer previously handed to Dart by a streaming callback.
/// Both endpoints use the C runtime allocator (Zig's c_allocator wraps
/// malloc/free, Dart's package:ffi `malloc` wraps the same), so freeing
/// here is symmetric — but we expose this entry point anyway to keep the
/// contract obvious and survive a future allocator switch on the bridge
/// side without breaking Dart consumers.
export fn bridge_free(ptr: [*]u8, len: u32) void {
    std.heap.c_allocator.free(ptr[0..len]);
}
