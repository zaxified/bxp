# CLAUDE.md — bxp-core

Internal Zig library shared by bxp-cli (and future packages).
For monorepo-level context see [`../CLAUDE.md`](../CLAUDE.md).

## Purpose

**bxp-core** — shared Zig modules for CSV parsing, xlsx conversion, expression evaluation,
JSON/JSON5 handling, configuration loading, and documentation aggregation.
Consumed by bxp-cli (conversion engine) and bxp-fmt (validator + docs emitter)
as a local path dependency.

## Module overview

| Module | File | Public API |
|---|---|---|
| `csv` | `csv.zig` | `splitRecords()`, `splitFields()` |
| `xlsx` | `xlsx.zig` | `xlsxToCsv()`, `SheetSpec` |
| `expr` | `expr.zig` | `eval()`, `evalString()`, `Context`, `Value`, `FnDoc` catalog |
| `config` | `config.zig` | `Config`, `BrokerConfig`, `load()`, `validate()`, `FieldDoc` |
| `json` | `json.zig` | `readJsonRecords()` |
| `json5` | `json5.zig` | `preprocess()` (internal; also exported for direct use) |
| `docs` | `docs.zig` | `writeDocs(alloc, writer)` — emits the `bxp-fmt --docs` JSON |

## Module details

### csv.zig
RFC 4180 CSV parser.

- `splitRecords(content, quote_ch, alloc)` — splits raw file content into record slices
  (no allocation per record; slices into `content`).
- `splitFields(record, buf, delim, quote_ch, alloc)` — splits one record into field strings,
  up to `buf.len` fields. Unquotes quoted fields.
- Intentional RFC 4180 deviation: leading/trailing spaces are trimmed from field values
  and header names (broker exports frequently pad fields).
- Unit tests inline (`zig build test`).

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
- Unit tests inline (~57 test cases).

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
Reads a JSON array-of-objects file into a unified row representation for use in the pipeline.

- `readJsonRecords(alloc, content, col_names, all_rows)` — fills `col_names` (union of all
  keys found across all objects) and `all_rows` (each object as a `[][]const u8` field array).
- Handles missing keys per object (fills with empty string).

### json5.zig
Preprocessor that converts JSON5 source to standard JSON.

- `preprocess(alloc, input)` — strips `//` and `/* */` comments, converts unquoted keys
  to quoted keys, removes trailing commas, converts single-quoted strings to double-quoted.
- Implemented as a single-pass tokenizer — no external dependencies.
- Unit tests inline (~8 test cases).

## Build

```bash
# Build all modules (no standalone binary):
cd bxp-core && zig build

# Run unit tests (csv, expr, json5, docs):
cd bxp-core && zig build test
```

Module exports in `build.zig`: `csv`, `json`, `json5`, `xlsx`, `expr`, `config`, `docs`.
`expr` imports `sunrise`; `config` imports `json5` (as `"json5.zig"` — internal import name);
`docs` imports `config`, `expr`, `json5`.

## Coding conventions

- All code comments and documentation in English.
- Zig 0.15.2 API.
- `processBroker()` in pipeline.zig and `load()` in config.zig are intentionally large
  (~320–336 lines) linear pipelines — do not split unless there is a concrete duplication problem.
