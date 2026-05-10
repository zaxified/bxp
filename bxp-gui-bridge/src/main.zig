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

/// Hard cap on captured bytes per stream (stdout, stderr) per call.
/// 64 MB per stream is enough for a full dry-run NDJSON dump on most
/// realistic datasets (one event per CSV row, ~200 B each → ~300 K rows).
/// When a child exceeds this, the bridge keeps the prefix and continues
/// draining without storing — the response carries `truncated: true` so
/// the Dart side can surface "output was clipped" instead of failing
/// the whole call.
const max_output_bytes: usize = 64 * 1024 * 1024;

/// Request shape: which executable to run with which arguments.
/// Caller (Dart) is responsible for resolving the absolute path to
/// bxp-fmt.exe / bxp-cli.exe; we don't probe PATH.
///
/// `cwd` is optional — when non-null the child runs with that working
/// directory. Used by the streaming dry-run path so relative
/// `data_dir` entries in the user's config resolve against the config
/// file's directory instead of bxp-gui's own CWD (Program Files).
///
/// `stdout_batch_lines` is streaming-only: tune how many newline-terminated
/// stdout lines accumulate before the bridge ships a batch to Dart. Lower
/// means smoother UI (smaller per-batch decode/dispatch cost) but more FFI
/// hops; higher means fewer hops but bigger latency spikes per batch.
/// Defaults to `default_stdout_batch_lines` when null/omitted.
const Request = struct {
    exe: []const u8,
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    stdout_batch_lines: ?usize = null,
};

/// Response shape mirrors dart:io ProcessResult conceptually:
/// exit code + captured stdout + stderr. `err` carries a bridge-level
/// failure (spawn failed, malformed request, …) so the Dart side can
/// distinguish "child exited nonzero" from "we never got to run it".
/// `truncated` is set when either stdout or stderr exceeded the
/// per-stream cap (`max_output_bytes`); the captured prefix is still
/// returned so the caller can render whatever fits.
const Response = struct {
    exit_code: i32,
    stdout: []const u8,
    stderr: []const u8,
    err: ?[]const u8 = null,
    truncated: bool = false,
};

/// Probe entry point — Dart can call this on load to confirm the DLL
/// is the right one (version match) before issuing real requests.
const version_z: [:0]const u8 = build_options.version ++ "";
export fn bridge_version() [*:0]const u8 {
    return version_z.ptr;
}

