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

    // zig-libs carries the hardened descendants of several modules that used to
    // live in src/. Every module taken from it must come off THIS one handle:
    // they import each other (`tz` imports `datefmt`), and a second
    // `b.dependency` call would compile a second, separate copy of the shared
    // ones. Foreign upstream — read-only, pinned in build.zig.zon.
    const zig_libs = b.dependency("zig_libs", .{
        .target = target,
        .optimize = optimize,
    });

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

    // Layer 0 single-byte code page ↔ UTF-8 transcoder, consumed from zig-libs
    // for the same reason as tz/datefmt: the local src/encoding.zig was lifted
    // into that repo and hardened there (normative WHATWG/Unicode.org index
    // vectors, a codec fuzz harness, three audit-found edge cases), and the
    // upstream copy is a strict superset — the five 256-entry mapping tables
    // and both transcode entry points are byte-identical. bxp keeps the CSV-edge
    // policy that drives it: `csv_input_encoding` / `csv_output_encoding` in
    // config.zig and the per-field decode in expr.zig.
    const encoding_mod = zig_libs.module("encoding");

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

    // regex engine (quangd/regex.zig) behind expr.zig's REGEX_MATCH /
    // REGEX_EXTRACT builtins — a pinned fetch dependency (zero transitive deps,
    // Pike-VM linear-time; security-audited 2026-06-17, see build.zig.zon). The
    // upstream package exposes its engine as the module named "regex".
    const regex_mod = b.dependency("regex", .{
        .target = target,
        .optimize = optimize,
    }).module("regex");

    // IANA time-zone offset lookup behind TO_UTC / TZ_OFFSET / TZ_CONVERT /
    // IS_DST. Consumed from the zig-libs collection (pinned in build.zig.zon)
    // rather than kept in-tree: the local src/tz.zig + generated src/tz_data.zig
    // were lifted into that repo and hardened there (fuzz harnesses, security
    // audit, the Jn/n POSIX rule forms this copy never had), so the upstream
    // module is strictly ahead. The offset tables ship inside it, so there is
    // still no runtime dependency — the data is compiled in, same as before.
    const tz_mod = zig_libs.module("tz");

    // Date core behind DATE_CONVERT and every calendar builtin (YEAR / DATEADD /
    // WORKDAY / EOMONTH / …). Consumed from zig-libs for the same reason as `tz`:
    // the local src/datefmt.zig was lifted into that repo and hardened there, and
    // the upstream copy is a strict superset — identical civil core, parser,
    // formatter and token table, plus extra coverage and an `xsd:dateTime` entry
    // point bxp does not call. Taking it from the SAME `b.dependency` handle as
    // `tz` is what collapses the two date cores that used to compile in (`tz`
    // imports upstream `datefmt`; the local copy was a second, separate one).
    const datefmt_mod = zig_libs.module("datefmt");

    // expr.zig pulls its date core in as the named "datefmt" module and the
    // shared decimal numeric core as the named "decimal" module.
    const expr_mod = b.addModule("expr", .{
        .root_source_file = b.path("src/expr.zig"),
        .imports = &.{
            .{ .name = "decimal", .module = decimal_mod },
            .{ .name = "uucode", .module = uucode_mod },
            .{ .name = "encoding", .module = encoding_mod },
            .{ .name = "regex", .module = regex_mod },
            .{ .name = "tz", .module = tz_mod },
            .{ .name = "datefmt", .module = datefmt_mod },
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
                .{ .name = "regex", .module = regex_mod },
                .{ .name = "tz", .module = tz_mod },
                .{ .name = "datefmt", .module = datefmt_mod },
            },
        }),
    });

    // No tz or datefmt test root here any more: both now come from the zig-libs
    // collection, each carrying its own (larger) suite plus fuzz harnesses
    // upstream. What bxp still owns is the expr-level behaviour built on them —
    // DATE_CONVERT, the calendar builtins, TO_UTC / TZ_OFFSET / TZ_CONVERT /
    // IS_DST — covered by expr_tests and the cross-runner corpus
    // (scripts/test-06-expr-corpus.sh).

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
    test_step.dependOn(&b.addRunArtifact(unicode_tests).step);
    test_step.dependOn(&b.addRunArtifact(decimal_tests).step);
    test_step.dependOn(&b.addRunArtifact(json5_tests).step);
    test_step.dependOn(&b.addRunArtifact(diagnostics_tests).step);
    test_step.dependOn(&b.addRunArtifact(zipstream_tests).step);
    test_step.dependOn(&b.addRunArtifact(xlsx_tests).step);
    test_step.dependOn(&b.addRunArtifact(config_tests).step);
    test_step.dependOn(&b.addRunArtifact(docs_tests).step);
    test_step.dependOn(&b.addRunArtifact(inspect_tests).step);
}
