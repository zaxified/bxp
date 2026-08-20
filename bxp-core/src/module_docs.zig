//! Architecture catalogs for bxp-core: the module inventory and the stateless
//! `inspect` surface. Pure data, no imports — `tools/zig-doc-gen` renders both
//! into `docs/includes/`, and `scripts/docs/gen-trees.py` cross-checks the
//! module names against `build.zig`.
//!
//! Why this file exists: the module table in `docs/dev/internals/modules.md`
//! was hand-kept, and the zig-libs migration moved eight modules out of this
//! tree without the table noticing — the three re-exports it gained
//! (`mcp`, `minisign`, `procrun`) never appeared there at all. `origin` is an
//! enum rather than a sentence precisely because "where does this module come
//! from" is the column that rots.

/// Where a module's code lives. The distinction is the one that keeps going
/// stale in prose: several of these used to be files in `src/` and are now
/// consumed from a pinned upstream.
pub const Origin = enum {
    /// A file in bxp-core/src/, published by build.zig.
    in_tree,
    /// A module of the pinned `zig_libs` collection.
    zig_libs,
    /// A standalone pinned fetch dependency.
    fetch_dep,

    pub fn label(self: Origin) []const u8 {
        return switch (self) {
            .in_tree => "",
            .zig_libs => "_(zig-libs)_",
            .fetch_dep => "_(fetch dep)_",
        };
    }
};

pub const ModuleDoc = struct {
    name: []const u8,
    origin: Origin,
    /// Source file, for `.in_tree` modules only.
    file: []const u8 = "",
    /// True when bxp-core never imports it and only re-publishes it so a
    /// downstream package shares this package's single zig-libs pin.
    reexport_only: bool = false,
    responsibility: []const u8,
};