/// Run `exe` with `args` and capture its output. Caller provides a
/// pre-allocated response buffer; the bridge writes a JSON document
/// `{"exit_code":N,"stdout":"...","stderr":"...","err":null,"truncated":false}`
/// into it and returns the byte length on success. Returns -1 if the
/// buffer is too small (caller can retry with a larger one) or if a
/// bridge-level failure (e.g. malformed request) prevented spawning the
/// child.
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

    // Manual two-thread drain instead of std.process.Child.collectOutput:
    // the stdlib version returns error.StdoutStreamTooLong / StderrStreamTooLong
    // on overflow and discards everything captured so far, leaving the
    // caller with nothing useful. Our drainer keeps the prefix up to
    // `max_output_bytes` and continues reading past the cap so the child
    // can flush and exit cleanly; truncation is signalled via the
    // `truncated` response field.
    var stdout_buf = std.ArrayList(u8).empty;
    var stderr_buf = std.ArrayList(u8).empty;
    defer stdout_buf.deinit(a);
    defer stderr_buf.deinit(a);

    var truncated_flag = std.atomic.Value(bool).init(false);
    collectOutputCapped(&child, a, &stdout_buf, &stderr_buf, max_output_bytes, &truncated_flag) catch |err| {
        _ = child.kill() catch {};
        return writeErr(out_buf, "collect failed: {s}", .{@errorName(err)});
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
        .truncated = truncated_flag.load(.acquire),
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
/// 1 KB is enough for a "spawn failed: FileNotFound" + a Windows long path
/// — the previous 256 B cap truncated those into useless half-strings.
fn writeErr(out_buf: []u8, comptime fmt: []const u8, args: anytype) i32 {
    var msg_buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "error formatting failure";
    const resp: Response = .{
        .exit_code = -1,
        .stdout = "",
        .stderr = "",
        .err = msg,
    };
    return writeResponse(out_buf, resp);
}

// ── Capped two-thread drain ─────────────────────────────────────────────
//
// Drains a child's stdout + stderr concurrently from native threads.
// Each stream stores up to `cap` bytes; once a stream reaches the cap,
// further reads are discarded but the loop keeps consuming so the child
// doesn't block forever on its own WriteFile. `truncated` is set whenever
// either stream had to discard at least one byte.

const DrainerArgs = struct {
    file: std.fs.File,
    buf: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    cap: usize,
    truncated: *std.atomic.Value(bool),
};

fn drainerLoop(args: DrainerArgs) void {
    var read_buf: [8192]u8 = undefined;
    while (true) {
        const n = args.file.read(&read_buf) catch return;
        if (n == 0) return;
        const have = args.buf.items.len;
        if (have >= args.cap) {
            args.truncated.store(true, .release);
            continue;
        }
        const space = args.cap - have;
        const take = @min(n, space);
        args.buf.appendSlice(args.alloc, read_buf[0..take]) catch return;
        if (take < n) args.truncated.store(true, .release);
    }
}

fn collectOutputCapped(
    child: *std.process.Child,
    alloc: std.mem.Allocator,
    stdout_buf: *std.ArrayList(u8),
    stderr_buf: *std.ArrayList(u8),
    cap: usize,
    truncated: *std.atomic.Value(bool),
) !void {
    const stdout = child.stdout orelse return error.NoStdoutPipe;
    const stderr = child.stderr orelse return error.NoStderrPipe;

    const stdout_thread = try std.Thread.spawn(.{}, drainerLoop, .{DrainerArgs{
        .file = stdout,
        .buf = stdout_buf,
        .alloc = alloc,
        .cap = cap,
        .truncated = truncated,
    }});
    const stderr_thread = try std.Thread.spawn(.{}, drainerLoop, .{DrainerArgs{
        .file = stderr,
        .buf = stderr_buf,
        .alloc = alloc,
        .cap = cap,
        .truncated = truncated,
    }});
    stdout_thread.join();
    stderr_thread.join();
}

// ── Streaming variant ────────────────────────────────────────────────────
//
// `bridge_run_streaming` is a non-blocking sibling of `bridge_run`: it spawns
// the child + reader threads, returns immediately, and reports stdout / stderr
// / exit progressively via Dart-side callbacks. The motivation is the GUI's
// `--trace` dry-run path — with the batch entrypoint, every NDJSON event
// arrived only after the child exited, so file-list + per-row counters never
// updated mid-run. With this entrypoint, batches of `stdout_batch_lines`
// stream up in real time (plus a final flush at EOF for the trailing
// partial batch).
//
// Memory ownership across the FFI boundary: each batch / chunk is heap-
// allocated on the bridge side via `c_allocator` and handed to Dart as a raw
// pointer + length. Dart MUST call `bridge_free(ptr, len)` once it's copied
// the bytes — same C runtime malloc/free on both sides keeps the contract
// simple. The on_exit callback fires after both reader threads have flushed
// their pipes, so no callback ever fires after on_exit.
//
// Cancellation: `bridge_run_streaming` returns a positive opaque handle on
// success (negative on pre-spawn failure). Dart can call `bridge_cancel(h)`
// to deliver SIGTERM / TerminateProcess to the child mid-stream; the reader
// threads then drain the remaining buffered output, the wait thread reaps
// the child, and on_exit fires with the signal exit code. Handles are
// invalidated when on_exit returns — calling `bridge_cancel` after that
// is a safe no-op (returns -1).

/// Per-stream batch callback. Invoked from a bridge-owned thread; the data
/// pointer becomes Dart's responsibility (call bridge_free).
const StreamCallback = ?*const fn (data: [*]const u8, len: u32) callconv(.c) void;

/// Final exit notification. Fires once, after all stream callbacks have
/// drained. Releases the bridge's hold on the streaming context — Dart can
/// safely close NativeCallables in the same handler.
const ExitCallback = ?*const fn (exit_code: i32) callconv(.c) void;

/// Default batch size when the caller doesn't pass `stdout_batch_lines` in
/// the request. Empirically tuned: 100 lines keeps the status-bar spinner
/// smooth on multi-thousand-line traces (the previous value of 1000 produced
/// perceptible freezes). Callers with tighter latency requirements can pass
/// a smaller value via the request JSON.
const default_stdout_batch_lines: usize = 100;

/// State shared between the bridge_run_streaming spawner and the three
/// long-lived helper threads (stdout reader, stderr reader, wait thread).
/// All allocations live in `arena` for a single deinit at teardown; the
/// Child + thread handles need explicit cleanup as they own OS resources.
///
/// `shutting_down` is the rollback signal: when the spawner can't finish
/// arming all three threads (extremely rare — thread alloc OOM), it sets
/// this flag before the rollback defers kill the child. Reader threads
/// check the flag before invoking the Dart callback; if set, they free
/// the per-batch buffer themselves instead of handing it across the FFI,
/// avoiding a leak from messages that would otherwise sit in the Dart
/// port queue with no handler to claim them after Dart closes the
/// NativeCallable.listener (dart-lang/sdk: "Resources passed to the
/// callback must be valid until the call completes" — and a closed
/// listener never completes the call).
const StreamingCtx = struct {
    arena: std.heap.ArenaAllocator,
    child: std.process.Child,
    on_stdout_batch: StreamCallback,
    on_stderr_chunk: StreamCallback,
    on_exit: ExitCallback,
    stdout_thread: std.Thread,
    stderr_thread: std.Thread,
    handle: i64 = 0,
    shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stdout_batch_lines: usize = default_stdout_batch_lines,
};

// ── Active-stream registry (cancellation lookup) ────────────────────────
//
// `bridge_cancel(handle)` needs to map a Dart-side handle back to the live
// `*StreamingCtx` so it can deliver a kill signal to the child. We use an
// opaque positive-int handle (monotonic counter) instead of casting the
// pointer directly so a stale handle from a freed stream can't accidentally
// match a fresh ctx that happened to land at the same address.
//
// Lifetime: an entry is added by `bridge_run_streaming` once spawn + threads
// are armed, and removed by `streamingWaitLoop` immediately before the ctx
// is destroyed. The mutex serialises lookups against the remove, so cancel
// is always safe to call concurrently with natural stream completion.

var streams_mutex: std.Thread.Mutex = .{};
var streams_table: std.AutoHashMapUnmanaged(i64, *StreamingCtx) = .empty;
var next_stream_handle: i64 = 1;

fn registerStream(ctx: *StreamingCtx) !i64 {
    streams_mutex.lock();
    defer streams_mutex.unlock();
    const h = next_stream_handle;
    next_stream_handle += 1;
    try streams_table.put(std.heap.c_allocator, h, ctx);
    ctx.handle = h;
    return h;
}

fn unregisterStream(handle: i64) void {
    streams_mutex.lock();
    defer streams_mutex.unlock();
    _ = streams_table.remove(handle);
}

/// Stdout reader: drain pipe in 8 KB chunks, accumulate, emit a batch to
/// Dart every `stdout_batch_lines` newlines. On EOF, flush any leftover
/// (which includes a possibly-unterminated final line). Closes the pipe
/// handle on exit so the child's write end isn't kept open by us after
/// the stream is drained.
fn streamingStdoutLoop(ctx: *StreamingCtx) void {
    const a = std.heap.c_allocator;
    var stdout = ctx.child.stdout orelse return;
    ctx.child.stdout = null;
    defer stdout.close();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var pending_newlines: usize = 0;
    const batch_lines = ctx.stdout_batch_lines;

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
        // `batch_lines` newline-terminated lines from the front of `buf`
        // and ships a heap copy to Dart.
        while (pending_newlines >= batch_lines) {
            var nl_seen: usize = 0;
            var pos: usize = 0;
            while (pos < buf.items.len and nl_seen < batch_lines) : (pos += 1) {
                if (buf.items[pos] == '\n') nl_seen += 1;
            }
            const batch_copy = a.dupe(u8, buf.items[0..pos]) catch return;
            dispatchOrFree(ctx, ctx.on_stdout_batch, batch_copy, a);
            const remaining = buf.items[pos..];
            std.mem.copyForwards(u8, buf.items[0..remaining.len], remaining);
            buf.shrinkRetainingCapacity(remaining.len);
            pending_newlines -= batch_lines;
        }
    }
    // EOF flush — final batch may be < stdout_batch_lines or have a partial
    // unterminated line at the tail. Dart's LineSplitter handles both.
    if (buf.items.len > 0) {
        const tail_copy = a.dupe(u8, buf.items) catch return;
        dispatchOrFree(ctx, ctx.on_stdout_batch, tail_copy, a);
    }
}

