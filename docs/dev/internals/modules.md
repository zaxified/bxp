# Module Reference

## bxp-core modules

| Module        | File              | Responsibility                                                                                                                                                                                                                                                                                                                                                                           |
| ------------- | ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `csv`         | `csv.zig`         | RFC 4180 parser. `LineIterator` yields records from an in-memory chunk; `splitFields()` unquotes fields. Spaces preserved — trimmed outside csv.zig at access time in `expr.Context`.                                                                                                                                                                                                    |
| `xlsx`        | `xlsx.zig`        | Converts `.xlsx` to intermediate `.csv`. Reads ZIP+XML, handles shared strings, formula results, dates (via `styles.xml` numFmtId). Worksheets are streamed (no whole-file size cap); only the shared-strings table is capped (`XLSX_SHARED_STRINGS_CAP`, 1 GiB).                                                                                                                        |
| `zipstream`   | `zipstream.zig`   | Streaming ZIP reader — central-directory walk + per-entry inflate. Shared primitive behind xlsx ingest and bxp-cli's parallel `zipPrePass`; consumer memory is O(one inflate window). Store + deflate only.                                                                                                                                                                              |
| `expr`        | `expr.zig`        | Expression evaluator. Recursive-descent parser → evaluator. Per-row `Context` holds field values, ticker map, lookup table. `eval()` returns `Value` (string/decimal/bool — decimal is fixed-point i128, see `decimal.zig`); `evalString()` coerces to string. Each built-in has a co-located `FnDoc` entry consumed by `docs.zig`.                                                      |
| `datefmt`     | _(zig-libs dep)_  | Date core (parse / format / civil arithmetic), named module imported by `expr.zig` from the pinned `zig_libs` fetch dependency — no longer in this tree. Pre-1970 dates supported (pure parse → format, no epoch round-trip).                                                                                                                                                            |
| `decimal`     | `decimal.zig`     | Fixed-point `i128` at scale 1e12 (12 fractional digits) numeric core: exact `+ −`, half-away-from-zero `× ÷` / `ROUND`. The named module behind `Value.decimal`; shared by the csv / json / xlsx input paths so an identical numeric string parses identically everywhere.                                                                                                               |
| `unicode`     | `unicode.zig`     | UTF-8 case mapping + diacritic stripping behind `UPPER` / `LOWER` / `UNACCENT`, over `uucode` tables. File-relative `@import` by `expr.zig`.                                                                                                                                                                                                                                             |
| `encoding`    | _(zig-libs dep)_  | Layer-0 single-byte code page ↔ UTF-8 transcode (Win-1250/1252, Latin-1/2/9) behind `csv_*_encoding`. 256-entry tables, no `uucode`. Named module imported by `expr` + `config` from the pinned `zig_libs` fetch dependency — no longer in this tree.                                                                                                                                                                                                                                            |
| `config`      | `config.zig`      | Reads `bxp-cli.json` via `json5.zig` preprocessor then `std.json`. Returns `Config` owning all heap memory. `BrokerConfig.validate()` checks semantic constraints. Each struct has a co-located `FieldDoc` table consumed by `docs.zig`.                                                                                                                                                 |
| `json`        | `json.zig`        | Reads a JSON array-of-objects into a flat row representation. Builds a union of all keys across all objects; fills missing keys with empty string.                                                                                                                                                                                                                                       |
| `btrace`      | `btrace.zig`      | Binary BXTB trace `Writer` / `Reader` for `bxp-cli --trace`. Carries metadata only (per-row source byte offsets, errors, pre_pass dump, stats); per-row drill-down is recomputed on demand by the GUI via the bridge. The sole `bxp-cli --trace` format — NDJSON is no longer emitted there (the per-expr `evalTrace` stream is the only remaining NDJSON, see the inspect table below). |
| `json5`       | `json5.zig`       | Single-pass tokenizer that converts JSON5 → standard JSON. Strips comments, converts unquoted keys, removes trailing commas, normalizes single-quoted strings.                                                                                                                                                                                                                           |
| `docs`        | `docs.zig`        | Aggregates `expr.zig` FnDoc catalog and `config.zig` FieldDoc tables into the docs catalog JSON. Single source of truth consumed by bxp-gui at startup.                                                                                                                                                                                                                                  |
| `diagnostics` | `diagnostics.zig` | Structured validation collector. `Severity` (.error / .warning / .info), `Diagnostic` (path, position, code, message, suggest), `Diagnostics` (ArrayList collector). Used by the config validator's deep validation; bxp-cli passes a null sink.                                                                                                                                         |

