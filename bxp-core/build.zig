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

    // JSON5 -> JSON preprocessor (plain + source-location annotated), consumed
    // from zig-libs. Unlike tz/datefmt/encoding this one was NOT a strict
    // subset: the local copy was an older, buggier line. Upstream gained a
    // fuzzer and the json5/json5-tests conformance corpus, which between them
    // fixed two crashes the local copy still had (an unquoted key with no ':'
    // before EOF sliced out of bounds; skipValue could return len+1 on a
    // trailing backslash inside a string) and two spec deviations it silently
    // accepted (an unterminated block comment was stripped to EOF; a lone /
    // leading comma was elided into a valid-looking empty container). Both
    // deviations are must-reject cases in that corpus. See the migration note
    // in bxp-core/CLAUDE.md -> Module details.
    const json5_mod = zig_libs.module("json5");
    reexport(b, "json5", json5_mod);

    // Structured diagnostic sink consumed by the inspect core's deep validation
    // pass. config/expr/json5 accept an optional pointer to it, so bxp-cli
    // (which passes null) is unaffected. Consumed from zig-libs: the local copy
    // was a strict subset — the collector, the `Diagnostic` fields and both
    // count methods were identical, upstream just adds three more tests. The
    // one thing the local header carried that upstream's does not is the
    // bxp-specific `$err_`/`$warn_`/`$info_` routing, which now lives next to
    // the switch that implements it in inspect.zig.
    const diagnostics_mod = zig_libs.module("diagnostics");
    reexport(b, "diagnostics", diagnostics_mod);

    // Fixed-point numeric core shared by every input path that turns a numeric
    // string into a value: expr.zig (expression eval), json.zig and xlsx.zig
    // (input number canonicalisation). Consumed from zig-libs. The arithmetic
    // is identical — same i128 @ 1e12 representation, same half-away-from-zero
    // rounding, same parse and format output — but the API is not: fallible
    // operations return `Error!Decimal` instead of `?Decimal`, and `toString`
    // writes into a caller buffer instead of allocating. That typed error set
    // is what let the div-by-zero and div-overflow cases split apart at the
    // call site in expr.zig; the local copy conflated them into one `null` and
    // `@intCast`-panicked on the overflow. See bxp-core/CLAUDE.md -> Module
    // details.
    const decimal_mod = zig_libs.module("decimal");

    // Grouped-number parser (`1,234.56` / `1.234,56`) behind expr.zig's numeric
    // coercion, its GREATEST/LEAST diagnostics and the `decimal_sep_in` locale
    // normalisation. Consumed from zig-libs: this one was extracted BELOW file
    // level — the upstream module is expr.zig's own `parseGroupedNumber`, and
    // the diff against the local copy was byte-identical code (only parameter
    // renames, `pub`, and reworded comments), plus two upstream reject-case
    // tests. It returns the same `decimal` this handle supplies, so the
    // optional-vs-error contract at the call sites is unchanged.
    const numparse_mod = zig_libs.module("numparse");

    // Minisign signature format (Ed25519 + Blake2b-512 over the
    // `untrusted comment:` / base64 framing) behind the GUI updater's
    // `bridge_verify_minisign`. bxp-core does not use it — it is re-published
    // here purely so `bxp-gui-bridge` can ask for it by name off the SAME
    // pinned zig-libs commit this package resolves. A second `zig_libs` entry
    // in the bridge's own build.zig.zon would be a second pin to bump in
    // lockstep on every upstream move; one pin, re-exported, cannot drift.
    reexport(b, "minisign", zig_libs.module("minisign"));

    // Subprocess runner whose reap-race-tolerant wait is what
    // `bxp-gui-bridge` needs around its `bxp-cli` spawns (the Dart VM's
    // `wait4(-1)` reaper would otherwise trip std's ECHILD panic). Re-exported
    // for the bridge for the same single-pin reason as `minisign`; bxp-core
    // does not use it either.
    reexport(b, "procrun", zig_libs.module("procrun"));

    // MCP server transport (JSON-RPC 2.0 + the handshake/tools dispatch over a
    // reader/writer, with a built-in stdio transport) behind `bxp-mcp`. This
    // one is a homecoming rather than an adoption: upstream's module IS this
    // repo's former `bxp-mcp/src/server.zig`, extracted 2026-07-04 and hardened
    // there (resources + prompts + sampling/elicitation, a 16 MiB line cap, 89
    // tests). bxp-core does not import it — re-exported for the same single-pin
    // reason as `minisign` and `procrun`, so bxp-mcp does not carry a second
    // `zig_libs` entry of its own.
    reexport(b, "mcp", zig_libs.module("mcp"));

    // Layer 0 single-byte code page ↔ UTF-8 transcoder, consumed from zig-libs
    // for the same reason as tz/datefmt: the local src/encoding.zig was lifted
    // into that repo and hardened there (normative WHATWG/Unicode.org index
    // vectors, a codec fuzz harness, three audit-found edge cases), and the
    // upstream copy is a strict superset — the five 256-entry mapping tables
    // and both transcode entry points are byte-identical. bxp keeps the CSV-edge
    // policy that drives it: `csv_input_encoding` / `csv_output_encoding` in
    // config.zig and the per-field decode in expr.zig.
    const encoding_mod = zig_libs.module("encoding");

    // CSV record model — `LineIterator` / `splitFields` / `LineSlice` (what
    // src/csv.zig used to be) AND `ChunkReader` (what bxp-cli's pipeline.zig
    // used to carry privately). Both were extracted upstream, so this is one
    // module where bxp had two halves. The lazy-quotes rule the whole parallel
    // pipeline rests on — a '\n' ALWAYS ends a record, deliberately not RFC
    // 4180 §2.6 — went upstream with the code and is documented there as the
    // reason every '\n' is a safe chunk boundary; the shared code diffs
    // byte-identical. Re-exported because bxp-cli asks for it by name.
    reexport(b, "csvstream", zig_libs.module("csvstream"));

    _ = b.addModule("json", .{
        .root_source_file = b.path("src/json.zig"),
        .imports = &.{
            .{ .name = "decimal", .module = decimal_mod },
        },
    });

    _ = b.addModule("btrace", .{
        .root_source_file = b.path("src/btrace.zig"),
    });

    // Streaming ZIP-entry reader (central-dir walk + per-entry inflate) behind
    // xlsx.zig's XML parts and bxp-cli's zipped-CSV pre-pass. Consumed from
    // zig-libs, which added what the local copy lacked: CRC-32 verification at
    // end-of-stream (the gap the 2026-06-14 audit recorded as a known
    // non-issue), a decompression-bomb output cap, a zip-slip name predicate,
    // and a pre-validation walk of the central directory that stops a hostile
    // `filename_len` from overflowing `std.zip.Iterator.next`'s u16 arithmetic
    // — reachable straight through `Archive.init` and a live process abort
    // before this migration. Also gains zip64 reading and an ArchiveWriter that
    // bxp does not use. See bxp-core/CLAUDE.md -> Module details.
    const zipstream_mod = zig_libs.module("zipstream");
    reexport(b, "zipstream", zipstream_mod);

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
            .{ .name = "numparse", .module = numparse_mod },
            .{ .name = "uucode", .module = uucode_mod },
            .{ .name = "encoding", .module = encoding_mod },
            .{ .name = "regex", .module = regex_mod },
            .{ .name = "tz", .module = tz_mod },
            .{ .name = "datefmt", .module = datefmt_mod },
        },
    });

    const config_mod = b.addModule("config", .{
        .root_source_file = b.path("src/config.zig"),
        .imports = &.{
            .{ .name = "json5", .module = json5_mod },
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
    const inspect_mod = b.addModule("inspect", .{
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
    // wasm32 playground artifact
    // -------------------------------------------------------------------------
    // Built by an opt-in step, never by `install`, and deliberately driven by
    // the SAME `target`/`optimize` options as everything above rather than a
    // second `b.dependency` handle pinned to wasm: the module graph is already
    // target-agnostic, so
    //
    //     zig build wasm -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
    //
    // recompiles the existing `inspect` module (and every zig-libs module under
    // it) for the browser without a parallel wiring block that could drift from
    // the native one. `entry = .disabled` + `rdynamic` produce a reactor-style
    // module: no `_start`, just the exports src/wasm.zig marks.
    const wasm_exe = b.addExecutable(.{
        .name = "bxp-eval",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "inspect", .module = inspect_mod },
            },
        }),
    });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;

    const wasm_step = b.step("wasm", "Build the wasm32 eval-batch module for the docs playground");
    wasm_step.dependOn(&b.addInstallArtifact(wasm_exe, .{}).step);

    // -------------------------------------------------------------------------
    // Unit tests
    // -------------------------------------------------------------------------
    // No csv test root here any more: the parser moved to the zig-libs
    // `csvstream` module, which carries all 22 of these tests verbatim plus
    // two fuzz harnesses, the maxogden/csv-spectrum acid-test corpus and the
    // streaming-layer suite. What bxp still owns is how the pipeline drives
    // it — covered by the datasets gate (test-07) and the expression corpus.

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
                .{ .name = "numparse", .module = numparse_mod },
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

    // xlsx.zig is both a module root and a test root: the tests live in the same
    // file the "xlsx" module above is built from. Its import names must therefore
    // mirror the production wiring — the same decimal + zipstream handles, or the
    // test build resolves a different module than the shipped one does.
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

    // The test module's import names must match the production wiring above.
    const config_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/config.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
            .imports = &.{
                .{ .name = "json5",       .module = json5_mod },
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
    test_step.dependOn(&b.addRunArtifact(json_tests).step);
    test_step.dependOn(&b.addRunArtifact(btrace_tests).step);
    test_step.dependOn(&b.addRunArtifact(expr_tests).step);
    test_step.dependOn(&b.addRunArtifact(unicode_tests).step);
    test_step.dependOn(&b.addRunArtifact(xlsx_tests).step);
    test_step.dependOn(&b.addRunArtifact(config_tests).step);
    test_step.dependOn(&b.addRunArtifact(docs_tests).step);
    test_step.dependOn(&b.addRunArtifact(inspect_tests).step);
}

/// Publish a module obtained from a dependency under bxp-core's own namespace.
///
/// `dependency().module()` returns a module OWNED by that dependency; unlike
/// `b.addModule` it does not add an entry to this package's module table. Any
/// module a downstream package asks for by name — `core_dep.module("json5")`
/// and `core_dep.module("zipstream")` in bxp-cli/build.zig,
/// `core_dep.module("minisign")` in bxp-gui-bridge/build.zig — therefore has
/// to be re-published here, or the downstream build panics with "unable to
/// find module '<name>'". This is `std.Build.addModule`'s own second line.
///
/// `minisign`, `procrun` and `mcp` are the re-exports bxp-core itself never
/// imports: they are published only so `bxp-gui-bridge` / `bxp-mcp` share this
/// package's single zig-libs pin instead of carrying a second one of their own.
fn reexport(b: *std.Build, name: []const u8, mod: *std.Build.Module) void {
    b.modules.put(b.graph.arena, b.dupe(name), mod) catch @panic("OOM");
}