/// Hand a freshly-allocated batch buffer to Dart via `cb`, OR — if the
/// stream is shutting down (rollback path) or no callback is registered —
/// free the buffer locally. Without this branch, a heap-allocated batch
/// can sit in Dart's port queue forever after the listener closes,
/// because the trampoline that would have invoked bridge_free is gone.
fn dispatchOrFree(
    ctx: *StreamingCtx,
    cb_opt: StreamCallback,
    buffer: []u8,
    a: std.mem.Allocator,
) void {
    if (ctx.shutting_down.load(.acquire)) {
        a.free(buffer);
        return;
    }
    if (cb_opt) |cb| {
        cb(buffer.ptr, @intCast(buffer.len));
    } else {
        a.free(buffer);
    }
}

/// Stderr reader: pass through chunks as-is. bxp-cli's stderr is low-volume
/// (occasional warnings, no per-row stream), so chunk-level callbacks won't
/// flood the event loop the way a per-line stdout would. Closes the pipe
/// handle on exit (same rationale as stdout reader).
fn streamingStderrLoop(ctx: *StreamingCtx) void {
    const a = std.heap.c_allocator;
    var stderr = ctx.child.stderr orelse return;
    ctx.child.stderr = null;
    defer stderr.close();

    var read_buf: [8192]u8 = undefined;
    while (true) {
        const n = stderr.read(&read_buf) catch break;
        if (n == 0) break;
        const chunk_copy = a.dupe(u8, read_buf[0..n]) catch return;
        dispatchOrFree(ctx, ctx.on_stderr_chunk, chunk_copy, a);
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
    else |wait_err| blk: {
        // OS-level wait failure (extremely rare — waitpid ECHILD-after-reap
        // race, or Windows handle invalidation). Without a diagnostic the
        // Dart side sees only exit_code=-1 and can't distinguish this from
        // a Stopped/Unknown signal. Emit the error name as a final stderr
        // chunk before on_exit fires so the bug reporter has something to
        // paste. Reader threads have already joined, so this is the last
        // dispatch through ctx.on_stderr_chunk.
        const a = std.heap.c_allocator;
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            "bridge: child.wait failed: {s}\n",
            .{@errorName(wait_err)},
        ) catch "bridge: child.wait failed\n";
        if (a.dupe(u8, msg)) |heap_msg|
            dispatchOrFree(ctx, ctx.on_stderr_chunk, heap_msg, a)
        else |_| {}
        break :blk -1;
    };

    // Snapshot the callback before tearing down the context — Dart's handler
    // may not access ctx, but defensive: we read everything we need first.
    const exit_cb = ctx.on_exit;
    const handle = ctx.handle;

    // Remove from the active-streams table BEFORE freeing ctx. Any in-flight
    // bridge_cancel(handle) call holding the mutex will either see the entry
    // (kill is harmless if child already exited) or not see it (no-op return);
    // either way the lookup never returns a freed pointer.
    unregisterStream(handle);
    ctx.arena.deinit();
    std.heap.c_allocator.destroy(ctx);

    if (exit_cb) |cb| cb(exit_code);
}

