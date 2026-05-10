const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    // Shared library: bxp-gui-bridge.dll on Windows, libbxp-gui-bridge.so
    // on Linux, libbxp-gui-bridge.dylib on macOS. Loaded at runtime by
    // bxp-gui via DartFFI's DynamicLibrary.open().
    const lib = b.addLibrary(.{
        .name = "bxp-gui-bridge",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    lib.linkLibC();

    b.installArtifact(lib);

    // `zig build test` — exercises the FFI surface (writeResponse / writeErr,
    // bridge_run, bridge_run_streaming + bridge_cancel) by spawning a small
    // helper binary built alongside the tests. Using a helper instead of
    // OS binaries (`/bin/true`, `/bin/echo`, `/bin/sleep`) is the Zig
    // analogue of Go's "re-exec" pattern: the child is real but its
    // behaviour is fully controlled by the test, so the suite is identical
    // on Linux / macOS / Windows. Helper sources live in `test/`; the
    // resulting binary is NOT installed (it never reaches release archives).
    const helper = b.addExecutable(.{
        .name = "bridge-test-helper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/test_helper.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_options = b.addOptions();
    test_options.addOptionPath("test_helper_path", helper.getEmittedBin());

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "test_options", .module = test_options.createModule() },
            },
        }),
    });
    tests.linkLibC();
    tests.step.dependOn(&helper.step);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run bridge unit tests");
    test_step.dependOn(&run_tests.step);
}
