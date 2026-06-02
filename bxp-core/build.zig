const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // json5 is used internally by config — export it and wire it in.
    const json5_mod = b.addModule("json5", .{
        .root_source_file = b.path("src/json5.zig"),
    });

    // Structured diagnostic sink consumed by bxp-fmt's deep validation
    // pass. config/expr/json5 modules accept an optional pointer to it
    // so bxp-cli (which passes null) is unaffected.
    const diagnostics_mod = b.addModule("diagnostics", .{
        .root_source_file = b.path("src/diagnostics.zig"),
    });

    _ = b.addModule("csv", .{
        .root_source_file = b.path("src/csv.zig"),
    });

    _ = b.addModule("json", .{
        .root_source_file = b.path("src/json.zig"),
    });

    _ = b.addModule("btrace", .{
        .root_source_file = b.path("src/btrace.zig"),
    });

    _ = b.addModule("xlsx", .{
        .root_source_file = b.path("src/xlsx.zig"),
    });

    // expr.zig pulls in its date core via a file-relative @import("datefmt.zig"),
    // so no named module wiring is needed for it.
    const expr_mod = b.addModule("expr", .{
        .root_source_file = b.path("src/expr.zig"),
    });

    // config.zig uses @import("json5.zig") — the import name must match.
    const config_mod = b.addModule("config", .{
        .root_source_file = b.path("src/config.zig"),
        .imports = &.{
            .{ .name = "json5.zig", .module = json5_mod },
            .{ .name = "diagnostics", .module = diagnostics_mod },
            .{ .name = "expr", .module = expr_mod },
        },
    });

    // docs.zig aggregates the expression catalog (re-exported live from
    // expr.zig) and the config schema (per-struct `pub const fields`
    // tables co-located in config.zig). Consumed by bxp-fmt --docs.
    _ = b.addModule("docs", .{
        .root_source_file = b.path("src/docs.zig"),
        .imports = &.{
            .{ .name = "config", .module = config_mod },
            .{ .name = "expr",   .module = expr_mod },
            .{ .name = "json5",  .module = json5_mod },
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

    const json_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/json.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
        }),
    });

    const btrace_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/btrace.zig"),
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
        }),
    });

    const datefmt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/datefmt.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
        }),
    });

    // decimal.zig is the fixed-point numeric core; expr.zig pulls it in via a
    // file-relative @import (like datefmt.zig), so no named module is needed —
    // only the standalone test artifact.
    const decimal_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/decimal.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
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

    const diagnostics_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/diagnostics.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
        }),
    });

    const xlsx_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/xlsx.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
        }),
    });

    // config.zig uses @import("json5.zig") — the test module's import name
    // must match the production module wiring above.
    const config_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/config.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
            .imports = &.{
                .{ .name = "json5.zig",   .module = json5_mod },
                .{ .name = "diagnostics", .module = diagnostics_mod },
                .{ .name = "expr",        .module = expr_mod },
            },
        }),
    });

    const docs_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/docs.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
            .imports = &.{
                .{ .name = "config", .module = config_mod },
                .{ .name = "expr",   .module = expr_mod },
                .{ .name = "json5",  .module = json5_mod },
            },
        }),
    });

    const test_step = b.step("test", "Run bxp-core unit tests");
    test_step.dependOn(&b.addRunArtifact(csv_tests).step);
    test_step.dependOn(&b.addRunArtifact(json_tests).step);
    test_step.dependOn(&b.addRunArtifact(btrace_tests).step);
    test_step.dependOn(&b.addRunArtifact(expr_tests).step);
    test_step.dependOn(&b.addRunArtifact(datefmt_tests).step);
    test_step.dependOn(&b.addRunArtifact(decimal_tests).step);
    test_step.dependOn(&b.addRunArtifact(json5_tests).step);
    test_step.dependOn(&b.addRunArtifact(diagnostics_tests).step);
    test_step.dependOn(&b.addRunArtifact(xlsx_tests).step);
    test_step.dependOn(&b.addRunArtifact(config_tests).step);
    test_step.dependOn(&b.addRunArtifact(docs_tests).step);
}