/// Spawn `exe` with `args` (and optional `cwd`) and stream output back to
/// Dart via callbacks. Returns a positive opaque handle on success (use
/// with `bridge_cancel` to abort); -1 on any pre-spawn failure (bad
/// request JSON, OOM, child spawn failure, thread spawn failure). The
/// on_exit callback is the canonical "stream is done" signal; no other
/// callback fires after it.
export fn bridge_run_streaming(
    request_json: [*:0]const u8,
    on_stdout_batch: StreamCallback,
    on_stderr_chunk: StreamCallback,
    on_exit: ExitCallback,
) i64 {
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
    ctx.handle = 0;
    ctx.shutting_down = std.atomic.Value(bool).init(false);
    ctx.stdout_batch_lines = if (req.stdout_batch_lines) |n|
        @max(n, 1)
    else
        default_stdout_batch_lines;

    // Rollback signal: any failure between here and the final `started_ok = true`
    // raises this flag. Reader threads check it before invoking a Dart callback
    // — if set, they free the per-batch buffer locally instead of handing it
    // across the FFI, where it would orphan in Dart's port queue after the
    // listener closes. Declared BEFORE child.spawn so it runs LAST on rollback
    // (defers are LIFO), which means subsequent rollback defers (kill child,
    // join readers) all execute with the flag already raised.
    var started_ok = false;
    defer if (!started_ok) ctx.shutting_down.store(true, .release);

    ctx.child.spawn() catch return -1;
    var child_ok = false;
    defer if (!child_ok) {
        // kill() in std.process.Child includes wait() on POSIX/Windows, so
        // the child is fully reaped by the time this defer returns. Pipe
        // handles inside ctx.child are still open here — they get freed
        // when arena_ok=false's deinit runs because ctx.child was init'd
        // from the arena allocator. (No-op if reader threads already took
        // ownership and nulled the field, which can only happen on the
        // success path.)
        _ = ctx.child.kill() catch {};
    };

    ctx.stdout_thread = std.Thread.spawn(.{}, streamingStdoutLoop, .{ctx}) catch return -1;
    var stdout_ok = false;
    defer if (!stdout_ok) ctx.stdout_thread.join();

    ctx.stderr_thread = std.Thread.spawn(.{}, streamingStderrLoop, .{ctx}) catch return -1;
    var stderr_ok = false;
    defer if (!stderr_ok) ctx.stderr_thread.join();

    // Register before launching the wait thread so cancel sees a complete
    // ctx the moment we return to Dart. If registerStream fails (OOM in the
    // hashmap), we fall back to the rollback defers — kill the child, join
    // the readers — and return -1.
    const handle = registerStream(ctx) catch return -1;
    var registered_ok = false;
    defer if (!registered_ok) unregisterStream(handle);

    var wait_thread = std.Thread.spawn(.{}, streamingWaitLoop, .{ctx}) catch return -1;
    wait_thread.detach();

    // All resources handed off to threads; cancel rollback defers.
    ctx_ok = true;
    arena_ok = true;
    child_ok = true;
    stdout_ok = true;
    stderr_ok = true;
    registered_ok = true;
    started_ok = true;

    return handle;
}

/// Signal cancellation to a running stream. Sends SIGTERM (POSIX) /
/// TerminateProcess (Windows) to the child; the reader threads then drain
/// any buffered output, the wait thread reaps the exit, and on_exit fires
/// with the signal exit code. Returns 0 if the signal was sent, -1 if
/// the handle is unknown (already exited, or never valid). Idempotent:
/// calling cancel after the stream has exited is a safe no-op.
export fn bridge_cancel(handle: i64) i32 {
    streams_mutex.lock();
    defer streams_mutex.unlock();
    const ctx = streams_table.get(handle) orelse return -1;
    sendKillSignal(&ctx.child);
    return 0;
}

/// Deliver a "please exit now" signal without waiting on the child.
/// std.process.Child.kill() on POSIX combines kill + waitpid, which
/// would race with streamingWaitLoop's own waitpid call → ECHILD. We
/// only signal here and let the wait thread reap.
fn sendKillSignal(child: *std.process.Child) void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.kernel32.TerminateProcess(child.id, 1);
    } else {
        std.posix.kill(child.id, std.posix.SIG.TERM) catch {};
    }
}

