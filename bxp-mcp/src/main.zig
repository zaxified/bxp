// bxp-mcp — entry point
//
// An MCP server (JSON-RPC 2.0 over stdio) exposing bxp's stateless surface as
// agent-callable tools: bxp_validate / bxp_eval / bxp_eval_batch /
// bxp_eval_trace / bxp_docs / bxp_list_templates / bxp_fetch_template
// (stateless, in-process via bxp-core's `inspect` module) plus bxp_simulate
// (a full conversion — spawns the co-located bxp-cli; see sim.zig).
//
// Register with an MCP client (e.g. Claude Code, ~/.claude.json):
//   "mcpServers": { "bxp": { "command": "/path/to/bxp-mcp", "args": [] } }

const std = @import("std");
const server = @import("server.zig");

pub fn main() void {
    // Base arena over page_allocator: one mmap up front, bump allocation after.
    // Holds only startup (argv) + the server's persistent reused buffers. Each
    // request's transient allocations go through a separate per-request arena
    // that `server.run` resets after every request (see server.zig Session).
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
                \\Speaks MCP on stdin/stdout. Tools: bxp_validate, bxp_eval,
                \\bxp_eval_batch, bxp_eval_trace, bxp_docs, bxp_list_templates,
                \\bxp_fetch_template, bxp_simulate. Register with an MCP client
                \\via "command": "bxp-mcp".
                \\
            ;
            _ = std.fs.File.stdout().write(msg) catch 0;
            return;
        }
    }

    server.run(arena.allocator());
}
