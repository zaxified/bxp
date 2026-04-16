const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_dep = b.dependency("bxp_core", .{ .target = target, .optimize = optimize });
    const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 });

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dvui",          .module = dvui_dep.module("dvui_sdl3") },
            .{ .name = "sdl-backend",   .module = dvui_dep.module("sdl3") },
            .{ .name = "config",        .module = core_dep.module("config") },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });

    const exe = b.addExecutable(.{
        .name = "bxp-gui",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run bxp-gui");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/json5_writer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "config", .module = core_dep.module("config") },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run bxp-gui unit tests");
    test_step.dependOn(&run_tests.step);
}