/// Release a buffer previously handed to Dart by a streaming callback.
/// Both endpoints use the C runtime allocator (Zig's c_allocator wraps
/// malloc/free, Dart's package:ffi `malloc` wraps the same), so freeing
/// here is symmetric — but we expose this entry point anyway to keep the
/// contract obvious and survive a future allocator switch on the bridge
/// side without breaking Dart consumers.
///
/// `len == 0` is treated as a no-op: a zero-length buffer pair carries no
/// real allocation (Zig's allocator returns a zero-size slice for it
/// anyway), and accepting it gracefully prevents a Dart-side bug — e.g.
/// re-freeing a slot that was already cleared to (ptr=null, len=0) — from
/// dereferencing a freed pointer.
export fn bridge_free(ptr: [*]u8, len: u32) void {
    if (len == 0) return;
    std.heap.c_allocator.free(ptr[0..len]);
}

// ── Tests ───────────────────────────────────────────────────────────────
//
// Exercise the exported FFI surface end-to-end. Tests spawn a small helper
// binary (`bridge-test-helper`, built alongside this library by build.zig)
// that emulates whatever child behaviour the test needs — exit codes,
// stdout/stderr writes, sleeps for cancellation, byte-fills for truncation.
// Using our own helper instead of OS binaries (`/bin/true`, `/bin/sleep`)
// keeps the suite identical on Linux / macOS / Windows; the path comes in
// via `test_options.test_helper_path`.

const testing = std.testing;
const test_options = @import("test_options");
const helper_path: []const u8 = test_options.test_helper_path;

/// Build a JSON request for the bridge that invokes the test helper with
/// `args`. Returned slice is null-terminated (the bridge expects a C
/// string) and allocated on the test allocator; caller frees with
/// `testing.allocator.free(req)`.
fn buildHelperRequestZ(args: []const []const u8) ![:0]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"exe\":");
    try std.json.Stringify.value(helper_path, .{}, &aw.writer);
    try aw.writer.writeAll(",\"args\":[");
    for (args, 0..) |arg, i| {
        if (i > 0) try aw.writer.writeAll(",");
        try std.json.Stringify.value(arg, .{}, &aw.writer);
    }
    try aw.writer.writeAll("]}");
    return aw.toOwnedSliceSentinel(0);
}

/// Variant of `buildHelperRequestZ` that adds a `cwd` field.
fn buildHelperRequestWithCwdZ(args: []const []const u8, cwd: []const u8) ![:0]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"exe\":");
    try std.json.Stringify.value(helper_path, .{}, &aw.writer);
    try aw.writer.writeAll(",\"args\":[");
    for (args, 0..) |arg, i| {
        if (i > 0) try aw.writer.writeAll(",");
        try std.json.Stringify.value(arg, .{}, &aw.writer);
    }
    try aw.writer.writeAll("],\"cwd\":");
    try std.json.Stringify.value(cwd, .{}, &aw.writer);
    try aw.writer.writeAll("}");
    return aw.toOwnedSliceSentinel(0);
}

test "writeResponse roundtrip basic" {
    var buf: [1024]u8 = undefined;
    const n = writeResponse(&buf, .{
        .exit_code = 42,
        .stdout = "hello",
        .stderr = "world",
    });
    try testing.expect(n > 0);

    const parsed = try std.json.parseFromSlice(
        Response,
        testing.allocator,
        buf[0..@intCast(n)],
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(i32, 42), parsed.value.exit_code);
    try testing.expectEqualStrings("hello", parsed.value.stdout);
    try testing.expectEqualStrings("world", parsed.value.stderr);
    try testing.expectEqual(@as(?[]const u8, null), parsed.value.err);
    try testing.expectEqual(false, parsed.value.truncated);
}

test "writeResponse overflow returns -1" {
    var buf: [4]u8 = undefined;
    const n = writeResponse(&buf, .{
        .exit_code = 0,
        .stdout = "abcdefghijklmnopqrstuvwxyz",
        .stderr = "",
    });
    try testing.expectEqual(@as(i32, -1), n);
}

test "writeErr produces parseable error response" {
    var buf: [1024]u8 = undefined;
    const n = writeErr(&buf, "test failure: {s}", .{"detail"});
    try testing.expect(n > 0);
    const parsed = try std.json.parseFromSlice(
        Response,
        testing.allocator,
        buf[0..@intCast(n)],
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(i32, -1), parsed.value.exit_code);
    try testing.expect(parsed.value.err != null);
    try testing.expect(std.mem.indexOf(u8, parsed.value.err.?, "test failure") != null);
}

