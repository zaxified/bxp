const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Zig 0.16 retired the Debug→ReleaseSafe rewrite this build used to carry:
    // the 0.15.2 Debug-mode x86-64 codegen bug (broken regalloc for
    // `mem.Allocator.remap` / `json.Scanner.next`, NULL deref at offset 0x30
    // under streaming load) was a backend defect, and 0.16's self-hosted x86
    // backend does not reproduce it. Debug now builds as Debug again.
    const optimize = b.standardOptimizeOption(.{});

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
    // minisign: the signature format behind `bridge_verify_minisign` (the
    // updater's authenticity check on the release SHA256SUMS). Comes from
    // zig-libs, but through bxp-core's module table rather than a second
    // `zig_libs` fetch dep here — bxp-core owns the single pin, so the bridge
    // cannot end up on a different upstream commit than the rest of the tree.
    const minisign_mod = bxp_core.module("minisign");
    // procrun: the reap-race-tolerant wait (`waitTolerant` / `ensureChildReaping`)
    // this file's spawn paths need to survive the Dart VM's `wait4(-1)` reaper.
    // Same route and same reason as `minisign` — bxp-core holds the one pin.
    const procrun_mod = bxp_core.module("procrun");

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
            .link_libc = true,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "inspect", .module = inspect_mod },
                .{ .name = "minisign", .module = minisign_mod },
                .{ .name = "procrun", .module = procrun_mod },
            },
        }),
    });

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
            .link_libc = true,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "test_options", .module = test_options.createModule() },
                .{ .name = "inspect", .module = inspect_mod },
                .{ .name = "minisign", .module = minisign_mod },
                .{ .name = "procrun", .module = procrun_mod },
            },
        }),
    });
    tests.step.dependOn(&helper.step);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run bridge unit tests");
    test_step.dependOn(&run_tests.step);
}