pub const modules = [_]ModuleDoc{
    .{ .name = "expr", .origin = .in_tree, .file = "expr.zig", .responsibility = "Expression evaluator. Recursive-descent parser into an evaluator; a per-row `Context` holds the field values, the named maps and the pre-pass lookup. `eval()` returns a `Value` (string / decimal / bool), `evalString()` coerces to string. Each built-in carries a co-located `FnDoc` entry that `docs.zig` consumes." },
    .{ .name = "config", .origin = .in_tree, .file = "config.zig", .responsibility = "Reads `bxp-cli.json` through the `json5` preprocessor, then `std.json`. Returns a `Config` owning all heap memory; `BrokerConfig.validate()` checks the semantic constraints. Each struct carries a co-located `FieldDoc` table that `docs.zig` consumes." },
    .{ .name = "xlsx", .origin = .in_tree, .file = "xlsx.zig", .responsibility = "Converts `.xlsx` to an intermediate `.csv`. Reads ZIP+XML, resolves shared strings, formula results and dates (via `styles.xml` numFmtId). Worksheets stream with no whole-file size cap; only the shared-strings table is capped (`XLSX_SHARED_STRINGS_CAP`, 1 GiB)." },
    .{ .name = "json", .origin = .in_tree, .file = "json.zig", .responsibility = "Reads a JSON array-of-objects into a flat row representation. Builds the union of all keys across all objects and fills the missing ones with an empty string." },
    .{ .name = "btrace", .origin = .in_tree, .file = "btrace.zig", .responsibility = "Binary BXTB trace `Writer` / `Reader` for `bxp-cli --trace`. Carries metadata only — per-row source byte offsets, errors, the pre_pass dump, stats; per-row drill-down is recomputed on demand by the GUI through the bridge." },
    .{ .name = "unicode", .origin = .in_tree, .file = "unicode.zig", .responsibility = "UTF-8 case mapping and diacritic stripping behind `UPPER` / `LOWER` / `UNACCENT`, over the `uucode` tables. Imported file-relative by `expr.zig`." },
    .{ .name = "docs", .origin = .in_tree, .file = "docs.zig", .responsibility = "Aggregates the `expr.zig` FnDoc catalog and the `config.zig` FieldDoc tables into the docs catalog JSON, and carries the shared Markdown table renderer. Single source for the GUI at startup and for the generated reference pages." },
    .{ .name = "inspect", .origin = .in_tree, .file = "inspect.zig", .responsibility = "The shared stateless inspection core — config validation, expression validation / eval / trace, expr-batch, schema and docs emission, template list and fetch. Pure: never reads argv, never writes stdout, never exits. Wrapped by bxp-mcp, bxp-gui-bridge and the wasm build." },
    .{ .name = "wasm", .origin = .in_tree, .file = "wasm.zig", .responsibility = "wasm32 export wrapper (`bxp_eval_batch` / `bxp_docs`) over `inspect.evalBatchIo` — the engine behind the docs site's expression scratchpad, which makes the browser a fourth consumer of the one evaluator. Opt-in target (`zig build wasm`), never part of `install`; the `.wasm` it emits is an untracked build artifact." },

    .{ .name = "csvstream", .origin = .zig_libs, .responsibility = "CSV record model plus streaming reader. `LineIterator` yields records from an in-memory chunk and `splitFields()` unquotes them (spaces preserved, trimmed at access time in `expr.Context`); `ChunkReader` feeds it, splitting input on `'\\n'` boundaries for the parallel pipeline. Lazy quotes by design — a `'\\n'` always ends a record, deliberately not RFC 4180 §2.6, which is what makes any newline a safe chunk boundary." },
    .{ .name = "zipstream", .origin = .zig_libs, .responsibility = "Streaming ZIP reader — central-directory walk plus per-entry inflate, with CRC-32 verified at end of stream. Shared primitive behind xlsx ingest and bxp-cli's parallel `zipPrePass`; consumer memory is O(one inflate window). Store and deflate only." },
    .{ .name = "datefmt", .origin = .zig_libs, .responsibility = "Date core — parse, format, civil arithmetic — behind `DATE_CONVERT` and every calendar built-in. Pre-1970 dates are supported (pure parse to format, no epoch round-trip)." },
    .{ .name = "tz", .origin = .zig_libs, .responsibility = "IANA time-zone UTC-offset lookup behind `TO_UTC` / `TZ_OFFSET` / `TZ_CONVERT` / `IS_DST`, including the DST transition rules. The zone tables are compiled into the module, so there is no runtime tzdata on the host. Imports `datefmt` internally, which is why both must come off the same `b.dependency` handle." },
    .{ .name = "decimal", .origin = .zig_libs, .responsibility = "Fixed-point `i128` at scale 1e12 (12 fractional digits): exact `+ −`, half-away-from-zero `× ÷` and `ROUND`. The core behind `Value.decimal`, shared by the csv / json / xlsx input paths so an identical numeric string parses identically everywhere. Fallible operations return `Error!Decimal`, and `toString` writes into a caller buffer." },
    .{ .name = "numparse", .origin = .zig_libs, .responsibility = "Grouped-number parser (`1,234.56` / `1.234,56`) behind `expr.zig`'s numeric-coercion fallback, its `GREATEST` / `LEAST` diagnostics and the `decimal_sep_in` locale normalisation. Returns the same `decimal` the module above supplies. The one piece extracted from below file level — it was never its own file here, only a function inside `expr.zig`." },
    .{ .name = "encoding", .origin = .zig_libs, .responsibility = "Layer-0 single-byte code page to UTF-8 transcode (Win-1250/1252, Latin-1/2/9) behind `csv_input_encoding` / `csv_output_encoding`. 256-entry tables, no `uucode`." },
    .{ .name = "json5", .origin = .zig_libs, .responsibility = "Single-pass tokenizer converting JSON5 to standard JSON: strips comments, quotes bare keys, removes trailing commas, normalises single-quoted strings. Imported by `config`, `docs` and `inspect`." },
    .{ .name = "diagnostics", .origin = .zig_libs, .responsibility = "Structured validation collector: `Severity` (error / warning / info), `Diagnostic` (path, position, code, message, suggest) and the `Diagnostics` collector. Used by the config validator's deep validation; bxp-cli passes a null sink." },
    .{ .name = "minisign", .origin = .zig_libs, .reexport_only = true, .responsibility = "Minisign signature format (Ed25519 + Blake2b-512) behind the GUI updater's authenticity check. bxp-core never imports it — re-published so `bxp-gui-bridge` shares this package's single zig-libs pin." },
    .{ .name = "procrun", .origin = .zig_libs, .reexport_only = true, .responsibility = "Reap-race-tolerant child wait behind the bridge's `bxp-cli` spawns (the Dart VM's own reaper would otherwise trip std's ECHILD panic). Re-published for the same single-pin reason." },
    .{ .name = "mcp", .origin = .zig_libs, .reexport_only = true, .responsibility = "JSON-RPC 2.0 / MCP transport behind `bxp-mcp` — the one module that came back: upstream's copy is this repo's former `bxp-mcp/src/server.zig`, extracted there and hardened. Re-published for the same single-pin reason." },

    .{ .name = "uucode", .origin = .fetch_dep, .responsibility = "Field-selected Unicode case-mapping and decomposition tables behind `UPPER` / `LOWER` / `UNACCENT`. Only the tables `unicode.zig` asks for are generated and compiled in." },
    .{ .name = "regex", .origin = .fetch_dep, .responsibility = "The Pike-VM engine (`quangd/regex.zig`, linear time, zero transitive deps) behind `REGEX_MATCH` / `REGEX_EXTRACT`." },
};

