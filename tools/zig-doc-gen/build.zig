const std = @import("std");

// Throwaway build-time tool: it sits ABOVE every bxp package (depends on them,
// nobody depends on it), so it can import every Zig `*Doc` catalog without an
// upward-import cycle and render all reference Markdown pages in one place.
// Never distributed; the binary can be discarded after a run.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Self-hosted backend only on request, for the edit loop: every build and
    // test step here compiles with LLVM (~/.claude/zig-backend.md; tiers in
    // .claude/rules/zig-pitfalls.md). A no-op in the release modes.
    const selfhosted = b.option(bool, "selfhosted", "Use Zig's self-hosted backend (edit loop only)") orelse false;
    const use_llvm: ?bool = if (selfhosted) null else true;

    const core = b.dependency("bxp_core", .{ .target = target, .optimize = optimize });
    const cli = b.dependency("bxp_cli", .{ .target = target, .optimize = optimize });
    const mcp = b.dependency("bxp_mcp", .{ .target = target, .optimize = optimize });
    const bridge = b.dependency("bxp_gui_bridge", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "zig-doc-gen",
        .use_llvm = use_llvm,
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
                // The class-diagram page is rendered from `@typeInfo` over the
                // live types, so the generator links the modules that define
                // them rather than a catalog describing them.
                .{ .name = "expr", .module = core.module("expr") },
                .{ .name = "xlsx", .module = core.module("xlsx") },
                .{ .name = "btrace", .module = core.module("btrace") },
                .{ .name = "diagnostics", .module = core.module("diagnostics") },
                .{ .name = "pipeline", .module = cli.module("pipeline") },
                // Architecture catalogs: the bxp-core module inventory + the
                // inspect surface, and the bridge's C-ABI surface.
                .{ .name = "module_docs", .module = core.module("module_docs") },
                .{ .name = "bridge_ops", .module = bridge.module("ops") },
            },
        }),
    });


    const run = b.addRunArtifact(exe);
    // Output dir: first CLI argument, else BXP_DOCS_OUT, else ../../docs (the
    // tool decides). Override: zig build run -- <dir>
    run.addPassthruArgs();
    b.step("run", "Generate all Zig-catalog reference Markdown pages").dependOn(&run.step);
}
