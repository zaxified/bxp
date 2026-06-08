// bxp-mcp — minimal MCP server (JSON-RPC 2.0 over stdio)
//
// Newline-delimited JSON: every write to stdout is exactly one JSON object
// followed by one \n. Handles initialize / tools/list / tools/call / ping.
// No roots / logging / progress yet (see CLAUDE.md TODO).
//
// Pure std: each incoming line is parsed with std.json; ids and tool text are
// re-serialized with std.json.Stringify. No third-party code.

const std = @import("std");
const tools = @import("tools.zig");

pub const PROTOCOL_VERSION = "2025-06-18";

const INITIALIZE_RESULT =
    \\{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"bxp-mcp","title":"bxp-mcp","version":"0.0.1"},"instructions":"bxp-mcp: validate bxp-cli configs (bxp_validate), evaluate bxp expressions (bxp_eval), and fetch the bxp language docs (bxp_docs). Call bxp_docs first to learn the expression/config language."}
;

const Session = struct {
    alloc: std.mem.Allocator,
    stdout: std.fs.File,
    line_buf: std.ArrayList(u8) = .empty,
    out_buf: std.ArrayList(u8) = .empty,
    tool_buf: std.ArrayList(u8) = .empty,

    fn deinit(self: *Session) void {
        self.line_buf.deinit(self.alloc);
        self.out_buf.deinit(self.alloc);
        self.tool_buf.deinit(self.alloc);
    }
};

pub fn run(alloc: std.mem.Allocator) void {
    var session: Session = .{
        .alloc = alloc,
        .stdout = std.fs.File.stdout(),
    };
    defer session.deinit();

    var read_buf: [64 * 1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&read_buf);
    const reader = &stdin_reader.interface;

    while (readLine(alloc, reader, &session.line_buf)) |line| {
        handleLine(&session, line);
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

    const parsed = std.json.parseFromSlice(std.json.Value, s.alloc, input, .{}) catch {
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

    if (eql(method, "initialize")) {
        writeResultRaw(s, id, INITIALIZE_RESULT);
    } else if (eql(method, "tools/list")) {
        writeResultRaw(s, id, tools.tools_list);
    } else if (eql(method, "ping")) {
        writeResultRaw(s, id, "{}");
    } else if (eql(method, "notifications/initialized")) {
        // fire-and-forget
    } else if (eql(method, "tools/call")) {
        handleCall(s, id, obj.get("params"));
    } else if (id != null) {
        writeError(s, id, -32601, "Method not found");
    }
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

    s.tool_buf.clearRetainingCapacity();
    tools.dispatch(s.alloc, tool, args, &s.tool_buf);
    writeToolResult(s, id, s.tool_buf.items);
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

fn writeToolResult(s: *Session, id: ?std.json.Value, text: []const u8) void {
    const alloc = s.alloc;
    const buf = &s.out_buf;
    buf.clearRetainingCapacity();
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendId(s, buf, id);
    buf.appendSlice(alloc, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":") catch return;
    appendJsonString(s, buf, text);
    buf.appendSlice(alloc, "}],\"isError\":false}}\n") catch return;
    _ = s.stdout.write(buf.items) catch 0;
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
fn appendId(s: *Session, buf: *std.ArrayList(u8), id: ?std.json.Value) void {
    const alloc = s.alloc;
    if (id) |v| {
        const txt = std.json.Stringify.valueAlloc(alloc, v, .{}) catch {
            buf.appendSlice(alloc, "null") catch {};
            return;
        };
        defer alloc.free(txt);
        buf.appendSlice(alloc, txt) catch {};
    } else {
        buf.appendSlice(alloc, "null") catch {};
    }
}

/// Append `text` as a properly escaped JSON string (including the quotes).
fn appendJsonString(s: *Session, buf: *std.ArrayList(u8), text: []const u8) void {
    const alloc = s.alloc;
    const quoted = std.json.Stringify.valueAlloc(alloc, text, .{}) catch {
        buf.appendSlice(alloc, "\"\"") catch {};
        return;
    };
    defer alloc.free(quoted);
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