test "bridge_run rejects empty exe" {
    var buf: [1024]u8 = undefined;
    const req: [*:0]const u8 = "{\"exe\":\"\"}";
    const n = bridge_run(req, &buf, @intCast(buf.len));
    try testing.expect(n > 0);
    const parsed = try std.json.parseFromSlice(
        Response,
        testing.allocator,
        buf[0..@intCast(n)],
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try testing.expect(parsed.value.err != null);
}

test "bridge_run rejects malformed JSON" {
    var buf: [1024]u8 = undefined;
    const req: [*:0]const u8 = "{not json";
    const n = bridge_run(req, &buf, @intCast(buf.len));
    try testing.expect(n > 0);
    const parsed = try std.json.parseFromSlice(
        Response,
        testing.allocator,
        buf[0..@intCast(n)],
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try testing.expect(parsed.value.err != null);
}

test "bridge_run reports spawn failure for missing executable" {
    var buf: [4096]u8 = undefined;
    const req: [*:0]const u8 = "{\"exe\":\"/this/path/does/not/exist/xyz\"}";
    const n = bridge_run(req, &buf, @intCast(buf.len));
    try testing.expect(n > 0);
    const parsed = try std.json.parseFromSlice(
        Response,
        testing.allocator,
        buf[0..@intCast(n)],
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try testing.expect(parsed.value.err != null);
}

test "bridge_run helper exit 0 produces clean response" {
    var buf: [4096]u8 = undefined;
    const req = try buildHelperRequestZ(&.{ "exit", "0" });
    defer testing.allocator.free(req);
    const n = bridge_run(req.ptr, &buf, @intCast(buf.len));
    try testing.expect(n > 0);
    const parsed = try std.json.parseFromSlice(
        Response,
        testing.allocator,
        buf[0..@intCast(n)],
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(i32, 0), parsed.value.exit_code);
    try testing.expectEqual(@as(?[]const u8, null), parsed.value.err);
}

test "bridge_run captures helper echo stdout" {
    var buf: [4096]u8 = undefined;
    const req = try buildHelperRequestZ(&.{ "echo", "hello", "world" });
    defer testing.allocator.free(req);
    const n = bridge_run(req.ptr, &buf, @intCast(buf.len));
    try testing.expect(n > 0);
    const parsed = try std.json.parseFromSlice(
        Response,
        testing.allocator,
        buf[0..@intCast(n)],
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(i32, 0), parsed.value.exit_code);
    try testing.expectEqualStrings("hello world\n", parsed.value.stdout);
    try testing.expectEqual(false, parsed.value.truncated);
}

test "bridge_run reports nonzero exit code from helper" {
    var buf: [4096]u8 = undefined;
    const req = try buildHelperRequestZ(&.{ "exit", "7" });
    defer testing.allocator.free(req);
    const n = bridge_run(req.ptr, &buf, @intCast(buf.len));
    try testing.expect(n > 0);
    const parsed = try std.json.parseFromSlice(
        Response,
        testing.allocator,
        buf[0..@intCast(n)],
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(i32, 7), parsed.value.exit_code);
}

test "bridge_run separates stdout and stderr" {
    var buf: [4096]u8 = undefined;
    const req = try buildHelperRequestZ(&.{"both"});
    defer testing.allocator.free(req);
    const n = bridge_run(req.ptr, &buf, @intCast(buf.len));
    try testing.expect(n > 0);
    const parsed = try std.json.parseFromSlice(
        Response,
        testing.allocator,
        buf[0..@intCast(n)],
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, parsed.value.stdout, "to-stdout") != null);
    try testing.expect(std.mem.indexOf(u8, parsed.value.stderr, "to-stderr") != null);
}

test "bridge_run honours cwd" {
    // Pick a directory we know exists: the CWD of the test process. The
    // helper's `pwd` subcommand prints whatever its own CWD is, so we
    // round-trip the test's own CWD through the bridge → should match.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&cwd_buf);

    var buf: [4096]u8 = undefined;
    const req = try buildHelperRequestWithCwdZ(&.{"pwd"}, cwd);
    defer testing.allocator.free(req);
    const n = bridge_run(req.ptr, &buf, @intCast(buf.len));
    try testing.expect(n > 0);
    const parsed = try std.json.parseFromSlice(
        Response,
        testing.allocator,
        buf[0..@intCast(n)],
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, parsed.value.stdout, cwd) != null);
}

test "bridge_run truncated flag set when stdout exceeds cap" {
    // Spawn the helper to fill 64 MB + a few bytes of stdout; the bridge's
    // 64 MB per-stream cap should clip to exactly 64 MB and report
    // truncated=true. Larger than `defaultBufSize` so this also exercises
    // the auto-retry path implicitly when called via Dart, but here we
    // pass a `largeBufSize`-equivalent (64 MB + headroom for the JSON
    // envelope) directly.
    const big_buf_size: usize = 70 * 1024 * 1024;
    const out_buf = try testing.allocator.alloc(u8, big_buf_size);
    defer testing.allocator.free(out_buf);

    const req = try buildHelperRequestZ(&.{ "stdout-bytes", "67108880" }); // 64 MB + 16 B
    defer testing.allocator.free(req);
    const n = bridge_run(req.ptr, out_buf.ptr, @intCast(big_buf_size));
    try testing.expect(n > 0);
    const parsed = try std.json.parseFromSlice(
        Response,
        testing.allocator,
        out_buf[0..@intCast(n)],
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 64 * 1024 * 1024), parsed.value.stdout.len);
    try testing.expectEqual(true, parsed.value.truncated);
}