/// One entry point of the stateless `inspect` surface.
pub const InspectOpDoc = struct {
    /// Public function name in `inspect.zig`. Checked at comptime against the
    /// module's actual declarations.
    name: []const u8,
    backed_by: []const u8,
    purpose: []const u8,
};

pub const inspect_ops = [_]InspectOpDoc{
    .{ .name = "annotateRaw", .backed_by = "`config.load` + `config.validateCollect`", .purpose = "Annotated JSON with `$err_<N>` / `$warn_<N>` / `$info_<N>` siblings, from config text held in memory." },
    .{ .name = "annotateConfigFromFile", .backed_by = "`annotateRaw`", .purpose = "The same, reading the config off disk." },
    .{ .name = "validateExpr", .backed_by = "`expr.eval` + static FnArgDoc lint", .purpose = "Authoring-time validation of one expression; null when it is clean." },
    .{ .name = "validateExprJson", .backed_by = "`validateExpr`", .purpose = "The same, serialised as JSON for a wire adapter." },
    .{ .name = "evalExpr", .backed_by = "`expr.evalString`", .purpose = "Lenient runtime value of one expression against one row." },
    .{ .name = "evalTrace", .backed_by = "`expr.eval` (trace_writer)", .purpose = "Per-call NDJSON trace stream for the expression debugger." },
    .{ .name = "evalBatch", .backed_by = "`expr.evalString` ×N", .purpose = "Evaluate N expressions against one row in a single call; `{results:[…]}`." },
    .{ .name = "evalBatchIo", .backed_by = "`evalBatch`", .purpose = "The same with an explicit `std.Io`, which is what lets the wasm build supply the browser's clock and RNG." },
    .{ .name = "docsJson", .backed_by = "`docs.writeDocs`", .purpose = "Full FnDoc / FieldDoc catalog — the single source the GUI reads at startup." },
    .{ .name = "listTemplates", .backed_by = "`config.load`", .purpose = "`{templates:[{id, data_dir, file_pattern_in/out, file_type_in/out, description}]}` from config text." },
    .{ .name = "listTemplatesValue", .backed_by = "`listTemplates`", .purpose = "The same from an already-parsed JSON value." },
    .{ .name = "listTemplatesFromFile", .backed_by = "`listTemplates`", .purpose = "The same, reading the config off disk." },
    .{ .name = "fetchTemplate", .backed_by = "`config.load`", .purpose = "One template re-serialised as a JSON object." },
    .{ .name = "fetchTemplateValue", .backed_by = "`fetchTemplate`", .purpose = "The same from an already-parsed JSON value." },
    .{ .name = "fetchTemplateFromFile", .backed_by = "`fetchTemplate`", .purpose = "The same, reading the config off disk." },
    .{ .name = "templateIo", .backed_by = "`config.load`", .purpose = "Just one template's input/output shape — what a caller needs to stage files before a run." },
};
