const std = @import("std");

// Throwaway build-time tool: it sits ABOVE every bxp package (depends on them,
// nobody depends on it), so it can import every Zig `*Doc` catalog without an
// upward-import cycle and render all reference Markdown pages in one place.
// Never distributed; the binary can be discarded after a run.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.dependency("bxp_core", .{ .target = target, .optimize = optimize });
    const cli = b.dependency("bxp_cli", .{ .target = target, .optimize = optimize });
    const mcp = b.dependency("bxp_mcp", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "zig-doc-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "docs", .module = core.module("docs") },
                // Reads resources/console/bxp-cli.examples.json so the shipped
                // template list is rendered from the config itself, not retyped.
                .{ .name = "config", .module = core.module("config") },
                .{ .name = "cli_docs", .module = cli.module("cli_docs") },
                .{ .name = "tools", .module = mcp.module("tools") },
            },
        }),
    });

    const run = b.addRunArtifact(exe);
    // Output dir via BXP_DOCS_OUT (default ../../docs/reference). Override:
    // zig build run -- <dir>
    if (b.args) |a| if (a.len > 0) run.setEnvironmentVariable("BXP_DOCS_OUT", a[0]);
    b.step("run", "Generate all Zig-catalog reference Markdown pages").dependOn(&run.step);
}
