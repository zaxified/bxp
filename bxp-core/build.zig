const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sunrise_dep = b.dependency("sunrise", .{ .target = target, .optimize = optimize });
    const sunrise_mod = sunrise_dep.module("sunrise");

    // json5 is used internally by config — export it and wire it in.
    const json5_mod = b.addModule("json5", .{
        .root_source_file = b.path("src/json5.zig"),
    });

    _ = b.addModule("csv", .{
        .root_source_file = b.path("src/csv.zig"),
    });

    _ = b.addModule("json", .{
        .root_source_file = b.path("src/json.zig"),
    });

    _ = b.addModule("xlsx", .{
        .root_source_file = b.path("src/xlsx.zig"),
    });

    _ = b.addModule("expr", .{
        .root_source_file = b.path("src/expr.zig"),
        .imports = &.{
            .{ .name = "sunrise", .module = sunrise_mod },
        },
    });

    // config.zig uses @import("json5.zig") — the import name must match.
    _ = b.addModule("config", .{
        .root_source_file = b.path("src/config.zig"),
        .imports = &.{
            .{ .name = "json5.zig", .module = json5_mod },
        },
    });

    // -------------------------------------------------------------------------
    // Unit tests
    // -------------------------------------------------------------------------
    const csv_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/csv.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
        }),
    });

    const expr_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/expr.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
            .imports = &.{
                .{ .name = "sunrise", .module = sunrise_mod },
            },
        }),
    });

    const json5_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/json5.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
        }),
    });

    const test_step = b.step("test", "Run bxp-core unit tests");
    test_step.dependOn(&b.addRunArtifact(csv_tests).step);
    test_step.dependOn(&b.addRunArtifact(expr_tests).step);
    test_step.dependOn(&b.addRunArtifact(json5_tests).step);
}
