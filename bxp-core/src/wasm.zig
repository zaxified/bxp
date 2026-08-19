//! wasm32 export wrapper around the stateless inspect core.
//!
//! POC scope (tier A of the docs playground): the single entry point is
//! `inspect.evalBatch` — the same surface bxp-mcp's `bxp_eval_batch` tool and
//! the bridge's `bridge_inspect {op:eval_batch}` already drive. This makes the
//! browser a FOURTH consumer of one engine, not a reimplementation: the docs
//! playground and the CLI agree because they run the same `expr.zig`.
//!
//! ABI, deliberately minimal (wasm32 pointers are u32, so nothing needs
//! 64-bit marshalling in the JS glue):
//!
//!   bxp_input_alloc(len) -> ptr    reserve a request buffer; JS writes UTF-8
//!                                  JSON into it, then calls eval
//!   bxp_eval_batch(len)  -> 0|1    0 = response JSON, 1 = plain-text error
//!   bxp_docs()           -> 0|1    the language catalog as JSON
//!   bxp_result_ptr()     -> ptr    every outcome lands in the same slot
//!   bxp_result_len()     -> len
//!
//! The result slice stays valid until the next call into this module: each
//! entry point resets one shared arena, so the caller must copy the bytes out
//! before invoking again. Everything is arena-bounded — there is no per-call free
//! for JS to remember.

const std = @import("std");
const inspect = @import("inspect");

const backing = std.heap.wasm_allocator;

/// Request buffer owned by this module; JS fills it between the alloc and the
/// eval call. Freed and re-allocated per request rather than grown in place —
/// a docs widget sends kilobytes, so churn is irrelevant next to the clarity.
var input_buf: []u8 = &.{};

/// Per-call arena. `evalBatch` allocates the parsed request, every duped
/// string and the response JSON out of it; resetting between calls is the
/// whole memory management story.
var arena_state = std.heap.ArenaAllocator.init(backing);

var result: []const u8 = "";

// ── browser io ────────────────────────────────────────────────────────────────
// `std.Io.Threaded` does not compile for wasm32-freestanding, and `.failing`
// would silently degrade two builtins the docs are allowed to demonstrate:
// NOW() would report 1970 and RAND() would error. Neither is acceptable in a
// playground whose entire promise is "this is the same engine the CLI runs".
//
// The expression evaluator only ever asks io for two things — a wall clock
// (NOW) and CSPRNG entropy (RAND) — so the fix is to take `.failing` as the
// base and replace exactly those two vtable entries with JS imports. Every
// other operation stays failing, which is correct: a browser page has no
// filesystem, no network and no threads to offer, and nothing on the eval path
// reaches for them.

extern "env" fn js_now_ms() f64;
extern "env" fn js_random_bytes(ptr: [*]u8, len: usize) void;

fn browserNow(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
    _ = userdata;
    _ = clock;
    // Date.now() is milliseconds since the Unix epoch — the same origin
    // `.real` means natively. The monotonic clocks share it: page-local
    // durations are not something an expression can observe.
    return .{ .nanoseconds = @as(i96, @intFromFloat(js_now_ms())) * std.time.ns_per_ms };
}

fn browserRandomSecure(userdata: ?*anyopaque, buffer: []u8) std.Io.RandomSecureError!void {
    _ = userdata;
    js_random_bytes(buffer.ptr, buffer.len);
}

const browser_vtable: std.Io.VTable = vt: {
    var vt = std.Io.failing.vtable.*;
    vt.now = browserNow;
    vt.randomSecure = browserRandomSecure;
    break :vt vt;
};

const browser_io: std.Io = .{ .userdata = null, .vtable = &browser_vtable };

/// Reserve `len` bytes for the next request body and hand JS the pointer.
/// Returns null on OOM so the glue can report it rather than write out of
/// bounds into linear memory.
export fn bxp_input_alloc(len: usize) ?[*]u8 {
    if (input_buf.len != 0) backing.free(input_buf);
    input_buf = backing.alloc(u8, len) catch {
        input_buf = &.{};
        return null;
    };
    return input_buf.ptr;
}

/// Evaluate the batch request now sitting in the first `len` bytes of the
/// input buffer. Returns 0 when `bxp_result_*` holds response JSON, 1 when it
/// holds a plain-text error message.
///
/// Mirrors `evalBatch`'s own contract: a well-formed request is exit 0 even if
/// individual expressions fail, because each result carries its own `ok` flag.
/// Only a malformed request — or unparseable JSON — comes back as 1.
export fn bxp_eval_batch(len: usize) i32 {
    if (len > input_buf.len) return fail("request length exceeds the allocated input buffer");
    _ = arena_state.reset(.retain_capacity);
    const a = arena_state.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, input_buf[0..len], .{}) catch |err| {
        return fail(switch (err) {
            error.OutOfMemory => "out of memory parsing the request",
            else => "request body is not valid JSON",
        });
    };

    const r = inspect.evalBatchIo(a, parsed, browser_io) catch return fail("out of memory evaluating the batch");
    if (r.error_message) |msg| {
        result = msg;
        return 1;
    }
    result = r.json;
    return 0;
}

/// Serialize the language catalog — every builtin's signature, description,
/// example, arg metadata and `needs` — into the result slot. Same
/// `inspect.docsJson` bxp-mcp's `bxp_docs` tool and the GUI bridge serve.
///
/// The playground needs one field of it today (`needs`, to explain why five
/// builtins cannot answer meaningfully without a row), and taking that from the
/// engine rather than from a blob baked into one generated page is what makes
/// the hint work on hand-written pages too. Costs ~12 KB gzipped over an
/// eval-only build; that buys the whole catalog, which is what an editor
/// affordance — completion, signature hints — would need next anyway.
export fn bxp_docs() i32 {
    _ = arena_state.reset(.retain_capacity);
    const a = arena_state.allocator();
    const json = inspect.docsJson(a) catch return fail("out of memory serializing the catalog");
    result = json;
    return 0;
}

export fn bxp_result_ptr() [*]const u8 {
    return result.ptr;
}

export fn bxp_result_len() usize {
    return result.len;
}

/// Park a static message in the result slot. Static so it survives the arena
/// reset that the next call performs.
fn fail(msg: []const u8) i32 {
    result = msg;
    return 1;
}

/// Freestanding wasm has no default panic path. Trap instead: a panic here is
/// a bug in this wrapper, and `unreachable` surfaces in the browser console as
/// a RuntimeError with a stack trace rather than silent corruption.
pub const panic = std.debug.FullPanic(wasmPanic);

fn wasmPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = msg;
    _ = first_trace_addr;
    unreachable;
}
