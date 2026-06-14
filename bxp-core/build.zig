const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // uucode supplies the Unicode tables behind expr.zig's text builtins:
    // UPPER/LOWER (case mapping) and UNACCENT (canonical decomposition + the
    // combining class, from which unicode.zig strips diacritics). Field-
    // selected: only these tables are generated + compiled in, keeping the
    // binary small. The dependency's own table generator runs in Debug + LLVM
    // internally (it works around the Zig x86 backend bug itself), so our
    // optimize mode only governs the thin lookup `lib` module.
    const uucode_mod = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields = @as([]const []const u8, &.{
            "uppercase_mapping",
            "lowercase_mapping",
            "decomposition_mapping",
            "decomposition_type",
            "canonical_combining_class",
        }),
    }).module("uucode");

    // json5 is used internally by config — export it and wire it in.
    const json5_mod = b.addModule("json5", .{
        .root_source_file = b.path("src/json5.zig"),
    });

    // Structured diagnostic sink consumed by the inspect core's deep validation
    // pass. config/expr/json5 modules accept an optional pointer to it
    // so bxp-cli (which passes null) is unaffected.
    const diagnostics_mod = b.addModule("diagnostics", .{
        .root_source_file = b.path("src/diagnostics.zig"),
    });

    // decimal.zig is the fixed-point numeric core shared by every input path
    // that turns a numeric string into a value: expr.zig (expression eval),
    // json.zig and xlsx.zig (input number canonicalisation). It must be a
    // single named module — file-relative @import from more than one module
    // would put the same file in multiple modules (compile error).
    const decimal_mod = b.addModule("decimal", .{
        .root_source_file = b.path("src/decimal.zig"),
    });

    // encoding.zig is the Layer 0 single-byte code page ↔ UTF-8 transcoder.
    // Shared by expr (per-field decode at read) and config (encoding key parse),
    // so — like decimal — it must be a single named module rather than a
    // file-relative @import from two modules (that would duplicate the file).
    const encoding_mod = b.addModule("encoding", .{
        .root_source_file = b.path("src/encoding.zig"),
    });

    _ = b.addModule("csv", .{
        .root_source_file = b.path("src/csv.zig"),
    });

    _ = b.addModule("json", .{
        .root_source_file = b.path("src/json.zig"),
        .imports = &.{
            .{ .name = "decimal", .module = decimal_mod },
        },
    });

    _ = b.addModule("btrace", .{
        .root_source_file = b.path("src/btrace.zig"),
    });

    // zipstream.zig is the streaming ZIP-entry reader (central-dir walk +
    // per-entry inflate). A named module so both xlsx.zig (XML parts) and the
    // future bxp-cli zipped-CSV pre-pass can consume it without duplicating the
    // file into two modules.
    const zipstream_mod = b.addModule("zipstream", .{
        .root_source_file = b.path("src/zipstream.zig"),
    });

    const xlsx_mod = b.addModule("xlsx", .{
        .root_source_file = b.path("src/xlsx.zig"),
        .imports = &.{
            .{ .name = "decimal", .module = decimal_mod },
            .{ .name = "zipstream", .module = zipstream_mod },
        },
    });

    // expr.zig pulls in its date core via a file-relative @import("datefmt.zig"),
    // and the shared decimal numeric core via the named "decimal" module.
    const expr_mod = b.addModule("expr", .{
        .root_source_file = b.path("src/expr.zig"),
        .imports = &.{
            .{ .name = "decimal", .module = decimal_mod },
            .{ .name = "uucode", .module = uucode_mod },
            .{ .name = "encoding", .module = encoding_mod },
        },
    });

    // config.zig uses @import("json5.zig") — the import name must match.
    const config_mod = b.addModule("config", .{
        .root_source_file = b.path("src/config.zig"),
        .imports = &.{
            .{ .name = "json5.zig", .module = json5_mod },
            .{ .name = "diagnostics", .module = diagnostics_mod },
            .{ .name = "expr", .module = expr_mod },
            .{ .name = "encoding", .module = encoding_mod },
            .{ .name = "xlsx", .module = xlsx_mod },
        },
    });

    // docs.zig aggregates the expression catalog (re-exported live from
    // expr.zig) and the config schema (per-struct `pub const fields`
    // tables co-located in config.zig). Consumed by inspect.docsJson.
    const docs_mod = b.addModule("docs", .{
        .root_source_file = b.path("src/docs.zig"),
        .imports = &.{
            .{ .name = "config", .module = config_mod },
            .{ .name = "expr",   .module = expr_mod },
            .{ .name = "json5",  .module = json5_mod },
        },
    });

    // inspect.zig is the shared stateless inspection core (config validation,
    // docs serialization, single-expression eval) behind both bxp-mcp (MCP
    // server adapter) and the bxp-gui-bridge FFI. "One core, thin adapters".
    _ = b.addModule("inspect", .{
        .root_source_file = b.path("src/inspect.zig"),
        .imports = &.{
            .{ .name = "config",      .module = config_mod },
            .{ .name = "expr",        .module = expr_mod },
            .{ .name = "json5",       .module = json5_mod },
            .{ .name = "docs",        .module = docs_mod },
            .{ .name = "diagnostics", .module = diagnostics_mod },
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
            .imports = &.{
                .{ .name = "decimal", .module = decimal_mod },
            },
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
            .imports = &.{
                .{ .name = "decimal", .module = decimal_mod },
                .{ .name = "uucode", .module = uucode_mod },
                .{ .name = "encoding", .module = encoding_mod },
            },
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

    const unicode_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unicode.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
            .imports = &.{
                .{ .name = "uucode", .module = uucode_mod },
            },
        }),
    });

    // decimal.zig is the fixed-point numeric core, wired as the named "decimal"
    // module above (shared by expr/json/xlsx). This is its standalone test
    // artifact — the file is both a module root and a test root, same as json5.
    const decimal_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/decimal.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
        }),
    });

    // encoding.zig is the single-byte code page transcoder, wired as the named
    // "encoding" module above (shared by expr/config). Standalone test artifact.
    const encoding_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/encoding.zig"),
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

    const zipstream_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zipstream.zig"),
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
            .imports = &.{
                .{ .name = "decimal", .module = decimal_mod },
                .{ .name = "zipstream", .module = zipstream_mod },
            },
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
                .{ .name = "encoding",    .module = encoding_mod },
                .{ .name = "xlsx",        .module = xlsx_mod },
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

    // inspect.zig is both a module root and a test root. Its tests (config
    // annotation Phases A–G8 + expr-batch) used to live in bxp-fmt/src/main.zig;
    // they moved here when bxp-fmt was deleted, since they exercise the shared
    // inspect core, not the CLI adapter. Imports mirror the inspect module above.
    const inspect_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/inspect.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
            .imports = &.{
                .{ .name = "config",      .module = config_mod },
                .{ .name = "expr",        .module = expr_mod },
                .{ .name = "json5",       .module = json5_mod },
                .{ .name = "docs",        .module = docs_mod },
                .{ .name = "diagnostics", .module = diagnostics_mod },
            },
        }),
    });

    const test_step = b.step("test", "Run bxp-core unit tests");
    test_step.dependOn(&b.addRunArtifact(csv_tests).step);
    test_step.dependOn(&b.addRunArtifact(json_tests).step);
    test_step.dependOn(&b.addRunArtifact(btrace_tests).step);
    test_step.dependOn(&b.addRunArtifact(expr_tests).step);
    test_step.dependOn(&b.addRunArtifact(datefmt_tests).step);
    test_step.dependOn(&b.addRunArtifact(unicode_tests).step);
    test_step.dependOn(&b.addRunArtifact(decimal_tests).step);
    test_step.dependOn(&b.addRunArtifact(encoding_tests).step);
    test_step.dependOn(&b.addRunArtifact(json5_tests).step);
    test_step.dependOn(&b.addRunArtifact(diagnostics_tests).step);
    test_step.dependOn(&b.addRunArtifact(zipstream_tests).step);
    test_step.dependOn(&b.addRunArtifact(xlsx_tests).step);
    test_step.dependOn(&b.addRunArtifact(config_tests).step);
    test_step.dependOn(&b.addRunArtifact(docs_tests).step);
    test_step.dependOn(&b.addRunArtifact(inspect_tests).step);
}
