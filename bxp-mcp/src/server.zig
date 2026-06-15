// bxp-mcp — minimal MCP server (JSON-RPC 2.0 over stdio)
//
// Newline-delimited JSON: every write to stdout is exactly one JSON object
// followed by one \n. Handles initialize / tools/list / tools/call / ping, plus
// server→client notifications/progress (opt-in via params._meta.progressToken).
// Request-only methods are answered only when an `id` is present; an id-less
// line for them is a stray notification and gets no response.
//
// Pure std: each incoming line is parsed with std.json; ids and tool text are
// re-serialized with std.json.Stringify. No third-party code.

const std = @import("std");
const tools = @import("tools.zig");
const Progress = @import("progress.zig").Progress;
const build_options = @import("build_options");

/// Latest MCP protocol revision we advertise. Older revisions we also accept
/// (and echo back) are listed in `SUPPORTED_VERSIONS`.
pub const PROTOCOL_VERSION = "2025-11-25";

/// Revisions the server is compatible with — our tool surface is identical
/// across them. On `initialize` we echo the client's requested version when it
/// is one of these (spec requirement), otherwise we answer with the latest
/// (`PROTOCOL_VERSION`).
const SUPPORTED_VERSIONS = [_][]const u8{ "2025-11-25", "2025-06-18" };

// The initialize result, assembled from three constant fragments around two
// runtime splices: the negotiated protocol version (so a client asking for
// 2025-06-18 gets it back) and `serverInfo.version`. The latter is the manifest
// version from `build_options.version` (single source — same value `--version`
// prints), NOT a hardcoded literal that would silently drift each release.
const INITIALIZE_PREFIX = "{\"protocolVersion\":\"";
const INITIALIZE_MID =
    \\","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"bxp-mcp","title":"bxp-mcp","version":"
;
const INITIALIZE_SUFFIX =
    \\"},"instructions":"bxp-mcp: validate bxp-cli configs (bxp_validate), evaluate one (bxp_eval) or many (bxp_eval_batch) bxp expressions, trace one expression's per-call evaluation (bxp_eval_trace), list/fetch conversion templates (bxp_list_templates, bxp_fetch_template), run a full conversion end-to-end against sample CSV (bxp_simulate), and fetch the bxp language docs (bxp_docs). Call bxp_docs first to learn the expression/config language; use bxp_eval_trace to debug an expression and bxp_simulate to verify a finished config for real."}
;

/// Pick the protocol version to answer with: the client's requested one if we
/// support it, else our latest. `requested` is null when the client omits it.
fn negotiateVersion(requested: ?[]const u8) []const u8 {
    if (requested) |req| {
        for (SUPPORTED_VERSIONS) |v| {
            if (std.mem.eql(u8, v, req)) return req;
        }
    }
    return PROTOCOL_VERSION;
}

const Session = struct {
    /// Base allocator: persistent, reused-across-requests buffers live here
    /// (they keep capacity via clearRetainingCapacity, so they don't grow
    /// unbounded). Never reset.
    alloc: std.mem.Allocator,
    /// Per-request arena: every transient allocation for one request (the
    /// incoming JSON parse, the tool dispatch, response-serialization temps)
    /// goes here and is freed wholesale after the response is written. Without
    /// this a long-lived server leaks one request's allocations per call into
    /// the process arena. `retain_capacity` keeps the backing pages so the
    /// arena reaches a steady state sized to the largest single request.
    req_arena: std.heap.ArenaAllocator,
    stdout: std.fs.File,
    line_buf: std.ArrayList(u8) = .empty,
    out_buf: std.ArrayList(u8) = .empty,

    /// Allocator for this request's transient work — reset after each request.
    fn reqAlloc(self: *Session) std.mem.Allocator {
        return self.req_arena.allocator();
    }

    fn deinit(self: *Session) void {
        self.line_buf.deinit(self.alloc);
        self.out_buf.deinit(self.alloc);
        self.req_arena.deinit();
    }
};

pub fn run(alloc: std.mem.Allocator) void {
    var session: Session = .{
        .alloc = alloc,
        .req_arena = std.heap.ArenaAllocator.init(alloc),
        .stdout = std.fs.File.stdout(),
    };
    defer session.deinit();

    var read_buf: [64 * 1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&read_buf);
    const reader = &stdin_reader.interface;

    while (readLine(alloc, reader, &session.line_buf)) |line| {
        handleLine(&session, line);
        // The full response is already written to stdout by handleLine; the
        // request's transient allocations are now dead.
        _ = session.req_arena.reset(.retain_capacity);
    }
}

/// Read one newline-terminated line into the reusable buffer (grows as needed,
/// so a tools/call line carrying a large config is handled). Returns the line
/// slice (without '\n'), or null at EOF.
fn readLine(alloc: std.mem.Allocator, reader: *std.Io.Reader, buf: *std.ArrayList(u8)) ?[]u8 {
    buf.clearRetainingCapacity();
    while (true) {
        const byte = reader.takeByte() catch {
            if (buf.items.len == 0) return null;
            return buf.items;
        };
        if (byte == '\n') return buf.items;
        buf.append(alloc, byte) catch return null;
    }
}

