const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Force-upgrade Debug to ReleaseSafe. Zig 0.15.2 Debug-mode codegen
    // produces broken register allocation for `mem.Allocator.remap` and
    // `json.Scanner.next` on x86-64 — both surface as a NULL deref at
    // offset 0x30 when the bridge's reader thread and `bridge_eval_expr_trace`
    // run under realistic streaming load (137 K rows from `bxp-cli --trace`
    // against DEV/bxp-cli.json). The bug does not reproduce in ReleaseSafe
    // (same runtime safety checks: overflow, bounds, null-deref asserts;
    // different codegen path). Release builds from
    // `scripts/release-02-desktop.sh` already use `-Doptimize=ReleaseSmall`,
    // so production artefacts have never tripped this; only the dev flow
    // (`flutter run` → CMake hook copies whatever is in `zig-out/lib`) was
    // affected. `-Doptimize=ReleaseSmall|ReleaseFast` still selects those
    // modes; only Debug is rewritten to ReleaseSafe.
    const requested_optimize = b.standardOptimizeOption(.{});
    const optimize: std.builtin.OptimizeMode = switch (requested_optimize) {
        .Debug => .ReleaseSafe,
        else => requested_optimize,
    };

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    // bxp-core: shared library with the actual expression evaluator,
    // config parser, etc. The bridge calls into it directly for in-process
    // operations (e.g. `bridge_eval_expr`) so the Dart GUI can avoid the
    // ~50 ms spawn cost of `inspect.validateExpr` per keystroke.
    const bxp_core = b.dependency("bxp_core", .{ .target = target, .optimize = optimize });
    // inspect: the shared stateless core (validate/eval/eval-trace/docs/templates)
    // also wrapped by bxp-mcp, so the bridge's in-proc paths share
    // one implementation instead of hand-rolling their own. (inspect pulls in
    // expr transitively, so the bridge no longer imports expr directly.)
    const inspect_mod = bxp_core.module("inspect");

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
                .{ .name = "inspect", .module = inspect_mod },
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
                .{ .name = "inspect", .module = inspect_mod },
            },
        }),
    });
    tests.linkLibC();
    tests.step.dependOn(&helper.step);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run bridge unit tests");
    test_step.dependOn(&run_tests.step);
}
