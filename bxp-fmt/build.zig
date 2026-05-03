const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_dep = b.dependency("bxp_core", .{ .target = target, .optimize = optimize });

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    const exe = b.addExecutable(.{
        .name = "bxp-fmt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "config",        .module = core_dep.module("config") },
                .{ .name = "expr",          .module = core_dep.module("expr") },
                .{ .name = "json5",         .module = core_dep.module("json5") },
                .{ .name = "docs",          .module = core_dep.module("docs") },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run bxp-fmt");
    run_step.dependOn(&run_cmd.step);

    // Inline tests live in src/main.zig (annotateConfigFromFile + …).
    // Replaces the shell-driven `Annotated JSON regression` phase that
    // used to live in scripts/test.sh + datasets/_annotated_fixtures/.
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
            .imports = &.{
                .{ .name = "config",        .module = core_dep.module("config") },
                .{ .name = "expr",          .module = core_dep.module("expr") },
                .{ .name = "json5",         .module = core_dep.module("json5") },
                .{ .name = "docs",          .module = core_dep.module("docs") },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });

    const test_step = b.step("test", "Run bxp-fmt unit tests");
    test_step.dependOn(&b.addRunArtifact(main_tests).step);
}