fn handleLine(s: *Session, line: []u8) void {
    const input = std.mem.trim(u8, line, " \t\r");
    if (input.len == 0) return;

    const parsed = std.json.parseFromSlice(std.json.Value, s.reqAlloc(), input, .{}) catch {
        writeError(s, null, -32700, "Parse error");
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        writeError(s, null, -32600, "Invalid request");
        return;
    }
    const obj = parsed.value.object;
    const id: ?std.json.Value = obj.get("id"); // absent => notification, no response

    const method_v = obj.get("method") orelse {
        if (id != null) writeError(s, id, -32600, "Missing method");
        return;
    };
    if (method_v != .string) {
        if (id != null) writeError(s, id, -32600, "Invalid method");
        return;
    }
    const method = method_v.string;

    // A request (has `id`) gets exactly one response; a notification (no `id`)
    // must get none. `notifications/initialized` is the only method we accept
    // without an id — every other id-less line is a stray notification we drop.
    if (eql(method, "notifications/initialized")) {
        // fire-and-forget
    } else if (id == null) {
        // notification for a request-only method: ignore, never respond.
    } else if (eql(method, "initialize")) {
        handleInitialize(s, id, obj.get("params"));
    } else if (eql(method, "tools/list")) {
        writeResultRaw(s, id, tools.tools_list);
    } else if (eql(method, "ping")) {
        writeResultRaw(s, id, "{}");
    } else if (eql(method, "tools/call")) {
        handleCall(s, id, obj.get("params"));
    } else {
        writeError(s, id, -32601, "Method not found");
    }
}

fn handleInitialize(s: *Session, id: ?std.json.Value, params_opt: ?std.json.Value) void {
    // Extract the client's requested protocolVersion (if any) and echo it back
    // when supported; otherwise answer with our latest.
    var requested: ?[]const u8 = null;
    if (params_opt) |params| {
        if (params == .object) {
            if (params.object.get("protocolVersion")) |pv| {
                if (pv == .string) requested = pv.string;
            }
        }
    }
    const version = negotiateVersion(requested);
    const result = std.fmt.allocPrint(s.reqAlloc(), "{s}{s}{s}{s}{s}", .{
        INITIALIZE_PREFIX, version, INITIALIZE_MID, build_options.version, INITIALIZE_SUFFIX,
    }) catch {
        writeError(s, id, -32603, "Internal error");
        return;
    };
    writeResultRaw(s, id, result);
}

fn handleCall(s: *Session, id: ?std.json.Value, params_opt: ?std.json.Value) void {
    const params = params_opt orelse {
        writeError(s, id, -32602, "Missing params");
        return;
    };
    if (params != .object) {
        writeError(s, id, -32602, "Invalid params");
        return;
    }
    const name_v = params.object.get("name") orelse {
        writeError(s, id, -32602, "Missing tool name");
        return;
    };
    if (name_v != .string) {
        writeError(s, id, -32602, "Invalid tool name");
        return;
    }
    const tool = tools.parse(name_v.string) orelse {
        writeError(s, id, -32602, "Unknown tool");
        return;
    };

    const args: std.json.Value = params.object.get("arguments") orelse .null;

    // MCP progress: a `params._meta.progressToken` opts the call into
    // server→client `notifications/progress`. Serialize the token verbatim
    // (string or number) so the reporter can echo it on every notification.
    const prog: ?Progress = blk: {
        const meta = params.object.get("_meta") orelse break :blk null;
        if (meta != .object) break :blk null;
        const token = meta.object.get("progressToken") orelse break :blk null;
        if (token != .string and token != .integer) break :blk null;
        const token_json = std.json.Stringify.valueAlloc(s.reqAlloc(), token, .{}) catch break :blk null;
        break :blk Progress{ .stdout = s.stdout, .token_json = token_json };
    };

    // A fresh per-request buffer on the request arena — NOT a persistent
    // reused one. A retained-capacity buffer would keep pointers into arena
    // memory that the next request's JSON parse reuses, so a later tool call
    // could alias its own output over the live request (observed corrupting a
    // second bxp_simulate's report). The arena reset reclaims this each turn.
    var tool_buf: std.ArrayList(u8) = .empty;
    const is_error = tools.dispatch(s.reqAlloc(), tool, args, prog, &tool_buf);
    writeToolResult(s, id, tool_buf.items, tools.allowsStructured(tool), is_error);
}

// ── JSON-RPC writers ───────────────────────────────────────────────────────

fn writeResultRaw(s: *Session, id: ?std.json.Value, result: []const u8) void {
    const alloc = s.alloc;
    const buf = &s.out_buf;
    buf.clearRetainingCapacity();
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendId(s, buf, id);
    buf.appendSlice(alloc, ",\"result\":") catch return;
    appendStrippingNewlines(alloc, buf, result);
    buf.appendSlice(alloc, "}\n") catch return;
    _ = s.stdout.write(buf.items) catch 0;
}

