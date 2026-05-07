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
}
