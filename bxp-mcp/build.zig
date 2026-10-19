const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Self-hosted backend only on request, for the edit loop: every build and
    // test step here compiles with LLVM (~/.claude/zig-backend.md; tiers in
    // .claude/rules/zig-pitfalls.md). A no-op in the release modes.
    const selfhosted = b.option(bool, "selfhosted", "Use Zig's self-hosted backend (edit loop only)") orelse false;
    const use_llvm: ?bool = if (selfhosted) null else true;

    const core_dep = b.dependency("bxp_core", .{ .target = target, .optimize = optimize });

    // Mirror bxp-cli: surface the manifest version to `--version` via a
    // generated build_options module (kept in lockstep at release time).
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    const exe = b.addExecutable(.{
        .name = "bxp-mcp",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "inspect",       .module = core_dep.module("inspect") },
                .{ .name = "btrace",        .module = core_dep.module("btrace") },
                .{ .name = "mcp",           .module = core_dep.module("mcp") },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the bxp-mcp server");
    run_step.dependOn(&run_cmd.step);

    // Export the tool catalog (tools.zig) as a module so tools/zig-doc-gen can
    // render mcp-tools.md from `tool_docs`. The generator references only the
    // catalog data; the handlers (which call inspect/sim/mcp) stay unreferenced
    // and are never compiled into it. `mcp` is listed anyway — lazy analysis is
    // what keeps the handlers out, and an import table that matches the file's
    // actual @imports means a future eager reference fails to build here rather
    // than in the docs generator.
    _ = b.addModule("tools", .{
        .root_source_file = b.path("src/tools.zig"),
        .imports = &.{
            .{ .name = "inspect", .module = core_dep.module("inspect") },
            .{ .name = "mcp",     .module = core_dep.module("mcp") },
        },
    });

    // Unit tests over the same source tree (picks up inline tests in
    // sim.zig/tools.zig reachable from main.zig).
    const exe_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "inspect",       .module = core_dep.module("inspect") },
                .{ .name = "btrace",        .module = core_dep.module("btrace") },
                .{ .name = "mcp",           .module = core_dep.module("mcp") },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run bxp-mcp unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
