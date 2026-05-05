const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_dep = b.dependency("bxp_core", .{ .target = target, .optimize = optimize });

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    const exe = b.addExecutable(.{
        .name = "bxp-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "csv",           .module = core_dep.module("csv") },
                .{ .name = "config",        .module = core_dep.module("config") },
                .{ .name = "expr",          .module = core_dep.module("expr") },
                .{ .name = "xlsx",          .module = core_dep.module("xlsx") },
                .{ .name = "json",          .module = core_dep.module("json") },
                .{ .name = "diagnostics",   .module = core_dep.module("diagnostics") },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run Broker eXchange Parser");
    run_step.dependOn(&run_cmd.step);

    // Unit tests live in bxp-core. Run "zig build test" there, or use scripts/test.sh.
    _ = b.step("test", "Run unit tests (delegates to bxp-core; use scripts/test.sh)");
}
