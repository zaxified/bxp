# CLAUDE.md — bxp-core

Internal Zig library shared by bxp-cli (and future packages).
For monorepo-level context see [`../CLAUDE.md`](../CLAUDE.md).

## Purpose

**bxp-core** — shared Zig modules for CSV parsing, xlsx conversion, expression evaluation,
JSON/JSON5 handling, configuration loading, and documentation aggregation.
Consumed by bxp-cli (conversion engine) and bxp-fmt (validator + docs emitter)
as a local path dependency.

## Module overview

| Module        | File              | Public API                                                                |
| ------------- | ----------------- | ------------------------------------------------------------------------- |
| `csv`         | `csv.zig`         | `splitRecords()`, `splitFields()`                                         |
| `xlsx`        | `xlsx.zig`        | `xlsxToCsv()`, `SheetSpec`                                                |
| `expr`        | `expr.zig`        | `eval()`, `evalString()`, `Context`, `Value`, `FnDoc` catalog             |
| `config`      | `config.zig`      | `Config`, `BrokerConfig`, `load()`, `validate()`, `FieldDoc`              |
| `json`        | `json.zig`        | `readJsonRecords()` + NDJSON writer (`Safe`, `classify`, `writeEvent`)    |
| `json5`       | `json5.zig`       | `preprocess()` (internal; also exported for direct use)                   |
| `docs`        | `docs.zig`        | `writeDocs(alloc, writer)` — emits the `bxp-fmt --docs` JSON              |
| `diagnostics` | `diagnostics.zig` | `Diagnostics`, `Diagnostic`, `Severity` — structured validation collector |

## Module details

### csv.zig

RFC 4180 CSV parser.

- `splitRecords(content, quote_ch, alloc)` — splits raw file content into record slices
  (no allocation per record; slices into `content`).
- `splitFields(record, buf, delim, quote_ch, alloc)` — splits one record into field strings,
  up to `buf.len` fields. Unquotes quoted fields.
- Spaces are preserved per RFC 4180. The bxp pipeline intentionally trims them
  _outside_ csv.zig: field values at access time in `expr.Context.field`
  (`expr.zig:138`), header names when building `col_index` in
  `bxp-cli/src/pipeline.zig:517`. Brokers frequently pad fields, so the rest
  of the pipeline (date parsing, numeric conversion, comparisons) sees clean
  values without csv.zig having to mutate the slices it returns.
- Unit tests inline (12 test cases).

### xlsx.zig

Converts `.xlsx` files (ZIP + XML) to intermediate CSV files.

- `xlsxToCsv(alloc, xlsx_file, sheets, out_dir, stem)` — extracts selected sheets to CSV.
- `SheetSpec` — `{ name, header_row, output_suffix }` describing one sheet to extract.
- Extracts to a temporary `.xlstmp` directory next to the output files; cleaned up on exit.
- Supported cell types: shared strings, inline strings, formula results, booleans,
  plain numbers, date/time (detected via styles.xml numFmtId).
- Buffer sizes: `ZIP_READ_BUF_SIZE=8192`, `CSV_OUT_BUF_SIZE=65536`, `XLSX_MAX_FILE_SIZE=10MB`.
- No unit tests (tested via bxp-cli integration tests).

### expr.zig

Expression evaluator for `input_schema` and `row_rules` in bxp-cli.json.

- `eval(expr, ctx)` — parse and evaluate expression, returns `Value`.
- `evalString(expr, ctx)` — like `eval()` but coerces result to string.
- `Context` — per-row evaluation context: `fields`, `col_index`, `ticker_map`,
  `lookup_table`, `alloc`, `decimal_sep_in`, `quote_out`.
- `Value` — union of `number: f64`, `string: []const u8`, `boolean: bool`.
- Depends on `sunrise` for `DATE_CONVERT()` date/time parsing and formatting.
- Unit tests inline (83 test cases).

**Built-in functions:** IF, ABS, DATE_CONVERT, PRICE_VALUE, PRICE_CURRENCY, TICKER,
LOOKUP, SPLIT_PART, CONTAINS, REPLACE, TRIM, ROUND, FLOOR, CEILING, NOW, RAND, COALESCE, FIELDS.

**Doc catalog** (`pub const builtins`, `keywords`, `operators`, `tokens`): each
builtin sits next to its `FnDoc` declaration (search for `── <NAME> ──`
section headers). The `docs` module re-exports these tables verbatim — adding
a new builtin means writing the impl + `FnDoc` here once, no separate doc
file to keep in sync.

### config.zig

JSON5 configuration loader.

- `load(alloc, config_path)` — reads and parses bxp-cli.json; returns `Config`.
  Missing file → returns empty Config. Malformed JSON5 → returns error with diagnostics.
- `Config` — owns all heap memory; `deinit()` frees everything.
- `BrokerConfig` — per-template config struct (see field list in bxp-cli/CLAUDE.md).
- `BrokerConfig.validate(id, writer)` — validates config consistency (e.g. `@date` required
  when `date_filter_from_filename=true`).
- Config file size limit: `CONFIG_MAX_FILE_SIZE=1MB`.
- Internally uses `json5.zig` to preprocess JSON5 → standard JSON before `std.json` parsing.

**Doc catalog** (`pub const FieldDoc`, plus `pub const fields = [_]FieldDoc{...}`
on each public struct + `pub const scaffold_template` where a struct can be
scaffolded by the GUI): co-located with the struct each entry describes —
same pattern as `expr.FnDoc`. Adding a config field = update the struct AND
its `fields` table in one place. Aggregated by `docs.zig`; serves
`bxp-fmt --docs`.

### docs.zig

Aggregator for `bxp-fmt --docs`. Single source of truth that the GUI
(bxp-gui) consumes at startup.

