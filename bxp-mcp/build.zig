const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_dep = b.dependency("bxp_core", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "bxp-mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "inspect", .module = core_dep.module("inspect") },
                .{ .name = "btrace", .module = core_dep.module("btrace") },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the bxp-mcp server");
    run_step.dependOn(&run_cmd.step);

    // Unit tests over the same source tree (picks up inline tests in
    // sim.zig/tools.zig reachable from main.zig).
    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "inspect", .module = core_dep.module("inspect") },
                .{ .name = "btrace", .module = core_dep.module("btrace") },
            },
        }),
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run bxp-mcp unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
