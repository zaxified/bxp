//! bxp-gui-bridge — Dart FFI shim that proxies bxp-core inspect ops / bxp-cli calls.
//!
//! Why this exists: Dart's Process.start on Windows hits a deterministic
//! ~8 KB cutoff when reading subprocess stdout — the docs catalog (~30 KB)
//! never makes it back through the pipe and the GUI startup fails with
//! "error: WriteFailed". The root cause is in the dart:io C++ pipe layer
//! (see dart-lang/sdk#1727 + #51273, both still open). Three Dart-side
//! approaches (direct Process.start, runInShell, Process.run) all hit the
//! same 8150 B cutoff because they share that one C++ pipe path.
//!
//! This bridge is a runtime-loaded shared library (DynamicLibrary.open
//! from dart:ffi). It reads pipes from native code, so the drain happens
//! synchronously without depending on the Dart event loop being ready —
//! no spawn-vs-attach race, no Flutter UI competition. `bridge_run` (the
//! original export) takes a JSON request, spawns the requested child,
//! captures stdout/stderr/exit, and writes a JSON response into a
//! caller-provided buffer. The v0.3.0 flip grew the surface to ~11 exports:
//! a streaming proxy (`bridge_run_streaming` + `bridge_cancel`/`bridge_ack`)
//! and in-process families (`bridge_eval_expr`/`_trace`, `bridge_inspect`,
//! `bridge_verify_minisign`) that serve bxp-core/inspect directly, so the GUI
//! no longer spawns anything for stateless ops. See the C-ABI table in
//! `bxp-gui-bridge/CLAUDE.md`.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const inspect = @import("inspect");
const minisign = @import("minisign");
const procrun = @import("procrun");

/// Hard cap on captured bytes per stream (stdout, stderr) per call.
/// 64 MB per stream covers every realistic `bridge_run` payload —
/// `inspect.docsJson` / `--config` / `--list-templates` / `--expr-batch`
/// all produce bounded responses well under this. When a child exceeds
/// the cap, the bridge keeps the prefix and continues draining without
/// storing — the response carries `truncated: true` so the Dart side
/// can surface "output was clipped" instead of failing the whole call.
const max_output_bytes: usize = 64 * 1024 * 1024;

// ── Bridge-owned Io (Zig 0.16) ────────────────────────────────────────────
//
// This is a C-ABI shared library with no `std.process.Init`, but Zig 0.16
// routes all filesystem, subprocess and sync-primitive access through an `Io`
// instance. We create ONE process-lifetime `Threaded` io, lazily on first use,
// and reuse it everywhere (process spawn/wait, pipe reads, Io.Mutex/Semaphore).
// Backed by the libc allocator (the library links libc); never deinitialised —
// it lives for the whole host-process lifetime, like the streams table.
var g_threaded: std.Io.Threaded = undefined;
var g_io: std.Io = undefined;
// Spin-based once (Zig 0.16 removed `std.once`). A late caller blocks in the
// `.running` state until init publishes `.done`, so `g_io` is never read before
// it is fully constructed. In practice the first `bridgeIo()` runs on the Dart
// main isolate before any bridge thread exists, so contention is theoretical.
const OnceState = enum(u8) { idle, running, done };
var g_io_state = std.atomic.Value(u8).init(@intFromEnum(OnceState.idle));

/// The bridge's shared `Io`. Idempotent + threadsafe; the returned value
/// captures `&g_threaded`, which is a stable global.
fn bridgeIo() std.Io {
    while (true) {
        switch (@as(OnceState, @enumFromInt(g_io_state.load(.acquire)))) {
            .done => return g_io,
            .idle => {
                if (g_io_state.cmpxchgStrong(
                    @intFromEnum(OnceState.idle),
                    @intFromEnum(OnceState.running),
                    .acq_rel,
                    .acquire,
                ) == null) {
                    g_threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
                    g_io = g_threaded.io();
                    g_io_state.store(@intFromEnum(OnceState.done), .release);
                    return g_io;
                }
            },
            .running => std.atomic.spinLoopHint(),
        }
    }
}

// ── Child reaping ───────────────────────────────────────────────────────
//
// Both helpers below come from the zig-libs `procrun` module, which is where
// this bridge's own versions were extracted to. They exist because the bridge
// spawns children inside a host process that reaps children behind its back:
//
//   * The Dart VM runs an `ExitCodeHandler` thread parked in `wait4(-1)`,
//     which reaps ANY child of the process — usually the bridge's `bxp-cli`
//     before the bridge's own wait runs.
//   * A host that inherited `SIGCHLD = SIG_IGN` (some shells, CI harnesses)
//     has the kernel auto-reap every child.
//
// Either way the bridge's wait sees ECHILD, and `std.process.Child.wait`
// treats that as an unrecoverable double-free bug and panics — a racy SIGABRT
// at GUI startup. `procrun.ensureChildReaping` flips ONLY `SIG_IGN` → `SIG_DFL`
// (a real handler the host installed is left alone), and
// `procrun.waitTolerant` reaps through a path that maps ECHILD to
// `.unknown` — the child IS gone, its status is just unreadable. That
// `.unknown` is harmless here: the GUI reads the run's real exit code from
// bxp-cli's BXTB `done` frame, not from this value.
//
// Taking the module also picks up three things the local copies lacked: the
// reap goes through `std.posix.system.wait4`/`waitpid` (raw syscalls on Linux)
// instead of `std.c.waitpid`, there is a fallback for platforms without
// `wait4`, and `waitTolerant` NULLS `child.id` after reaping — so a
// `bridge_cancel` arriving after the wait thread finished is a no-op instead
// of signalling a pid the kernel may since have recycled (see
// `sendKillSignal`, which reads exactly that field).
//
// Only the reap core is taken. procrun's own runner (capped 3-thread drain,
// streaming handles, backpressure) is NOT used: the bridge's streaming path
// dispatches into Dart ports and owns its own thread/ack machinery.

const ensureChildReaping = procrun.ensureChildReaping;

fn waitTolerant(child: *std.process.Child) std.process.Child.Term {
    return procrun.waitTolerant(bridgeIo(), child);
}

// The SIGCHLD-disposition test that used to sit here moved upstream with the
// function ("ensureChildReaping: idempotent and leaves a real disposition
// alone" in procrun). It cannot be written against the module's public API
// anyway: the `SIG_IGN` → `SIG_DFL` flip is behind a one-shot guard, so a
// second call from a test is a no-op by design. What this file still tests is
// the integration — see the `waitTolerant` out-of-band-reap test near the end,
// which drives a real spawned child through the bridge's own wait path.