fn writeToolResult(s: *Session, id: ?std.json.Value, text: []const u8, allow_structured: bool, is_error: bool) void {
    const alloc = s.alloc;
    const buf = &s.out_buf;
    buf.clearRetainingCapacity();
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendId(s, buf, id);
    buf.appendSlice(alloc, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":") catch return;
    appendJsonString(s, buf, text);
    buf.appendSlice(alloc, "}]") catch return;
    // MCP 2025-06-18+ structuredContent: when the tool's output is a single JSON
    // object, hand it back parsed so the agent doesn't re-parse the text blob.
    // Gated on the tool's declared shape (`allow_structured`) — an NDJSON tool
    // stays text-only even when a trivial input yields one object — and on a
    // structural re-check so an error/text blob never emits invalid structure.
    if (allow_structured and isSingleJsonObject(text)) {
        buf.appendSlice(alloc, ",\"structuredContent\":") catch return;
        appendStrippingNewlines(alloc, buf, text);
    }
    // isError:true marks a tool failure (missing arg, unexpected error) so the
    // agent notices; a domain `{"ok":false}` answer keeps isError:false.
    buf.appendSlice(alloc, if (is_error) ",\"isError\":true}}\n" else ",\"isError\":false}}\n") catch return;
    _ = s.stdout.write(buf.items) catch 0;
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// True when `text` is exactly one top-level JSON object (`{ … }`) followed by
/// nothing but whitespace — the only shape MCP `structuredContent` accepts.
/// Brace-matches with string/escape awareness so NDJSON (e.g. `bxp_eval_trace`,
/// many `{…}` lines) and bare arrays are correctly rejected, not concatenated
/// into invalid JSON by the later newline-strip.
fn isSingleJsonObject(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len and isWs(text[i])) : (i += 1) {}
    if (i >= text.len or text[i] != '{') return false;

    var depth: usize = 0;
    var in_str = false;
    var escaped = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_str) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{', '[' => depth += 1,
            '}', ']' => {
                if (depth == 0) return false; // unbalanced
                depth -= 1;
                if (depth == 0) {
                    // top-level value closed: the remainder must be whitespace.
                    i += 1;
                    while (i < text.len) : (i += 1) {
                        if (!isWs(text[i])) return false;
                    }
                    return true;
                }
            },
            else => {},
        }
    }
    return false; // unterminated
}

fn writeError(s: *Session, id: ?std.json.Value, code: i32, msg: []const u8) void {
    const alloc = s.alloc;
    const buf = &s.out_buf;
    buf.clearRetainingCapacity();
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendId(s, buf, id);
    buf.appendSlice(alloc, ",\"error\":{\"code\":") catch return;
    var tmp: [12]u8 = undefined;
    const cs = std.fmt.bufPrint(&tmp, "{d}", .{code}) catch return;
    buf.appendSlice(alloc, cs) catch return;
    buf.appendSlice(alloc, ",\"message\":") catch return;
    appendJsonString(s, buf, msg);
    buf.appendSlice(alloc, "}}\n") catch return;
    _ = s.stdout.write(buf.items) catch 0;
}

/// Append the request id verbatim (re-serialized from its parsed Value, so an
/// integer stays an integer and a string keeps its quotes). Null => `null`.
/// `buf` (the persistent out-buffer) grows on the base allocator; the temporary
/// serialization buffer comes from the per-request arena (freed on reset).
fn appendId(s: *Session, buf: *std.ArrayList(u8), id: ?std.json.Value) void {
    const alloc = s.alloc;
    if (id) |v| {
        const txt = std.json.Stringify.valueAlloc(s.reqAlloc(), v, .{}) catch {
            buf.appendSlice(alloc, "null") catch {};
            return;
        };
        buf.appendSlice(alloc, txt) catch {};
    } else {
        buf.appendSlice(alloc, "null") catch {};
    }
}

/// Append `text` as a properly escaped JSON string (including the quotes).
fn appendJsonString(s: *Session, buf: *std.ArrayList(u8), text: []const u8) void {
    const alloc = s.alloc;
    const quoted = std.json.Stringify.valueAlloc(s.reqAlloc(), text, .{}) catch {
        buf.appendSlice(alloc, "\"\"") catch {};
        return;
    };
    buf.appendSlice(alloc, quoted) catch {};
}

/// Append `data` to `buf`, skipping raw \n and \r so a multi-line raw JSON
/// literal never breaks the one-object-per-line invariant.
fn appendStrippingNewlines(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), data: []const u8) void {
    var i: usize = 0;
    while (i < data.len) {
        const start = i;
        while (i < data.len and data[i] != '\n' and data[i] != '\r') : (i += 1) {}
        if (i > start) buf.appendSlice(alloc, data[start..i]) catch return;
        if (i < data.len) i += 1;
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
