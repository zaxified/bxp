// bxp-mcp — entry point
//
// An MCP server (JSON-RPC 2.0 over stdio) exposing bxp's stateless surface as
// agent-callable tools: bxp_validate / bxp_eval / bxp_docs. Calls the shared
// bxp-core `fmtcore` module in-process — no subprocess spawn.
//
// Register with an MCP client (e.g. Claude Code, ~/.claude.json):
//   "mcpServers": { "bxp": { "command": "/path/to/bxp-mcp", "args": [] } }

const std = @import("std");
const server = @import("server.zig");

pub fn main() void {
    // Arena over page_allocator: one mmap up front, bump allocation after.
    // The server is long-lived but each request's transient allocations are
    // bounded; a future refactor can reset a per-request arena (see CLAUDE.md).
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var args = std.process.argsWithAllocator(arena.allocator()) catch {
        std.process.exit(1);
    };
    _ = args.skip();
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            const msg =
                \\bxp-mcp — MCP server (JSON-RPC 2.0 over stdio)
                \\
                \\Speaks MCP on stdin/stdout. Tools: bxp_validate, bxp_eval, bxp_docs.
                \\Register with an MCP client via "command": "bxp-mcp".
                \\
            ;
            _ = std.fs.File.stdout().write(msg) catch 0;
            return;
        }
    }

    server.run(arena.allocator());
}