/// Request shape: which executable to run with which arguments.
/// Caller (Dart) is responsible for resolving the absolute path to
/// bxp-cli.exe; we don't probe PATH.
///
/// `cwd` is optional — when non-null the child runs with that working
/// directory. Used by the streaming dry-run path so relative
/// `data_dir` entries in the user's config resolve against the config
/// file's directory instead of bxp-gui's own CWD (Program Files).
///
/// Streaming and one-shot requests share this shape — extra fields the
/// Dart side may include are ignored (`ignore_unknown_fields = true`).
const Request = struct {
    exe: []const u8,
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
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
/// `stdin_ptr` + `stdin_len` carry an optional input body to write to the
/// child's stdin. When `stdin_len == 0` the child's stdin is closed
/// immediately (legacy behaviour, used by `inspect.docsJson` etc). When
/// non-zero the bridge spawns a writer thread that pushes the body and
/// closes the pipe, running concurrently with the stdout/stderr drainers
/// so a request larger than the OS pipe buffer doesn't deadlock against
/// a child that won't flush stdout until it has consumed stdin (the
/// `inspect.evalBatch` shape).
///
/// Memory: all internal allocations go through std.heap.c_allocator and
/// are released before returning. The response_buf is owned by the
/// caller — Dart side typically allocates from `malloc` via dart:ffi
/// and frees it after parsing the JSON.
export fn bridge_run(
    request_json: [*:0]const u8,
    stdin_ptr: [*]const u8,
    stdin_len: u32,
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

    const has_stdin = stdin_len > 0;
    const io = bridgeIo();
    // Suppress the briefly-visible cmd.exe window that Windows pops up when a
    // GUI parent (bxp-gui.exe) spawns a console-subsystem child (bxp-cli.exe);
    // `create_no_window` maps to CREATE_NO_WINDOW and is a no-op elsewhere.
    const cwd_opt: std.process.Child.Cwd = if (req.cwd) |cwd|
        (if (cwd.len > 0) .{ .path = cwd } else .inherit)
    else
        .inherit;

    ensureChildReaping();
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = if (has_stdin) .pipe else .close,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = cwd_opt,
        .create_no_window = true,
    }) catch |err| {
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
    // When stdin is in play, the writer thread runs concurrently with the
    // drainers — without this a child reading stdin while writing stdout
    // would deadlock once either side hits its pipe buffer. The writer
    // closes the child's stdin pipe on completion so the child's
    // `read(stdin)` sees EOF and proceeds to exit.
    var stdin_writer_err: ?anyerror = null;
    var stdin_writer_thread: ?std.Thread = null;
    if (has_stdin) {
        const stdin_slice = stdin_ptr[0..stdin_len];
        stdin_writer_thread = std.Thread.spawn(.{}, stdinWriterLoop, .{ &child, stdin_slice, &stdin_writer_err }) catch |err| blk: {
            stdin_writer_err = err;
            // Spawn failure — close stdin manually so the child unblocks
            // its read() and exits. Drainers + wait still run normally.
            if (child.stdin) |stdin_pipe| {
                stdin_pipe.close(io);
                child.stdin = null;
            }
            break :blk null;
        };
    }
    collectOutputCapped(&child, a, &stdout_buf, &stderr_buf, max_output_bytes, &truncated_flag) catch |err| {
        if (stdin_writer_thread) |t| t.join();
        // Best-effort kill (void in 0.16; ignores OS errors internally).
        child.kill(io);
        return writeErr(out_buf, "collect failed: {s}", .{@errorName(err)});
    };
    if (stdin_writer_thread) |t| t.join();
    if (stdin_writer_err) |werr| {
        // stdin write failed mid-stream (child closed its read end early,
        // pipe broken, OOM). Surface so the Dart side can distinguish
        // this from a child that simply exited non-zero. Drainers already
        // captured whatever stdout/stderr the child managed to emit.
        return writeErr(out_buf, "stdin write failed: {s}", .{@errorName(werr)});
    }

    // `waitTolerant` reaps (ECHILD-safe vs the Dart-VM reaper) and closes the
    // child's still-open pipe ends — see its doc comment.
    const term = waitTolerant(&child);

    const exit_code: i32 = switch (term) {
        .exited => |c| @intCast(c),
        .signal => |s| -@as(i32, @intCast(@intFromEnum(s))),
        .stopped, .unknown => -1,
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
    file: std.Io.File,
    buf: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    cap: usize,
    truncated: *std.atomic.Value(bool),
};

fn drainerLoop(args: DrainerArgs) void {
    const io = bridgeIo();
    var read_buf: [8192]u8 = undefined;
    while (true) {
        const n = args.file.readStreaming(io, &.{read_buf[0..]}) catch return;
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

/// Pump `data` into the child's stdin pipe and close it. Runs on its own
/// thread so a request body larger than the OS pipe buffer can't deadlock
/// against a child holding its stdout flush until it has finished reading
/// stdin (the `inspect.evalBatch` shape: write request, then read
/// response). Stores the first error encountered in `out_err` for the
/// caller to surface — there is no in-band channel back from a detached
/// writer otherwise.
fn stdinWriterLoop(
    child: *std.process.Child,
    data: []const u8,
    out_err: *?anyerror,
) void {
    const io = bridgeIo();
    var stdin = child.stdin orelse return;
    child.stdin = null;
    defer stdin.close(io);
    stdin.writeStreamingAll(io, data) catch |err| {
        out_err.* = err;
    };
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
// `--trace=bin` dry-run path — with the one-shot entrypoint, every trace
// frame arrived only after the child exited, so file-list + per-row counters
// never updated mid-run. With this entrypoint, each stdout pipe read fires
// the stdout callback as a raw chunk in real time.
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

/// Maximum number of un-acked stdout batches that can be in flight to
/// Dart at any one time. The stdout reader thread blocks on the per-stream
/// `queue_sema` before dispatching each batch; Dart calls `bridge_ack`
/// after processing a batch to release a permit. Without this bound, a
/// slow Dart consumer (GC pause, heavy rebuild) can let the bridge
/// accumulate batches in Dart's port queue indefinitely, each holding a
/// heap-allocated buffer — memory grows unbounded.
///
/// 32 chosen as a balance: large enough that bursty production
/// (100 lines/batch × ~200 B/line ≈ 20 KB × 32 ≈ 640 KB worst-case
/// in-flight) doesn't throttle realistic workloads, small enough to
/// bound memory under pathological backpressure. Stderr is NOT subject
/// to this limit — its volume is too low to matter.
const default_queue_permits: usize = 32;

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
    /// Bound on un-acked stdout batches in flight to Dart. Reader thread
    /// `wait`s a permit before dispatch; Dart `bridge_ack` posts one after
    /// it has processed the batch. See `default_queue_permits` for sizing.
    queue_sema: std.Io.Semaphore = .{ .permits = default_queue_permits },
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

var streams_mutex: std.Io.Mutex = .init;
var streams_table: std.AutoHashMapUnmanaged(i64, *StreamingCtx) = .empty;
var next_stream_handle: i64 = 1;

fn registerStream(ctx: *StreamingCtx) !i64 {
    const io = bridgeIo();
    streams_mutex.lockUncancelable(io);
    defer streams_mutex.unlock(io);
    const h = next_stream_handle;
    next_stream_handle += 1;
    try streams_table.put(std.heap.c_allocator, h, ctx);
    ctx.handle = h;
    return h;
}

fn unregisterStream(handle: i64) void {
    const io = bridgeIo();
    streams_mutex.lockUncancelable(io);
    defer streams_mutex.unlock(io);
    _ = streams_table.remove(handle);
}

/// Stdout reader: drain pipe in 8 KB chunks, dispatch each read() result
/// verbatim as a raw chunk. Used by the bxp-cli `--trace=bin` (BXTB) path
/// where stdout is a binary frame stream with no line boundaries.
///
/// Backpressure: `queue_sema.wait()` blocks until Dart acks via `bridge_ack`,
/// bounding the number of in-flight heap-allocated chunks. Cancel / rollback
/// paths post enough permits to drain any waiter so we never block past
/// the stream's natural lifetime.
///
/// Closes the pipe handle on exit so the child's write end isn't kept
/// open by us after the stream is drained.
fn streamingStdoutLoop(ctx: *StreamingCtx) void {
    const a = std.heap.c_allocator;
    const io = bridgeIo();
    var stdout = ctx.child.stdout orelse return;
    ctx.child.stdout = null;
    defer stdout.close(io);

    var read_buf: [8192]u8 = undefined;
    while (true) {
        const n = stdout.readStreaming(io, &.{read_buf[0..]}) catch break;
        if (n == 0) break;
        const chunk_copy = a.dupe(u8, read_buf[0..n]) catch return;
        ctx.queue_sema.waitUncancelable(io);
        dispatchOrFree(ctx, ctx.on_stdout_batch, chunk_copy, a);
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
    const io = bridgeIo();
    var stderr = ctx.child.stderr orelse return;
    ctx.child.stderr = null;
    defer stderr.close(io);

    var read_buf: [8192]u8 = undefined;
    while (true) {
        const n = stderr.readStreaming(io, &.{read_buf[0..]}) catch break;
        if (n == 0) break;
        const chunk_copy = a.dupe(u8, read_buf[0..n]) catch return;
        dispatchOrFree(ctx, ctx.on_stderr_chunk, chunk_copy, a);
    }
}

/// Wait thread: joins both reader threads (guaranteeing any in-flight
/// callbacks have drained AND that the readers — not child.wait() — own the
/// pipe fds), then reaps the child, calls on_exit, and frees the streaming
/// context. Must run detached because bridge_run_streaming returns to Dart
/// immediately after spawn.
fn streamingWaitLoop(ctx: *StreamingCtx) void {
    // Join the reader threads FIRST, before reaping. They exit on pipe EOF,
    // which the child's own exit produces (it closes its write ends as it
    // terminates, independently of the parent reaping the zombie) — so we
    // don't need to wait() first to make them finish. Joining before wait()
    // is also the *required* ordering: each reader takes ownership of its pipe
    // (sets `ctx.child.stdout` / `stderr` to null and closes its own copy)
    // only while it runs. `waitTolerant` closes + nulls any still-open
    // `child.stdout`/`stderr` itself (Zig 0.16). If that ran concurrently with
    // a reader it would race for the same fd: it either nulls the pipe out from
    // under a reader that hasn't read yet (→ 0 bytes delivered) or double-closes
    // the fd (→ EBADF panic in the reader thread, aborting the process). Both
    // reproduce under CPU load. Joining first guarantees both readers have
    // already nulled + closed their pipes, so waitTolerant's close loop is a
    // no-op on stdout/stderr.
    //
    // Joining is also the synchronisation point that guarantees no stream
    // callback fires after on_exit.
    ctx.stdout_thread.join();
    ctx.stderr_thread.join();

    // Now reap. ECHILD-tolerant (see waitTolerant): the Dart VM's
    // ExitCodeHandler may reap our child first, so a panicking std waitpid is
    // not safe here. The resulting `.Unknown` → exit_code -1 is harmless: the
    // GUI reads the run's real exit code from bxp-cli's BXTB `done` frame, not
    // from this value. The pipes are already null (readers closed them), so
    // child.wait()'s internal cleanupStreams() is a no-op — no double close.
    const term = waitTolerant(&ctx.child);

    const exit_code: i32 = switch (term) {
        .exited => |c| @intCast(c),
        .signal => |s| -@as(i32, @intCast(@intFromEnum(s))),
        .stopped, .unknown => -1,
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

    const io = bridgeIo();
    const cwd_opt: std.process.Child.Cwd = if (req.cwd) |cwd_str|
        (if (cwd_str.len > 0) .{ .path = cwd_str } else .inherit)
    else
        .inherit;

    ctx.on_stdout_batch = on_stdout_batch;
    ctx.on_stderr_chunk = on_stderr_chunk;
    ctx.on_exit = on_exit;
    ctx.handle = 0;
    ctx.shutting_down = std.atomic.Value(bool).init(false);
    // Reset queue_sema permits — ctx was allocated via c_allocator.create
    // (not zeroed), so the default struct initialiser hasn't run.
    ctx.queue_sema = .{ .permits = default_queue_permits };

    // Rollback signal: any failure between here and the final `started_ok = true`
    // raises this flag. Reader threads check it before invoking a Dart callback
    // — if set, they free the per-batch buffer locally instead of handing it
    // across the FFI, where it would orphan in Dart's port queue after the
    // listener closes.
    //
    // This defer is declared BEFORE child.spawn, so in LIFO order it runs
    // AFTER the `child_ok` defer (kill child + join readers) below — i.e. too
    // late to protect that join. The `child_ok` defer therefore raises the
    // flag itself before joining; this block is the residual cover for the
    // narrow pre-reader-spawn window (a `child.spawn` failure, where no reader
    // threads exist yet so the raise is a harmless no-op).
    var started_ok = false;
    defer if (!started_ok) {
        ctx.shutting_down.store(true, .release);
        // Wake any reader thread blocked on queue_sema so it can observe
        // the shutdown flag and self-free its pending batch instead of
        // dispatching across a tearing-down FFI. Posting `default_queue_permits`
        // unblocks at most that many waiters; extra posts just inflate
        // permits harmlessly because the ctx is about to be destroyed.
        var i: usize = 0;
        while (i < default_queue_permits) : (i += 1) ctx.queue_sema.post(io);
    };

    ensureChildReaping();
    ctx.child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .close,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = cwd_opt,
        .create_no_window = true,
    }) catch return -1;
    // Single combined rollback for child + reader threads: kill the
    // child FIRST (so any spawned reader threads' read() calls return
    // EOF and exit their loops), THEN join the readers. The previous
    // shape — separate child_ok / stdout_ok / stderr_ok defers — fired
    // joins before kill in LIFO order on the rare `registerStream` OOM
    // path, deadlocking on readers blocked in read() with a child still
    // alive. `child_ok` flips true on the success path so the rollback
    // is skipped after we've handed ownership to the wait thread.
    var stdout_spawned = false;
    var stderr_spawned = false;
    var child_ok = false;
    defer if (!child_ok) {
        // Raise the shutdown flag and wake any blocked reader BEFORE killing
        // the child and joining the reader threads. A reader that drains the
        // last buffered bytes during the join must observe `shutting_down` and
        // self-free its batch rather than hand it across the FFI, where it
        // would orphan in Dart's port queue after the listener closes. The
        // separate `started_ok` defer below ALSO raises the flag, but defers
        // are LIFO so it runs AFTER this block — too late for this join. So
        // this rollback path must raise the flag itself.
        ctx.shutting_down.store(true, .release);
        var wake: usize = 0;
        while (wake < default_queue_permits) : (wake += 1) ctx.queue_sema.post(io);
        ctx.child.kill(io);
        if (stdout_spawned) ctx.stdout_thread.join();
        if (stderr_spawned) ctx.stderr_thread.join();
    };

    ctx.stdout_thread = std.Thread.spawn(.{}, streamingStdoutLoop, .{ctx}) catch return -1;
    stdout_spawned = true;

    ctx.stderr_thread = std.Thread.spawn(.{}, streamingStderrLoop, .{ctx}) catch return -1;
    stderr_spawned = true;

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
    const io = bridgeIo();
    streams_mutex.lockUncancelable(io);
    defer streams_mutex.unlock(io);
    const ctx = streams_table.get(handle) orelse return -1;
    // Wake any reader thread blocked on queue_sema before sending the
    // kill signal — if the reader is mid-wait, the child's eventual EOF
    // would never reach it, and the stream would hang past cancellation.
    // Posting `default_queue_permits` covers the worst case (all permits
    // exhausted by un-acked batches).
    var i: usize = 0;
    while (i < default_queue_permits) : (i += 1) ctx.queue_sema.post(io);
    sendKillSignal(&ctx.child);
    return 0;
}

/// Release one permit on a streaming run's backpressure semaphore.
/// Dart calls this after processing each stdout batch (decode + onLine
/// + bridge_free) so the bridge knows it can dispatch another batch.
/// Returns 0 on success, -1 if the handle is unknown (stream already
/// exited, or never valid). Idempotent in the sense that extra acks
/// just inflate the permit count harmlessly.
export fn bridge_ack(handle: i64) i32 {
    const io = bridgeIo();
    streams_mutex.lockUncancelable(io);
    defer streams_mutex.unlock(io);
    const ctx = streams_table.get(handle) orelse return -1;
    ctx.queue_sema.post(io);
    return 0;
}

// Zig 0.16 dropped `std.os.windows.kernel32.TerminateProcess`, so the
// kernel32 entry point is declared locally for the Windows cancel path below
// (mirrors the self-declared psapi GetProcessMemoryInfo in bxp-cli/main.zig).
extern "kernel32" fn TerminateProcess(
    hProcess: std.os.windows.HANDLE,
    uExitCode: std.os.windows.UINT,
) callconv(.winapi) std.os.windows.BOOL;

/// Deliver a "please exit now" signal without waiting on the child.
/// std.process.Child.kill() on POSIX combines kill + waitpid, which
/// would race with streamingWaitLoop's own waitpid call → ECHILD. We
/// only signal here and let the wait thread reap.
fn sendKillSignal(child: *std.process.Child) void {
    const pid = child.id orelse return;
    if (builtin.os.tag == .windows) {
        _ = TerminateProcess(pid, 1);
    } else {
        std.posix.kill(pid, std.posix.SIG.TERM) catch {};
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

// ── In-process expr evaluation ──────────────────────────────────────────
//
// New-style FFI family — see "Adding a new bridge FFI export" in
// docs/devel.md for the conventions these exports follow:
//   * caller-supplied output buffer, `bytes_written` return value
//   * negative codes for bridge-level failures only
//   * per-call arena; no handle table, no Dart-side `bridge_free`
//   * stateless and thread-safe — safe to call direct from main isolate
//
// First member of the family: `bridge_eval_expr`, the in-process equivalent
// of `inspect.validateExpr <text>`. Replaces a ~50 ms subprocess spawn with a
// ~1 ms direct call so the GUI's per-keystroke validation no longer pays
// the spawn tax.

/// Negative return codes for new-style FFI exports. Positive returns are
/// always `bytes_written` to `out_buf` and may carry a success or
/// failure JSON payload depending on the specific export.
const BridgeFfiError = enum(i32) {
    out_of_memory = -1,
    buf_too_small = -2,
    invalid_input = -3,
};

/// Validate an expression's syntax + semantic correctness against an empty
/// row context. Mirrors `inspect.validateExpr <text>` runtime-wise but in-process,
/// avoiding the ~50 ms subprocess spawn the GUI pays per keystroke today.
///
/// Returns:
///   * `0` — valid expression (out_buf untouched)
///   * `> 0` — invalid expression, `bytes_written` of JSON in out_buf:
///     `{"error":"<ErrorName>","detail":"<detail>","off":N,"len":N}`
///     Matches the inspect.validateExpr stderr shape so the existing Dart
///     parser in `BxpProcessClient.validateExpr` works unchanged.
///   * `-1` OOM in bridge area (extreme edge — c_allocator can't satisfy)
///   * `-2` BUF_TOO_SMALL — caller retries with a bigger buffer
///   * `-3` reserved (not currently emitted)
export fn bridge_eval_expr(
    text_ptr: [*]const u8,
    text_len: u32,
    out_buf: [*]u8,
    out_size: u32,
) callconv(.c) i32 {
    if (text_len == 0) return 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const text = text_ptr[0..text_len];
    const out = out_buf[0..out_size];

    // Validation core (runtime eval against an empty row context + static
    // FnArgDoc checks) lives in inspect.validateExpr, shared with bxp-mcp
    // --expr so editor-time and CLI diagnostics stay in sync. `[ColumnName]`
    // references resolve to "" here (row-aware eval goes through
    // bridge_eval_expr_trace).
    const maybe_err = inspect.validateExpr(alloc, text) catch
        return @intFromEnum(BridgeFfiError.out_of_memory);
    if (maybe_err) |e| return writeExprErrorJson(out, e.name, e.detail, e.off, e.len);
    return 0;
}

/// Serialise an expr validation finding (from inspect.validateExpr) into the
/// caller-supplied `out` buffer: `{"error":<name>,"detail":<detail>,"off"?,
/// "len"?}`. `off`/`len` appear only when `len > 0`. Shape matches `bxp-fmt
/// --expr` stderr JSON exactly, so Dart-side `BxpProcessClient.validateExpr`
/// parses the bridge response identically to the subprocess response. Returns
/// positive byte count on success or `BUF_TOO_SMALL` (-2) on overflow.
fn writeExprErrorJson(
    out: []u8,
    name: []const u8,
    detail: []const u8,
    err_offset: u32,
    err_len: u32,
) i32 {
    var w: std.Io.Writer = .fixed(out);
    var jw: std.json.Stringify = .{ .writer = &w, .options = .{} };
    const buf_too_small = @intFromEnum(BridgeFfiError.buf_too_small);
    jw.beginObject() catch return buf_too_small;
    jw.objectField("error") catch return buf_too_small;
    jw.write(name) catch return buf_too_small;
    jw.objectField("detail") catch return buf_too_small;
    jw.write(detail) catch return buf_too_small;
    if (err_len > 0) {
        jw.objectField("off") catch return buf_too_small;
        jw.write(err_offset) catch return buf_too_small;
        jw.objectField("len") catch return buf_too_small;
        jw.write(err_len) catch return buf_too_small;
    }
    jw.endObject() catch return buf_too_small;
    return @intCast(w.buffered().len);
}

/// Evaluate an expression against a fake-row context (headers + fields)
/// and emit one NDJSON line per traced function call into out_buf, plus
/// a final sentinel describing the eval result. Mirrors `bxp-fmt
/// --expr-trace <text> --row-headers <json> --row-fields <json>` but
/// in-process — used by the GUI's hover-on-token tooltip path.
///
/// Output payload shape (NDJSON, one JSON object per line):
///   {"fn":"ABS","src_start":2,"src_end":9,"value":"100"}    (per-call)
///   {"fn":"IF","src_start":0,"src_end":36,"value":"BUY"}    (per-call)
///   {"t":"final","value":"BUY"}                              (success)
/// On eval failure the final line is replaced with the error sentinel:
///   {"t":"error","error":"<ErrorName>","detail":"...","off":N,"len":N}
/// Trace lines emitted before the failure point are preserved so the
/// hover layer can show partial results.
///
/// Returns:
///   * `0` — empty input (text_len == 0): no payload emitted
///   * `> 0` — `bytes_written` of NDJSON in out_buf
///   * `-1` OOM (transient scratch allocation failed)
///   * `-2` BUF_TOO_SMALL — accumulated payload exceeds out_size
///   * `-3` INVALID_INPUT — headers/fields aren't matching JSON arrays
///     of strings, or arrays have mismatched lengths
export fn bridge_eval_expr_trace(
    text_ptr: [*]const u8,
    text_len: u32,
    headers_json_ptr: [*]const u8,
    headers_json_len: u32,
    fields_json_ptr: [*]const u8,
    fields_json_len: u32,
    out_buf: [*]u8,
    out_size: u32,
) callconv(.c) i32 {
    if (text_len == 0) return 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const text = text_ptr[0..text_len];
    const out = out_buf[0..out_size];
    const oom = @intFromEnum(BridgeFfiError.out_of_memory);

    // Hand the headers/fields JSON blobs straight to inspect.evalTrace — the
    // shared trace core also behind inspect.evalTrace and the MCP
    // bxp_eval_trace tool. null blob = no row context. Ragged headers/fields
    // are tolerated (matches the runtime engine + fmt; field access is by
    // header→index), so unlike the old hand-rolled path this no longer rejects
    // a length mismatch — the Dart caller always sends a matching pair anyway.
    const headers_json: ?[]const u8 = if (headers_json_len > 0) headers_json_ptr[0..headers_json_len] else null;
    const fields_json: ?[]const u8 = if (fields_json_len > 0) fields_json_ptr[0..fields_json_len] else null;

    // Accumulate the trace payload (per-call lines + terminal sentinel) in an
    // arena-backed writer first, then copy to out_buf — so we know up-front
    // whether the full payload fits (no "partial NDJSON, no sentinel" shape).
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    const result = inspect.evalTrace(alloc, text, headers_json, fields_json, &aw.writer) catch |err| switch (err) {
        error.InvalidRowJson => return @intFromEnum(BridgeFfiError.invalid_input),
        else => return oom,
    };
    // On eval failure inspect.evalTrace returns the error sentinel rather than
    // writing it; append it to the same stream (matches the old behaviour and
    // the MCP tool — error sentinel rides inline after any partial traces).
    if (result.error_json) |ej| {
        aw.writer.writeAll(ej) catch return oom;
        aw.writer.writeByte('\n') catch return oom;
    }

    const written = aw.written();
    if (written.len > out.len) return @intFromEnum(BridgeFfiError.buf_too_small);
    @memcpy(out[0..written.len], written);
    return @intCast(written.len);
}

/// Optional string field from a parsed JSON object — null if missing/wrong type.
fn objStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// In-process inspect dispatcher — serves the stateless inspect operations the
/// GUI used to spawn (`--docs`, `--config`, `--list-templates`,
/// `--fetch-template`, `--expr-batch`) directly from bxp-core/inspect, so the
/// GUI no longer spawns bxp-fmt for them. Output is the same JSON the former
/// bxp-fmt stdout produced; the bridge runs in the GUI process, so relative
/// `data_dir` paths in the config's FS check resolve against the same CWD the
/// spawned bxp-fmt used (no behaviour change).
///
/// `request_json` is one object:
///   {"op":"docs"}
///   {"op":"config","path":"…","check_fs":N}
///   {"op":"list_templates","path":"…"}
///   {"op":"fetch_template","path":"…","id":"…"}
///   {"op":"eval_batch","request":{ headers, fields, exprs, … }}
///
/// Returns: `> 0` byte count of result JSON in out_buf; `-1` OOM; `-2`
/// BUF_TOO_SMALL (caller retries larger); `-3` INVALID_INPUT (bad request /
/// unknown op / missing field / malformed eval_batch request).
export fn bridge_inspect(
    request_ptr: [*]const u8,
    request_len: u32,
    out_buf: [*]u8,
    out_size: u32,
) callconv(.c) i32 {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const oom = @intFromEnum(BridgeFfiError.out_of_memory);
    const invalid = @intFromEnum(BridgeFfiError.invalid_input);
    const out = out_buf[0..out_size];

    const parsed = std.json.parseFromSlice(std.json.Value, a, request_ptr[0..request_len], .{}) catch
        return invalid;
    defer parsed.deinit();
    if (parsed.value != .object) return invalid;
    const obj = parsed.value.object;
    const op = objStr(obj, "op") orelse return invalid;

    const result: []const u8 = if (std.mem.eql(u8, op, "docs"))
        (inspect.docsJson(a) catch return oom)
    else if (std.mem.eql(u8, op, "config")) blk: {
        const path = objStr(obj, "path") orelse return invalid;
        const check_fs: u8 = if (obj.get("check_fs")) |v| switch (v) {
            .integer => |i| std.math.cast(u8, i) orelse 0,
            else => 0,
        } else 0;
        const r = inspect.annotateConfigFromFile(a, path, check_fs) catch return oom;
        break :blk r.json;
    } else if (std.mem.eql(u8, op, "list_templates")) blk: {
        const path = objStr(obj, "path") orelse return invalid;
        break :blk inspect.listTemplatesFromFile(a, path) catch return oom;
    } else if (std.mem.eql(u8, op, "fetch_template")) blk: {
        const path = objStr(obj, "path") orelse return invalid;
        const id = objStr(obj, "id") orelse return invalid;
        const r = inspect.fetchTemplateFromFile(a, path, id) catch return oom;
        break :blk r.json;
    } else if (std.mem.eql(u8, op, "eval_batch")) blk: {
        const reqv = obj.get("request") orelse return invalid;
        const r = inspect.evalBatch(a, reqv) catch return oom;
        if (r.error_message != null) return invalid;
        break :blk r.json;
    } else return invalid;

    if (result.len > out.len) return @intFromEnum(BridgeFfiError.buf_too_small);
    @memcpy(out[0..result.len], result);
    return @intCast(result.len);
}

// ── Minisign signature verification ─────────────────────────────────────
//
// Verifies a minisign signature over a file (the release `SHA256SUMS`)
// against the maintainer's embedded public key, so the GUI updater can
// confirm the checksum manifest is authentic before trusting it.
//
// The format parsing and the Ed25519 / Blake2b-512 verification both live in
// the zig-libs `minisign` module (see bxp-core/build.zig for why the module
// comes through bxp-core rather than a second pin here). This file used to
// carry an 81-line hand-rolled parser instead — which mattered because the
// `.minisig` text it reads is FETCHED OVER THE NETWORK by the updater, so it
// is attacker-reachable input. Upstream verifies the same two layers with
// known-answer vectors generated by the real `minisign` 0.12 binary, a fuzz
// harness over `parseSignatureFile`, and the reference's own printable-comment
// guard; the local copy had four tests and none of that. Nothing here
// allocates on the heap: the one scratch buffer the trusted-comment layer
// needs is a stack `FixedBufferAllocator`.
//
// What this wrapper still owns is the C-ABI contract with Dart: the
// `MinisignResult` codes below, and the mapping from upstream's typed errors
// onto them. That mapping is the reason `verifyMessage` is called separately
// rather than through `minisign.verifyFile` — a key-id mismatch has to stay
// distinguishable from a bad signature (`key_mismatch` vs `verify_failed`).

/// Verify-result codes returned by `bridge_verify_minisign`. Zero means
/// authentic; any non-zero value means refuse the install. Distinct positive
/// codes let the Dart side surface a specific reason.
const MinisignResult = enum(i32) {
    ok = 0,
    bad_pubkey = 1,
    bad_sig_file = 2,
    key_mismatch = 3,
    verify_failed = 4,
};

/// Scratch space for the trusted-comment layer: upstream concatenates
/// `signature(64) ++ trusted_comment` and signs/verifies that in one call, so
/// it takes an allocator. A stack `FixedBufferAllocator` over this buffer
/// keeps the entry point heap-free, and its size IS the trusted-comment cap —
/// a longer comment fails the allocation and is refused as `bad_sig_file`,
/// which is exactly what the previous hand-rolled length check did.
const minisign_scratch_len = 64 + 2048;

/// Verify a minisign signature (`sig_*`, the `.minisig` file text) over the
/// file bytes (`file_*`, the release `SHA256SUMS`) against the base64 public
/// key (`pubkey_*`, the key part of `minisign.pub`). Returns a `MinisignResult`
/// code — `0` is authentic, non-zero refuses. No heap allocation, thread-safe.
export fn bridge_verify_minisign(
    file_ptr: [*]const u8,
    file_len: u32,
    sig_ptr: [*]const u8,
    sig_len: u32,
    pubkey_ptr: [*]const u8,
    pubkey_len: u32,
) callconv(.c) i32 {
    if (file_len == 0 or sig_len == 0 or pubkey_len == 0)
        return @intFromEnum(MinisignResult.bad_sig_file);

    const file = file_ptr[0..file_len];
    const sig_text = sig_ptr[0..sig_len];
    const pubkey_b64 = pubkey_ptr[0..pubkey_len];

    // The GUI embeds the bare base64 key struct, not a two-line `.pub` file.
    const pub_key = minisign.parsePublicKeyBase64(pubkey_b64) catch
        return @intFromEnum(MinisignResult.bad_pubkey);

    // Parsing validates the whole 4-line framing before any crypto runs:
    // both comment prefixes, exact base64 lengths, a known algorithm tag, and
    // the reference's printable-comment rule on the trusted comment.
    const parsed = minisign.parseSignatureFile(sig_text) catch
        return @intFromEnum(MinisignResult.bad_sig_file);

    // Layer 1 — the file itself. Prehashed ("ED") signs Blake2b-512(file),
    // legacy ("Ed") the bytes; upstream picks by tag. A key-id mismatch is
    // reported as its own code, so the GUI can say "not our key" rather than
    // "bad signature".
    minisign.verifyMessage(pub_key, file, parsed.signature) catch |err|
        return @intFromEnum(switch (err) {
            error.KeyIdMismatch => MinisignResult.key_mismatch,
            error.UnsupportedAlgorithm => MinisignResult.bad_sig_file,
            else => MinisignResult.verify_failed,
        });

    // Layer 2 — the global signature binding the trusted comment.
    var scratch: [minisign_scratch_len]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    minisign.verifyTrustedComment(
        fba.allocator(),
        pub_key,
        parsed.signature,
        parsed.trusted_comment,
        parsed.global_signature,
    ) catch |err| return @intFromEnum(switch (err) {
        // Comment longer than the scratch cap — refuse it as a malformed
        // signature file, the pre-module behaviour for the same input.
        error.OutOfMemory => MinisignResult.bad_sig_file,
        else => MinisignResult.verify_failed,
    });

    return @intFromEnum(MinisignResult.ok);
}

// ── Minisign verification tests ──────────────────────────────────────────
//
// Vectors generated with minisign 0.11 (`minisign -G -W` + `-S`), the same
// prehashed ("ED" / Blake2b-512) shape `scripts/release-02-desktop.sh`
// produces. The key here is a throwaway test key, NOT the release key.

const ms_test_pubkey = "RWQEcu0vt68SdjtYvqFgob3VvMjsOOgNp4I4XXVoz63OSJHAus5CqDVe";
const ms_test_file = "abc123  bxp-desktop-linux-x86_64.AppImage\n";
const ms_test_sig =
    "untrusted comment: signature from minisign secret key\n" ++
    "RUQEcu0vt68Sdpoe4VOmFICkvQaGYDo7PoaSoTidwMK6CoT2pyDdPjtOn1xgmYJfXayf336GWzvgf4Yh+LtL+XypPsX0vUSF0wY=\n" ++
    "trusted comment: timestamp:1781452539\tfile:SHA256SUMS\thashed\n" ++
    "bgwWEjryrROXcZzXj13Mm0Oqhw6N+iGJSoTvgVFyZbGaihcEDdTiBIf8zMpLWOmNgxKPkAdzEIB7nurDCRZsAA==\n";

fn callVerify(file: []const u8, sig: []const u8, pubkey: []const u8) i32 {
    return bridge_verify_minisign(
        file.ptr,
        @intCast(file.len),
        sig.ptr,
        @intCast(sig.len),
        pubkey.ptr,
        @intCast(pubkey.len),
    );
}

test "bridge_verify_minisign accepts a valid prehashed signature" {
    try testing.expectEqual(
        @intFromEnum(MinisignResult.ok),
        callVerify(ms_test_file, ms_test_sig, ms_test_pubkey),
    );
}

test "bridge_verify_minisign rejects a tampered file" {
    try testing.expectEqual(
        @intFromEnum(MinisignResult.verify_failed),
        callVerify("abc123  bxp-desktop-linux-x86_64.AppImageX\n", ms_test_sig, ms_test_pubkey),
    );
}

test "bridge_verify_minisign rejects a different public key" {
    // Same length / format, different key → key_id won't match.
    const other = "RWThisIsADifferentKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const r = callVerify(ms_test_file, ms_test_sig, other);
    try testing.expect(r != @intFromEnum(MinisignResult.ok));
}

test "bridge_verify_minisign rejects malformed inputs" {
    try testing.expectEqual(
        @intFromEnum(MinisignResult.bad_sig_file),
        callVerify("", ms_test_sig, ms_test_pubkey),
    );
    try testing.expectEqual(
        @intFromEnum(MinisignResult.bad_pubkey),
        callVerify(ms_test_file, ms_test_sig, "not-base64!!!"),
    );
    try testing.expectEqual(
        @intFromEnum(MinisignResult.bad_sig_file),
        callVerify(ms_test_file, "only one line\n", ms_test_pubkey),
    );
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
/// `args`, optionally including a `cwd` field. Returned slice is
/// null-terminated (the bridge expects a C string) and allocated on the
/// test allocator; caller frees with `testing.allocator.free(req)`.
fn buildHelperRequestZ(args: []const []const u8) ![:0]u8 {
    return buildHelperRequestZWithCwd(args, null);
}

/// Variant of `buildHelperRequestZ` that adds a `cwd` field.
fn buildHelperRequestWithCwdZ(args: []const []const u8, cwd: []const u8) ![:0]u8 {
    return buildHelperRequestZWithCwd(args, cwd);
}

fn buildHelperRequestZWithCwd(args: []const []const u8, cwd: ?[]const u8) ![:0]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"exe\":");
    try std.json.Stringify.value(helper_path, .{}, &aw.writer);
    try aw.writer.writeAll(",\"args\":[");
    for (args, 0..) |arg, i| {
        if (i > 0) try aw.writer.writeAll(",");
        try std.json.Stringify.value(arg, .{}, &aw.writer);
    }
    try aw.writer.writeAll("]");
    if (cwd) |c| {
        try aw.writer.writeAll(",\"cwd\":");
        try std.json.Stringify.value(c, .{}, &aw.writer);
    }
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
    const n = bridge_run(req, "".ptr, 0, &buf, @intCast(buf.len));
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
    const n = bridge_run(req, "".ptr, 0, &buf, @intCast(buf.len));
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
    const n = bridge_run(req, "".ptr, 0, &buf, @intCast(buf.len));
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
    const n = bridge_run(req.ptr, "".ptr, 0, &buf, @intCast(buf.len));
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
    const n = bridge_run(req.ptr, "".ptr, 0, &buf, @intCast(buf.len));
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
    const n = bridge_run(req.ptr, "".ptr, 0, &buf, @intCast(buf.len));
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
    // The `both` test_helper subcommand uses raw unbuffered File.writeAll
    // for both streams so the writes hit the kernel pipe synchronously
    // before the helper exits; no retry crutch needed.
    const req = try buildHelperRequestZ(&.{"both"});
    defer testing.allocator.free(req);

    var buf: [4096]u8 = undefined;
    const n = bridge_run(req.ptr, "".ptr, 0, &buf, @intCast(buf.len));
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
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_n = try std.process.currentPath(bridgeIo(), &cwd_buf);
    const cwd = cwd_buf[0..cwd_n];

    var buf: [4096]u8 = undefined;
    const req = try buildHelperRequestWithCwdZ(&.{"pwd"}, cwd);
    defer testing.allocator.free(req);
    const n = bridge_run(req.ptr, "".ptr, 0, &buf, @intCast(buf.len));
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

test "bridge_run round-trips stdin to stdout through helper" {
    // Sanity check: small payload should flow stdin → child → stdout without
    // any deadlock or corruption. Covers the inspect.evalBatch shape
    // where Dart sends a JSON request body on stdin and reads the response
    // from stdout.
    var buf: [4096]u8 = undefined;
    const req = try buildHelperRequestZ(&.{"stdin-echo"});
    defer testing.allocator.free(req);
    const payload = "hello bridge stdin\nline two";
    const n = bridge_run(
        req.ptr,
        payload.ptr,
        @intCast(payload.len),
        &buf,
        @intCast(buf.len),
    );
    try testing.expect(n > 0);
    const parsed = try std.json.parseFromSlice(
        Response,
        testing.allocator,
        buf[0..@intCast(n)],
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(i32, 0), parsed.value.exit_code);
    try testing.expectEqualStrings(payload, parsed.value.stdout);
    try testing.expectEqual(@as(?[]const u8, null), parsed.value.err);
}

test "bridge_run stdin write survives request larger than pipe buffer" {
    // The whole point of running the stdin writer on its own thread is so
    // bodies bigger than the OS pipe buffer (typically 4-64 KB) don't
    // deadlock with the stdout/stderr drainers. Push 1 MiB through to
    // verify the concurrent setup holds.
    const big_size: usize = 1 * 1024 * 1024;
    const payload = try testing.allocator.alloc(u8, big_size);
    defer testing.allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    const out_buf = try testing.allocator.alloc(u8, 4 * 1024 * 1024);
    defer testing.allocator.free(out_buf);

    const req = try buildHelperRequestZ(&.{"stdin-echo"});
    defer testing.allocator.free(req);
    const n = bridge_run(
        req.ptr,
        payload.ptr,
        @intCast(payload.len),
        out_buf.ptr,
        @intCast(out_buf.len),
    );
    try testing.expect(n > 0);
    const parsed = try std.json.parseFromSlice(
        Response,
        testing.allocator,
        out_buf[0..@intCast(n)],
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(i32, 0), parsed.value.exit_code);
    try testing.expectEqual(@as(usize, big_size), parsed.value.stdout.len);
    try testing.expectEqualSlices(u8, payload, parsed.value.stdout);
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
    const n = bridge_run(req.ptr, "".ptr, 0, out_buf.ptr, @intCast(big_buf_size));
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
    var child = try std.process.spawn(bridgeIo(), .{
        .argv = argv.items,
        .stdin = .close,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var stdout_buf: std.ArrayList(u8) = .empty;
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(a);
    defer stderr_buf.deinit(a);
    var trunc = std.atomic.Value(bool).init(false);
    try collectOutputCapped(&child, a, &stdout_buf, &stderr_buf, 128, &trunc);
    _ = waitTolerant(&child);

    try testing.expectEqual(@as(usize, 128), stdout_buf.items.len);
    try testing.expectEqual(true, trunc.load(.acquire));
}

test "waitTolerant survives a child reaped by another waiter (no ECHILD panic)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(a);
    try argv.append(a, helper_path);
    try argv.append(a, "stdout-bytes");
    try argv.append(a, "0");
    var child = try std.process.spawn(bridgeIo(), .{
        .argv = argv.items,
        .stdin = .close,
        .stdout = .ignore,
        .stderr = .ignore,
    });

    // Simulate the Dart VM's wait4(-1) ExitCodeHandler winning the race:
    // reap the child ourselves first. A naive child.wait(io) would now hit
    // ECHILD → errnoBug → panic.
    const pid = child.id.?;
    const reaped = std.c.waitpid(pid, null, 0);
    try testing.expect(reaped == pid);

    // Must not panic; the status is gone so it reports .unknown.
    const term = waitTolerant(&child);
    switch (term) {
        .unknown => {},
        else => return error.TestExpectedUnknownTerm,
    }
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

/// Test-only sleep (Zig 0.16 removed `std.Thread.sleep`); blocks the calling
/// thread for `ms` milliseconds via the bridge io's monotonic clock.
fn testSleepMs(ms: u64) void {
    const dur: std.Io.Clock.Duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)),
        .clock = .awake,
    };
    dur.sleep(bridgeIo()) catch {};
}

const stream_test = struct {
    var stdout_total: usize = 0;
    var stderr_total: usize = 0;
    var batch_count: usize = 0;
    var exit_code: i32 = 0;
    var mutex: std.Io.Mutex = .init;
    // Zig 0.16's Io.Condition has no timed wait, so the exit signal uses an
    // Io.Event (which does — `waitTimeout`). The mutex still guards the counters.
    var exit_event: std.Io.Event = .unset;

    fn reset() void {
        const io = bridgeIo();
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        stdout_total = 0;
        stderr_total = 0;
        batch_count = 0;
        exit_code = 0;
        exit_event.reset();
    }

    fn waitForExit(timeout_ns: u64) bool {
        const io = bridgeIo();
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
            .raw = std.Io.Duration.fromNanoseconds(@intCast(timeout_ns)),
            .clock = .awake,
        });
        const timeout: std.Io.Timeout = .{ .deadline = deadline };
        while (!exit_event.isSet()) {
            exit_event.waitTimeout(io, timeout) catch {};
            if (exit_event.isSet()) return true;
            const now = std.Io.Clock.Timestamp.now(io, .awake);
            if (deadline.compare(.lte, now)) return false;
        }
        return true;
    }
};

fn streamTestOnStdout(data: [*]const u8, len: u32) callconv(.c) void {
    const io = bridgeIo();
    stream_test.mutex.lockUncancelable(io);
    stream_test.stdout_total += len;
    stream_test.batch_count += 1;
    stream_test.mutex.unlock(io);
    bridge_free(@constCast(data), len);
}

fn streamTestOnStderr(data: [*]const u8, len: u32) callconv(.c) void {
    const io = bridgeIo();
    stream_test.mutex.lockUncancelable(io);
    stream_test.stderr_total += len;
    stream_test.mutex.unlock(io);
    bridge_free(@constCast(data), len);
}

fn streamTestOnExit(code: i32) callconv(.c) void {
    const io = bridgeIo();
    stream_test.mutex.lockUncancelable(io);
    stream_test.exit_code = code;
    stream_test.mutex.unlock(io);
    stream_test.exit_event.set(io);
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
    try testing.expectEqual(false, stream_test.exit_event.isSet());
}

test "bridge_run_streaming malformed JSON returns negative" {
    stream_test.reset();
    const req: [*:0]const u8 = "{not json";
    const rc = bridge_run_streaming(req, streamTestOnStdout, streamTestOnStderr, streamTestOnExit);
    try testing.expect(rc < 0);
    try testing.expectEqual(false, stream_test.exit_event.isSet());
}

test "bridge_cancel kills running stream" {
    stream_test.reset();
    const req = try buildHelperRequestZ(&.{ "sleep", "30" });
    defer testing.allocator.free(req);
    const handle = bridge_run_streaming(req.ptr, streamTestOnStdout, streamTestOnStderr, streamTestOnExit);
    try testing.expect(handle > 0);

    // Give the wait thread a moment to enter wait().
    testSleepMs(100);

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

test "bridge_run_streaming dispatches raw stdout chunks" {
    // Helper emits 32 KB of cycling bytes (0x00..0xFF repeating). The
    // reader ships each pipe-read result verbatim. Assert that the total
    // byte count survives the round-trip — exact chunk count depends on
    // pipe scheduling so we only check the sum.
    stream_test.reset();
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"exe\":");
    try std.json.Stringify.value(helper_path, .{}, &aw.writer);
    try aw.writer.writeAll(
        ",\"args\":[\"stdout-binary\",\"32768\"]}",
    );
    const req = try aw.toOwnedSliceSentinel(0);
    defer testing.allocator.free(req);

    const handle = bridge_run_streaming(req.ptr, streamTestOnStdout, streamTestOnStderr, streamTestOnExit);
    try testing.expect(handle > 0);
    try testing.expect(stream_test.waitForExit(5 * std.time.ns_per_s));
    try testing.expectEqual(@as(i32, 0), stream_test.exit_code);
    try testing.expectEqual(@as(usize, 32768), stream_test.stdout_total);
    // Each chunk arrives independently, so we expect at least 2 batches
    // for a 32 KB payload through an 8 KB reader buffer. Upper bound left
    // loose for kernel scheduling jitter.
    try testing.expect(stream_test.batch_count >= 2);
}

// ── bridge_ack / backpressure tests ─────────────────────────────────────

test "bridge_ack with unknown handle returns -1" {
    const rc = bridge_ack(999_999_999);
    try testing.expectEqual(@as(i32, -1), rc);
}

test "bridge_ack succeeds for active stream" {
    stream_test.reset();
    // Long-running child so the handle is still registered when we ack.
    const req = try buildHelperRequestZ(&.{ "sleep", "30" });
    defer testing.allocator.free(req);
    const handle = bridge_run_streaming(req.ptr, streamTestOnStdout, streamTestOnStderr, streamTestOnExit);
    try testing.expect(handle > 0);

    // Extra ack is harmless (just inflates the permit count) — useful
    // for catching a future regression that gates on permit == 0.
    try testing.expectEqual(@as(i32, 0), bridge_ack(handle));

    _ = bridge_cancel(handle);
    try testing.expect(stream_test.waitForExit(5 * std.time.ns_per_s));
}

// ── bridge_eval_expr tests ──────────────────────────────────────────────
//
// Direct calls into the export — no helper binary needed because the
// new-style FFI family is stateless and in-process.

test "bridge_eval_expr returns 0 for empty input" {
    var buf: [256]u8 = undefined;
    // text_ptr value doesn't matter when text_len == 0 (never dereferenced);
    // use the same buffer to satisfy the [*]const u8 parameter type.
    const n = bridge_eval_expr(&buf, 0, &buf, buf.len);
    try testing.expectEqual(@as(i32, 0), n);
}

test "bridge_eval_expr returns 0 for valid expression" {
    const text: []const u8 = "IF(1 = 1, 'yes', 'no')";
    var buf: [256]u8 = undefined;
    const n = bridge_eval_expr(text.ptr, @intCast(text.len), &buf, buf.len);
    try testing.expectEqual(@as(i32, 0), n);
}

test "bridge_eval_expr returns 0 for column reference (empty context)" {
    // [Field] references resolve to "" in --expr mode (empty col_index);
    // comparison with empty string is valid syntax → success.
    const text: []const u8 = "IF([Action] = 'Buy', 'B', 'S')";
    var buf: [256]u8 = undefined;
    const n = bridge_eval_expr(text.ptr, @intCast(text.len), &buf, buf.len);
    try testing.expectEqual(@as(i32, 0), n);
}

test "bridge_eval_expr returns JSON error for syntax error" {
    // Unterminated function call.
    const text: []const u8 = "IF(";
    var buf: [1024]u8 = undefined;
    const n = bridge_eval_expr(text.ptr, @intCast(text.len), &buf, buf.len);
    try testing.expect(n > 0);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        buf[0..@intCast(n)],
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    const err_field = parsed.value.object.get("error") orelse return error.MissingErrorField;
    try testing.expect(err_field == .string);
    try testing.expect(err_field.string.len > 0);
}

test "bridge_eval_expr returns JSON with off/len for unknown function" {
    // Parser pins the offending token span for UnknownFunction so the
    // GUI can highlight it inline.
    const text: []const u8 = "DOESNOTEXIST(1)";
    var buf: [1024]u8 = undefined;
    const n = bridge_eval_expr(text.ptr, @intCast(text.len), &buf, buf.len);
    try testing.expect(n > 0);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        buf[0..@intCast(n)],
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try testing.expect(parsed.value.object.contains("error"));
    // off + len present when parser pinned the offending token.
    try testing.expect(parsed.value.object.contains("off"));
    try testing.expect(parsed.value.object.contains("len"));
    const len_field = parsed.value.object.get("len").?;
    try testing.expect(len_field == .integer);
    try testing.expect(len_field.integer > 0);
}

test "bridge_eval_expr returns BUF_TOO_SMALL when out_buf insufficient" {
    // Force an error path (so JSON gets written) with a tiny out_buf.
    const text: []const u8 = "BAD@SYNTAX";
    var buf: [4]u8 = undefined;
    const n = bridge_eval_expr(text.ptr, @intCast(text.len), &buf, buf.len);
    try testing.expectEqual(@as(i32, -2), n);
}

// ── bridge_eval_expr_trace tests ────────────────────────────────────────

test "bridge_eval_expr_trace returns 0 for empty input" {
    var buf: [256]u8 = undefined;
    const n = bridge_eval_expr_trace(&buf, 0, &buf, 0, &buf, 0, &buf, buf.len);
    try testing.expectEqual(@as(i32, 0), n);
}

test "bridge_eval_expr_trace emits per-call trace + final sentinel" {
    // Helpers shared across trace tests below.
    const Helper = struct {
        fn countLines(out: []const u8) usize {
            var n: usize = 0;
            for (out) |c| if (c == '\n') {
                n += 1;
            };
            return n;
        }
    };
    const text: []const u8 = "ABS(0 - 5)";
    var buf: [1024]u8 = undefined;
    const n = bridge_eval_expr_trace(text.ptr, @intCast(text.len), &buf, 0, &buf, 0, &buf, buf.len);
    try testing.expect(n > 0);
    const out = buf[0..@intCast(n)];
    // Expect at least one per-call line (ABS) plus the {"t":"final"} sentinel.
    try testing.expect(Helper.countLines(out) >= 2);
    try testing.expect(std.mem.indexOf(u8, out, "\"fn\":\"ABS\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"t\":\"final\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"value\":\"5\"") != null);
}

test "bridge_eval_expr_trace resolves column references via headers/fields" {
    const text: []const u8 = "IF([Action] = 'Buy', 'B', 'S')";
    const headers: []const u8 = "[\"Action\",\"Qty\"]";
    const fields: []const u8 = "[\"Buy\",\"100\"]";
    var buf: [1024]u8 = undefined;
    const n = bridge_eval_expr_trace(
        text.ptr,
        @intCast(text.len),
        headers.ptr,
        @intCast(headers.len),
        fields.ptr,
        @intCast(fields.len),
        &buf,
        buf.len,
    );
    try testing.expect(n > 0);
    const out = buf[0..@intCast(n)];
    // Should resolve [Action] = "Buy" → 'B' branch
    try testing.expect(std.mem.indexOf(u8, out, "\"value\":\"B\"") != null);
}

test "bridge_eval_expr_trace tolerates ragged headers/fields (matches engine)" {
    // Ragged lengths used to be INVALID_INPUT; inspect.evalTrace tolerates them
    // like the runtime engine (field access is by header→index; a missing index
    // yields "") so a trailing-delimiter CSV row doesn't blank the trace.
    const text: []const u8 = "ABS(-2)";
    const headers: []const u8 = "[\"A\",\"B\"]";
    const fields: []const u8 = "[\"only-one\"]";
    var buf: [256]u8 = undefined;
    const n = bridge_eval_expr_trace(
        text.ptr,
        @intCast(text.len),
        headers.ptr,
        @intCast(headers.len),
        fields.ptr,
        @intCast(fields.len),
        &buf,
        buf.len,
    );
    try testing.expect(n > 0);
    try testing.expect(std.mem.indexOf(u8, buf[0..@intCast(n)], "\"t\":\"final\"") != null);
}

test "bridge_eval_expr_trace returns INVALID_INPUT on non-array JSON" {
    const text: []const u8 = "ABS(1)";
    const headers: []const u8 = "{\"not\":\"array\"}";
    const fields: []const u8 = "[]";
    var buf: [256]u8 = undefined;
    const n = bridge_eval_expr_trace(
        text.ptr,
        @intCast(text.len),
        headers.ptr,
        @intCast(headers.len),
        fields.ptr,
        @intCast(fields.len),
        &buf,
        buf.len,
    );
    try testing.expectEqual(@as(i32, -3), n);
}

test "bridge_eval_expr_trace emits error sentinel on eval failure" {
    // Unknown function should produce an error sentinel after any trace
    // lines emitted up to the failure point.
    const text: []const u8 = "DOESNOTEXIST(1)";
    var buf: [1024]u8 = undefined;
    const n = bridge_eval_expr_trace(text.ptr, @intCast(text.len), &buf, 0, &buf, 0, &buf, buf.len);
    try testing.expect(n > 0);
    const out = buf[0..@intCast(n)];
    try testing.expect(std.mem.indexOf(u8, out, "\"t\":\"error\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"error\":\"UnknownFunction\"") != null);
}

test "bridge_eval_expr_trace returns BUF_TOO_SMALL when payload exceeds out_size" {
    const text: []const u8 = "ABS(0 - 5)";
    var buf: [4]u8 = undefined;
    const n = bridge_eval_expr_trace(text.ptr, @intCast(text.len), &buf, 0, &buf, 0, &buf, buf.len);
    try testing.expectEqual(@as(i32, -2), n);
}

test "bridge_eval_expr error JSON matches Dart parser shape" {
    // BxpProcessClient.validateExpr reads `error`, `detail`, `off`, `len`
    // from the JSON map. Lock the shape in a test so future refactors
    // can't silently break the Dart consumer.
    const text: []const u8 = "DOESNOTEXIST(1)";
    var buf: [1024]u8 = undefined;
    const n = bridge_eval_expr(text.ptr, @intCast(text.len), &buf, buf.len);
    try testing.expect(n > 0);
    const ShapeMirror = struct {
        @"error": []const u8,
        detail: []const u8,
        off: ?i64 = null,
        len: ?i64 = null,
    };
    const parsed = try std.json.parseFromSlice(
        ShapeMirror,
        testing.allocator,
        buf[0..@intCast(n)],
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try testing.expect(parsed.value.@"error".len > 0);
}

test "bridge_inspect docs returns the language/schema JSON" {
    const req: []const u8 = "{\"op\":\"docs\"}";
    var buf: [256 * 1024]u8 = undefined;
    const n = bridge_inspect(req.ptr, @intCast(req.len), &buf, buf.len);
    try testing.expect(n > 0);
    const payload = buf[0..@intCast(n)];
    try testing.expect(std.mem.indexOf(u8, payload, "\"functions\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"config_schema\"") != null);
}

test "bridge_inspect eval_batch evaluates exprs against a row" {
    const req: []const u8 =
        "{\"op\":\"eval_batch\",\"request\":{\"headers\":[\"P\"],\"fields\":[\"7\"],\"exprs\":[\"[P]\",\"BADFN()\"]}}";
    var buf: [4096]u8 = undefined;
    const n = bridge_inspect(req.ptr, @intCast(req.len), &buf, buf.len);
    try testing.expect(n > 0);
    const payload = buf[0..@intCast(n)];
    try testing.expect(std.mem.indexOf(u8, payload, "\"value\":\"7\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"ok\":false") != null);
}

test "bridge_inspect rejects unknown op and bad request" {
    var buf: [256]u8 = undefined;
    const bad_op: []const u8 = "{\"op\":\"nope\"}";
    try testing.expectEqual(@as(i32, -3), bridge_inspect(bad_op.ptr, @intCast(bad_op.len), &buf, buf.len));
    const not_obj: []const u8 = "[1,2,3]";
    try testing.expectEqual(@as(i32, -3), bridge_inspect(not_obj.ptr, @intCast(not_obj.len), &buf, buf.len));
    const missing_path: []const u8 = "{\"op\":\"config\"}";
    try testing.expectEqual(@as(i32, -3), bridge_inspect(missing_path.ptr, @intCast(missing_path.len), &buf, buf.len));
}

test "bridge_inspect BUF_TOO_SMALL when docs exceeds out_size" {
    const req: []const u8 = "{\"op\":\"docs\"}";
    var tiny: [16]u8 = undefined;
    try testing.expectEqual(@as(i32, -2), bridge_inspect(req.ptr, @intCast(req.len), &tiny, tiny.len));
}