test "collectOutputCapped truncates and keeps prefix at unit level" {
    // Same idea as the integration test above but at the unit level: cap=128
    // with a 4 KB child output → expect exactly 128 captured bytes and
    // truncated=true. Cheaper to run, exercises the drainer in isolation.
    const a = testing.allocator;
    const req = try buildHelperRequestZ(&.{ "stdout-bytes", "4096" });
    defer testing.allocator.free(req);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(a);
    try argv.append(a, helper_path);
    try argv.append(a, "stdout-bytes");
    try argv.append(a, "4096");
    var child = std.process.Child.init(argv.items, a);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.stdin_behavior = .Close;
    try child.spawn();

    var stdout_buf: std.ArrayList(u8) = .empty;
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(a);
    defer stderr_buf.deinit(a);
    var trunc = std.atomic.Value(bool).init(false);
    try collectOutputCapped(&child, a, &stdout_buf, &stderr_buf, 128, &trunc);
    _ = try child.wait();

    try testing.expectEqual(@as(usize, 128), stdout_buf.items.len);
    try testing.expectEqual(true, trunc.load(.acquire));
}

test "bridge_version returns build version string" {
    const v = bridge_version();
    const span = std.mem.span(v);
    try testing.expect(span.len > 0);
}

// ── Streaming test harness ─────────────────────────────────────────────
//
// Module-level state captured by the C-ABI test callbacks. Tests must call
// `stream_test.reset()` before each run and `stream_test.waitForExit()` to
// block until on_exit fires.

const stream_test = struct {
    var stdout_total: usize = 0;
    var stderr_total: usize = 0;
    var batch_count: usize = 0;
    var exit_called: bool = false;
    var exit_code: i32 = 0;
    var mutex: std.Thread.Mutex = .{};
    var cond: std.Thread.Condition = .{};

    fn reset() void {
        mutex.lock();
        defer mutex.unlock();
        stdout_total = 0;
        stderr_total = 0;
        batch_count = 0;
        exit_called = false;
        exit_code = 0;
    }

    fn waitForExit(timeout_ns: u64) bool {
        mutex.lock();
        defer mutex.unlock();
        const start = std.time.nanoTimestamp();
        while (!exit_called) {
            const elapsed: i128 = std.time.nanoTimestamp() - start;
            if (elapsed >= @as(i128, timeout_ns)) return false;
            const remaining: u64 = @intCast(@as(i128, timeout_ns) - elapsed);
            cond.timedWait(&mutex, remaining) catch return false;
        }
        return true;
    }
};

fn streamTestOnStdout(data: [*]const u8, len: u32) callconv(.c) void {
    stream_test.mutex.lock();
    stream_test.stdout_total += len;
    stream_test.batch_count += 1;
    stream_test.mutex.unlock();
    bridge_free(@constCast(data), len);
}

fn streamTestOnStderr(data: [*]const u8, len: u32) callconv(.c) void {
    stream_test.mutex.lock();
    stream_test.stderr_total += len;
    stream_test.mutex.unlock();
    bridge_free(@constCast(data), len);
}

fn streamTestOnExit(code: i32) callconv(.c) void {
    stream_test.mutex.lock();
    stream_test.exit_called = true;
    stream_test.exit_code = code;
    stream_test.cond.signal();
    stream_test.mutex.unlock();
}

test "bridge_run_streaming captures stdout and fires on_exit" {
    stream_test.reset();
    const req = try buildHelperRequestZ(&.{ "echo", "streaming", "hello" });
    defer testing.allocator.free(req);
    const handle = bridge_run_streaming(req.ptr, streamTestOnStdout, streamTestOnStderr, streamTestOnExit);
    try testing.expect(handle > 0);
    try testing.expect(stream_test.waitForExit(5 * std.time.ns_per_s));
    try testing.expectEqual(@as(i32, 0), stream_test.exit_code);
    try testing.expect(stream_test.stdout_total >= "streaming hello\n".len);
}

test "bridge_run_streaming reports stderr separately" {
    stream_test.reset();
    const req = try buildHelperRequestZ(&.{ "stderr", "from-stderr" });
    defer testing.allocator.free(req);
    const handle = bridge_run_streaming(req.ptr, streamTestOnStdout, streamTestOnStderr, streamTestOnExit);
    try testing.expect(handle > 0);
    try testing.expect(stream_test.waitForExit(5 * std.time.ns_per_s));
    try testing.expectEqual(@as(i32, 0), stream_test.exit_code);
    try testing.expect(stream_test.stderr_total >= "from-stderr\n".len);
}

test "bridge_run_streaming pre-spawn validation rejects empty exe" {
    // Note: posix_spawn defers exec failure to the child, so a missing
    // executable path still returns a positive handle (the child is
    // spawned, exec fails inside, child exits non-zero). The pre-spawn
    // validation we CAN test on the streaming path is the empty-exe
    // shortcut in bridge_run_streaming — that's caught synchronously
    // before any spawn attempt.
    stream_test.reset();
    const req: [*:0]const u8 = "{\"exe\":\"\"}";
    const rc = bridge_run_streaming(req, streamTestOnStdout, streamTestOnStderr, streamTestOnExit);
    try testing.expect(rc < 0);
    try testing.expectEqual(false, stream_test.exit_called);
}

