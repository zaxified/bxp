const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Default a bare `zig build` to ReleaseSafe, not Debug. (`preferred_optimize_mode`
    // does NOT do this — it only applies under `--release`; a plain `zig build`
    // would still be Debug.) Reasons:
    //   * Profiling footgun: a plain `zig build` (e.g. inside scripts/test-01)
    //     used to leave a Debug binary at zig-out/bin/bxp-cli — 10-50× slower,
    //     and its Debug DebugAllocator serialises the parallel workers, which
    //     once looked like a hang on large inputs. ReleaseSafe is fast yet keeps
    //     runtime safety (UB / bounds / overflow → panic, not silent garbage).
    //   * Shipping is unaffected: scripts/release.sh passes -Doptimize=ReleaseSmall
    //     explicitly (the -Doptimize form overrides this). Use -Doptimize=Debug
    //     when you need a debugger.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSafe;

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
                .{ .name = "csvstream",     .module = core_dep.module("csvstream") },
                .{ .name = "config",        .module = core_dep.module("config") },
                .{ .name = "expr",          .module = core_dep.module("expr") },
                .{ .name = "xlsx",          .module = core_dep.module("xlsx") },
                .{ .name = "zipstream",     .module = core_dep.module("zipstream") },
                .{ .name = "json",          .module = core_dep.module("json") },
                .{ .name = "btrace",        .module = core_dep.module("btrace") },
                .{ .name = "json5",         .module = core_dep.module("json5") },
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

    // The flag / exit-code catalog (src/cli_docs.zig) is exported as a module so
    // the central docs generator (tools/zig-doc-gen) can render it. Pure data, no
    // deps — the consumer pays nothing it doesn't reference.
    _ = b.addModule("cli_docs", .{ .root_source_file = b.path("src/cli_docs.zig") });

    // The processing engine is exported as a module for the same reason, but it
    // is not pure data: the docs generator renders `SectionStats` into the
    // architecture class diagram off `@typeInfo`, and that struct lives here
    // next to the loop that fills it rather than in a data file of its own.
    // Imports mirror the executable's wiring above minus `build_options`, which
    // only main.zig reads.
    _ = b.addModule("pipeline", .{
        .root_source_file = b.path("src/pipeline.zig"),
        .imports = &.{
            .{ .name = "csvstream",   .module = core_dep.module("csvstream") },
            .{ .name = "config",      .module = core_dep.module("config") },
            .{ .name = "expr",        .module = core_dep.module("expr") },
            .{ .name = "xlsx",        .module = core_dep.module("xlsx") },
            .{ .name = "zipstream",   .module = core_dep.module("zipstream") },
            .{ .name = "json",        .module = core_dep.module("json") },
            .{ .name = "btrace",      .module = core_dep.module("btrace") },
        },
    });

    // Inline tests live in src/main.zig (validatePath, matchValueArg) and
    // src/pipeline.zig (writeSafeValue). main.zig is the test root; it
    // @imports pipeline.zig, so the latter's tests are discovered too.
    // bxp-core has its own `zig build test`; scripts/test.sh runs both.
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
            .imports = &.{
                .{ .name = "csvstream",     .module = core_dep.module("csvstream") },
                .{ .name = "config",        .module = core_dep.module("config") },
                .{ .name = "expr",          .module = core_dep.module("expr") },
                .{ .name = "xlsx",          .module = core_dep.module("xlsx") },
                .{ .name = "zipstream",     .module = core_dep.module("zipstream") },
                .{ .name = "json",          .module = core_dep.module("json") },
                .{ .name = "btrace",        .module = core_dep.module("btrace") },
                .{ .name = "json5",         .module = core_dep.module("json5") },
                .{ .name = "diagnostics",   .module = core_dep.module("diagnostics") },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });

    const test_step = b.step("test", "Run bxp-cli unit tests");
    test_step.dependOn(&b.addRunArtifact(main_tests).step);
}
