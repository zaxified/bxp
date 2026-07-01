const std = @import("std");

// Throwaway build-time tool: parses the IANA tzdata TZif files (via std.Tz)
// and emits bxp-core/src/tz_data.zig — a compact, committed table of per-zone
// UTC-offset transitions (>= 1970) plus each zone's POSIX-TZ footer rule for
// dates past the last explicit transition. The generated file IS the pin
// (record the tzdata version in its header); regenerate on a tzdata bump.
// Never distributed.
//
//   zig build run                         # default paths
//   zig build run -- <out.zig> <zoneinfo> # explicit
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "tz-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run = b.addRunArtifact(exe);
    if (b.args) |a| run.addArgs(a);
    b.step("run", "Generate bxp-core/src/tz_data.zig from IANA tzdata").dependOn(&run.step);
}
