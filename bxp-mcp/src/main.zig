// bxp-mcp — entry point
//
// An MCP server (JSON-RPC 2.0 over stdio) exposing bxp's stateless surface as
// agent-callable tools: bxp_validate / bxp_validate_expr / bxp_eval /
// bxp_eval_batch / bxp_eval_trace / bxp_docs / bxp_list_templates /
// bxp_fetch_template (stateless, in-process via bxp-core's `inspect` module)
// plus bxp_simulate (a full conversion — spawns the co-located bxp-cli; see
// sim.zig).
//
// Register with an MCP client (e.g. Claude Code, ~/.claude.json):
//   "mcpServers": { "bxp": { "command": "/path/to/bxp-mcp", "args": [] } }

const std = @import("std");
const server = @import("server.zig");
const tools = @import("tools.zig");
const build_options = @import("build_options");

/// One documented CLI flag — same shape as bxp-cli's `FlagDoc`, so a single
/// walker can render either binary's flags uniformly. Co-located with the arg
/// parsing in `main` below; `arg` is the value placeholder ("" = takes no value).
const FlagDoc = struct {
    flag: []const u8,
    arg: []const u8 = "",
    description: []const u8,
};

const flags = [_]FlagDoc{
    .{ .flag = "--version", .description = "print version and exit" },
    .{ .flag = "--help", .description = "print this help and exit (also -h)" },
};

/// Write a short message to stdout (Zig 0.16: stdout access goes through `Io`).
fn writeStdout(io: std.Io, msg: []const u8) void {
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    fw.interface.writeAll(msg) catch {};
    fw.interface.flush() catch {};
}

pub fn main(init: std.process.Init) void {
    const io = init.io;

    // Base arena over page_allocator: one mmap up front, bump allocation after.
    // Holds only startup (argv) + the server's persistent reused buffers. Each
    // request's transient allocations go through a separate per-request arena
    // that `server.run` resets after every request (see server.zig Session).
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Zig 0.16: `std.process.argsWithAllocator` is gone; iterate `Init`'s args.
    var args = std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa) catch {
        std.process.exit(1);
    };
    defer args.deinit();
    _ = args.skip();
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            // Same "<name> <version>\n" shape bxp-cli prints, so the GUI's
            // getVersion() (bridge_run <bin> --version) parses it identically.
            // Without this, `--version` would fall through to server.run() and
            // block reading stdin as an MCP server until the caller times out.
            var buf: [64]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "bxp-mcp {s}\n", .{build_options.version}) catch "bxp-mcp\n";
            writeStdout(io, line);
            return;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            // Both lists render from catalogs (no hand-written prose): Options
            // from `flags`, Tools from `tools.tool_docs` (the same source behind
            // `tools/list`), so --help can't drift from either.
            const SPACES = " " ** 24;
            var buf: [2048]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            w.writeAll(
                \\bxp-mcp — MCP server (JSON-RPC 2.0 over stdio)
                \\
                \\Speaks MCP on stdin/stdout. Register with an MCP client via
                \\"command": "bxp-mcp". Send tools/list for the full schemas.
                \\
                \\Options:
                \\
            ) catch {};
            for (flags) |f| {
                var lbuf: [48]u8 = undefined;
                const label = if (f.arg.len > 0)
                    std.fmt.bufPrint(&lbuf, "{s} {s}", .{ f.flag, f.arg }) catch f.flag
                else
                    f.flag;
                const fill = if (label.len < 13) 13 - label.len else 1;
                w.print("  {s}{s}{s}\n", .{ label, SPACES[0..fill], f.description }) catch {};
            }
            w.writeAll("\nTools:\n") catch {};
            for (tools.tool_docs) |t| w.print("  {s}\n", .{t.name}) catch {};
            writeStdout(io, w.buffered());
            return;
        }
    }

    server.run(io, init.environ_map, arena.allocator());
}