- `writeDocs(alloc, writer)` — emits the full JSON: `functions`, `keywords`,
  `operators`, `tokens` (re-exported live from `expr.zig`), and
  `config_schema` (flattened from per-struct `FieldDoc` tables in `config.zig`
  plus envelope entries declared inline for top-level keys, map wildcards,
  and the legacy `pre_pass` single-block form).
- The output JSON shape is a stable contract with bxp-gui's
  `lib/store/trace_store.dart` and `lib/store/schema_gate.dart`. Verify
  refactors via `jq -S '.config_schema |= sort_by(.key)'` byte-diff before/after.
- Inline test guards the entry count and known paths against drift.

### json.zig

Two responsibilities: JSON array-of-objects reader for pipeline input, and a
fast-path NDJSON writer for the bxp-cli `--trace` event stream.

**Reader:**

- `readJsonRecords(alloc, content, col_names, all_rows)` — fills `col_names` (union of all
  keys found across all objects) and `all_rows` (each object as a `[][]const u8` field array).
- Handles missing keys per object (fills with empty string).

**NDJSON writer** (bypasses `std.json.Stringify.encodeJsonString`'s per-byte
escape scan when callers can pre-classify strings as escape-free):

- `Safe { bytes: []const u8 }` — wrapper marking a string as JSON-safe (no `"`, `\`, or byte < 0x20).
- `classify(s)` — returns true when `s` contains no JSON-significant bytes.
- `wrap(s)` — unchecked Safe wrapping (caller asserts contract).
- `wrapChecked(s)` — returns `?Safe` (null when classify fails).
- `writeEvent(w, comptime t_name, args)` — emits one NDJSON line. Comptime-dispatched
  field handling for `Safe`, `[]const u8`, integers, floats, bool, optionals, slices,
  fixed arrays, anonymous structs (recurse as nested object), and StringHashMap-like
  types with `.iterator()` (recurse as runtime-keyed object). JSON output is semantically
  equivalent to `std.json.Stringify` (same parsed tree) but is NOT byte-identical: no
  whitespace, no indent, minimal escape shape.
- ~15 inline tests cover all dispatch arms including UTF-8 multibyte, adversarial
  payloads (control bytes, embedded quotes), and `rule_match`-shape nested maps.

### json5.zig

Preprocessor that converts JSON5 source to standard JSON.

- `preprocess(alloc, input)` — strips `//` and `/* */` comments, converts unquoted keys
  to quoted keys, removes trailing commas, converts single-quoted strings to double-quoted.
- Implemented as a single-pass tokenizer — no external dependencies.
- Unit tests inline (20 test cases).

### diagnostics.zig

Structured diagnostics collector for config/json5/expr validation.

- `Severity` — enum `{ .@"error", .warning, .info }`.
- `Diagnostic` — one finding: `path` (dot-separated config tree path), optional source
  position (`line`, `col`, `end_line`, `end_col`), optional in-expression byte span
  (`expr_off`, `expr_len`), `severity`, `code` (machine-readable, e.g. `"config.unknown_key"`),
  `message`, and optional `suggest` (did-you-mean hint).
- `Diagnostics` — owned `ArrayList(Diagnostic)` collector with `init`, `deinit`, `append`,
  `count`, `countBySeverity`.
- Used by bxp-fmt's `--config` deep validation pass. bxp-cli passes a null sink; existing
  fail-fast/stderr behavior is preserved.
- Severity routing in bxp-fmt annotated JSON: `.@"error"` → `$err_<N>` object,
  `.warning` → `$warn_<N>` object, `.info` → `$info_<N>` object. Each object may contain
  `message`, `off`, `len`, `suggest` fields.
- Unit tests inline (1 test case).

## Build

```bash
# Build all modules (no standalone binary):
cd bxp-core && zig build

# Run unit tests (csv, expr, json5, docs):
cd bxp-core && zig build test
```

Module exports in `build.zig`: `csv`, `json`, `json5`, `xlsx`, `expr`, `config`, `docs`, `diagnostics`.
`expr` imports `sunrise`; `config` imports `json5` (as `"json5.zig"` — internal import name);
`docs` imports `config`, `expr`, `json5`; `diagnostics` has no bxp-core dependencies.

## Coding conventions

- All code comments and documentation in English.
- Zig 0.15.2 API.
- `processBroker()` in pipeline.zig and `load()` in config.zig are intentionally large
  (~320–336 lines) linear pipelines — do not split unless there is a concrete duplication problem.

## Known non-issues — deliberately not refactored

Audit follow-up rationale captured here so future audits don't re-flag
the same observations. If the rationale stops applying, revisit.

- **`xlsx.zig normalizeNumber` 1e15 guard.** A 2026-05-06 audit
  flagged the `@abs(f) < 1e15` check as letting 16-digit f64 values
  through. The example given (`9_999_999_999_999_999.0`) actually
  exceeds 1e15, so the guard correctly rejects it. f64 represents
  integers exactly up to `2^53 ≈ 9.007e15`; the 1e15 cap leaves a 9×
  margin below that boundary. Anything passing both `f == rounded`
  and `@abs(f) < 1e15` is bit-exact through `@intFromFloat` —
  no precision loss possible. The guard could be raised to
  `0x20000000000000` (`2^53`) but that's an optimisation, not a fix.

- **`expr.zig adaptReplace` OOM detail.** A previous audit suggested
  routing OOM through the `setNotANumber` / `error_detail` convention so
  callers see a friendly diagnostic. Skipped: that convention works for
  type-mismatch errors (predictable, recoverable inputs), but OOM is
  systemic — the next `allocPrint` for the diagnostic itself would also
  OOM. We propagate `error.OutOfMemory` unchanged as a non-recoverable
  failure.
