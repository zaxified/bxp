// bxp-mcp — MCP progress notifications (server→client)
//
// A long-running tool (today only bxp_simulate) emits `notifications/progress`
// while it works, so an agent sees lifecycle phases instead of one silent
// blocking call. Per the MCP spec a notification is only sent when the caller
// supplied a `progressToken` in the request's `params._meta` — when absent the
// reporter is null and nothing is written.
//
// Notifications and the eventual tool result share the server's stdout; each is
// one complete JSON object on its own line, so interleaving is safe (the
// progress lines precede the result line because the tool runs before the
// server serializes its response).

const std = @import("std");

pub const Progress = struct {
    /// Io for stdout access (Zig 0.16 — `std.fs.File` writes go through `Io`).
    io: std.Io,
    /// The server's stdout — same handle the JSON-RPC responses use.
    stdout: std.Io.File,
    /// The client's progressToken, already serialized to JSON text (a quoted
    /// string like `"abc"` or a bare number like `42`), embedded verbatim.
    token_json: []const u8,

    /// Emit one `notifications/progress`. `message` must be plain ASCII without
    /// `"`/`\` (we use only static literals); progress/total are step counters.
    /// Best-effort: a formatting or write failure is silently dropped — a missed
    /// progress note must never derail the tool run.
    pub fn report(self: Progress, progress: u32, total: u32, message: []const u8) void {
        var buf: [1024]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buf,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{{\"progressToken\":{s},\"progress\":{d},\"total\":{d},\"message\":\"{s}\"}}}}\n",
            .{ self.token_json, progress, total, message },
        ) catch return;
        self.stdout.writeStreamingAll(self.io, line) catch {};
    }
};

/// Convenience: call `.report` only when a reporter is present.
pub fn report(p: ?Progress, progress: u32, total: u32, message: []const u8) void {
    if (p) |r| r.report(progress, total, message);
}
