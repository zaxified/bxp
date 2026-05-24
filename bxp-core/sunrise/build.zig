const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create sunrise module (can be obtained externally with `dependency.module("sunrise")`)
    const mod = b.addModule("sunrise", .{
        .root_source_file = b.path("src/sunrise.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create test executable for datetime_test.zig
    const datetime_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/datetime_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    datetime_test_module.addImport("sunrise", mod);

    const datetime_tests = b.addTest(.{
        .root_module = datetime_test_module,
    });

    // A run step that will run the datetime test executable.
    const run_datetime_tests = b.addRunArtifact(datetime_tests);

    // A top level step for running all tests.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_datetime_tests.step);
}