test "bridge_run_streaming malformed JSON returns negative" {
    stream_test.reset();
    const req: [*:0]const u8 = "{not json";
    const rc = bridge_run_streaming(req, streamTestOnStdout, streamTestOnStderr, streamTestOnExit);
    try testing.expect(rc < 0);
    try testing.expectEqual(false, stream_test.exit_called);
}

test "bridge_cancel kills running stream" {
    stream_test.reset();
    const req = try buildHelperRequestZ(&.{ "sleep", "30" });
    defer testing.allocator.free(req);
    const handle = bridge_run_streaming(req.ptr, streamTestOnStdout, streamTestOnStderr, streamTestOnExit);
    try testing.expect(handle > 0);

    // Give the wait thread a moment to enter wait().
    std.Thread.sleep(100 * std.time.ns_per_ms);

    const rc = bridge_cancel(handle);
    try testing.expectEqual(@as(i32, 0), rc);

    try testing.expect(stream_test.waitForExit(5 * std.time.ns_per_s));
    // Killed by SIGTERM → exit code is -SIGTERM (-15) on POSIX,
    // 1 (TerminateProcess code) on Windows.
    try testing.expect(stream_test.exit_code != 0);
}

test "bridge_cancel with unknown handle returns -1" {
    const rc = bridge_cancel(999_999_999);
    try testing.expectEqual(@as(i32, -1), rc);
}

test "bridge_cancel after natural exit is safe no-op" {
    stream_test.reset();
    const req = try buildHelperRequestZ(&.{ "exit", "0" });
    defer testing.allocator.free(req);
    const handle = bridge_run_streaming(req.ptr, streamTestOnStdout, streamTestOnStderr, streamTestOnExit);
    try testing.expect(handle > 0);
    try testing.expect(stream_test.waitForExit(5 * std.time.ns_per_s));
    // Stream has already exited and unregistered; cancel should report -1
    // without touching anything.
    const rc = bridge_cancel(handle);
    try testing.expectEqual(@as(i32, -1), rc);
}

test "dispatchOrFree frees buffer when shutting_down is set" {
    // Unit-test the rollback-path helper directly: when shutting_down=true,
    // the buffer is freed locally and the (would-be) Dart callback is not
    // invoked. This is the contract that prevents leaks in the rare
    // wait_thread.spawn failure path inside bridge_run_streaming.
    const a = testing.allocator;
    var ctx: StreamingCtx = undefined;
    ctx.shutting_down = std.atomic.Value(bool).init(true);
    ctx.on_stdout_batch = struct {
        fn cb(_: [*]const u8, _: u32) callconv(.c) void {
            std.debug.panic("callback fired despite shutting_down=true", .{});
        }
    }.cb;

    const buf = try a.dupe(u8, "should be freed locally");
    // If dispatchOrFree dispatches instead of freeing, leak-check on
    // testing.allocator will fail at test exit (caught by the testing harness).
    dispatchOrFree(&ctx, ctx.on_stdout_batch, buf, a);
}

test "dispatchOrFree frees buffer when callback is null" {
    // Same contract for the "no callback registered" branch.
    const a = testing.allocator;
    var ctx: StreamingCtx = undefined;
    ctx.shutting_down = std.atomic.Value(bool).init(false);
    ctx.on_stdout_batch = null;

    const buf = try a.dupe(u8, "should be freed locally");
    dispatchOrFree(&ctx, ctx.on_stdout_batch, buf, a);
}

test "bridge_free is a no-op when len is zero" {
    // Defends against Dart-side bugs that pass (ptr, 0) after already
    // clearing the slot. A 0-len free with an arbitrary pointer would
    // otherwise be UB.
    var dummy: u8 = 0;
    bridge_free(@ptrCast(&dummy), 0);
}

test "bridge_run_streaming honours stdout_batch_lines from request" {
    // Helper emits 5 lines; request asks for batch_lines=1 → each line
    // arrives as a separate batch (5 batches total). Exercises the
    // request → ctx → reader-loop plumbing.
    stream_test.reset();
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"exe\":");
    try std.json.Stringify.value(helper_path, .{}, &aw.writer);
    try aw.writer.writeAll(
        ",\"args\":[\"echo\",\"a\\nb\\nc\\nd\\ne\"]," ++
            "\"stdout_batch_lines\":1}",
    );
    const req = try aw.toOwnedSliceSentinel(0);
    defer testing.allocator.free(req);

    const handle = bridge_run_streaming(req.ptr, streamTestOnStdout, streamTestOnStderr, streamTestOnExit);
    try testing.expect(handle > 0);
    try testing.expect(stream_test.waitForExit(5 * std.time.ns_per_s));
    try testing.expectEqual(@as(i32, 0), stream_test.exit_code);
    // Helper's echo joins args with single space, so we sent ONE arg
    // "a\nb\nc\nd\ne" + the trailing "\n" from echo's println = 5 newlines
    // → batch_lines=1 produces 5 batches.
    try testing.expectEqual(@as(usize, 5), stream_test.batch_count);
}