---

## bxp-cli internals

**`main.zig`** - entry point:

1. Parses run flags: `--config`, `--template`, `--data`, `--dry-run`, `--debug` (+ `=json`), `--quiet`, `--fresh`, `--trace` (+ `--trace-file`), `--check-fs`, `--version`, `--help`.
2. Validates file paths (rejects shell metacharacters, limits `../` depth).
3. Loads and validates all templates in config (`config.validate()`).
4. Calls `pipeline.xlsxPrePass()` for any templates that reference `.xlsx` files.
5. Calls `pipeline.processBroker()` for each selected template.
6. Exits with code `0` (success), `1` (error), or `2` (warnings).

**`pipeline.zig`** - processing engine:

- `xlsxPrePass()` - iterates all templates with `xlsx_sheet` defined, converts each
  `.xlsx` file to an intermediate `.csv`. Templates sharing the same `data_dir` share
  the extraction pass (each file extracted once).
- `processBroker()` - the main processing loop (intentionally monolithic):
  1. Reads input files (CSV, JSON, or intermediate CSV from xlsx pre-pass).
  2. Runs `pre_pass` if defined: one full iteration over all rows building a lookup map.
  3. Main loop: evaluates `input_schema` expressions, matches `row_rules`, renders `output_schema` to produce output rows.
  4. Writes RFC 4180-compliant CSV to `.csvx` output files.
- `Output` - thin wrapper around stdout that respects `--quiet` and `--debug` flags.
- `SectionStats` - accumulates warning/error counts and elapsed time across templates.

Deeper detail: [`bxp-cli/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-cli/CLAUDE.md).

---

## inspect core (stateless surface)

Everything that isn't "run a conversion" — config validation, expression
validation / evaluation / trace, expr-batch, schema/docs emission, template
list/fetch — lives in one stateless module, `bxp-core/src/inspect.zig`. It is
pure: it never reads argv, never writes stdout/stderr, never exits; callers own
all I/O and the arena. Two thin adapters wrap it: **bxp-mcp** (MCP/stdio for
agents) and **bxp-gui-bridge** (FFI for the GUI). A former `bxp-fmt` CLI adapter
wrapped the same calls argv→stdout and was removed once both covered every op.

| inspect function                            | Backed by                                | Purpose                                                                           |
| ------------------------------------------- | ---------------------------------------- | --------------------------------------------------------------------------------- |
| `annotateRaw` / `annotateConfigFromFile`    | `config.load` + `config.validateCollect` | Annotated JSON with `$comm_<N>` / `$err_<N>` / `$warn_<N>` / `$info_<N>` siblings |
| `listTemplatesValue` / `fetchTemplateValue` | `config.load`                            | Template id array / one template's raw JSON                                       |
| `validateExpr` / `validateExprJson`         | `expr.eval` + static FnArgDoc lint       | Authoring-time validation of one expression                                       |
| `evalExpr`                                  | `expr.evalString`                        | Lenient runtime value of one expression                                           |
| `evalTrace`                                 | `expr.eval` (trace_writer)               | Per-call NDJSON trace stream                                                      |
| `evalBatch`                                 | `expr.evalString` ×N                     | Evaluate N exprs against one row in a single call; `{results:[…]}`                |
| `docsJson`                                  | `docs.writeDocs`                         | Full FnDoc / FieldDoc catalog (single source for bxp-gui startup)                 |

Adding an op: write the pure function in `inspect.zig`, then expose it from each
adapter (a `bxp-mcp` tool in `bxp-mcp/src/tools.zig` + a `bridge_*` entry in
`bxp-gui-bridge/src/main.zig`). No business logic lives in the adapters.

Deeper detail: [`bxp-mcp/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-mcp/CLAUDE.md),
[`bxp-gui-bridge/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-gui-bridge/CLAUDE.md).
