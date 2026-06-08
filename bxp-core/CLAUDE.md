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
| `csv`         | `csv.zig`         | `splitFields()`, `LineIterator`                                           |
| `xlsx`        | `xlsx.zig`        | `xlsxToCsv()`, `SheetSpec`                                                |
| `expr`        | `expr.zig`        | `eval()`, `evalString()`, `Context`, `Value`, `FnDoc` catalog             |
| `datefmt`     | `datefmt.zig`     | `parse()`, `format()`, civil/arithmetic helpers — date core (file-rel @import by `expr.zig`, not a named module) |
| `decimal`     | `decimal.zig`     | `Decimal` fixed-point i128 @ 1e12 — numeric core (named `"decimal"` module, shared by every input path) |
| `unicode`     | `unicode.zig`     | `toUpperStr()`, `toLowerStr()`, `unaccentStr()` — UTF-8 case mapping + diacritic stripping over `uucode` tables (file-rel @import by `expr.zig`, not a named module) |
| `encoding`    | `encoding.zig`    | `Encoding`, `decodeToUtf8()`, `encodeFromUtf8()` — Layer 0 single-byte code page ↔ UTF-8 (named module; shared by `expr` + `config`; no `uucode` dep) |
| `config`      | `config.zig`      | `Config`, `BrokerConfig`, `load()`, `validate()`, `FieldDoc`              |
| `json`        | `json.zig`        | `scanColNames()` + `RecordReader` — streaming JSON array-of-objects input |
| `btrace`      | `btrace.zig`      | Binary trace `Writer` / `Reader` for `--trace=bin`                        |
| `json5`       | `json5.zig`       | `preprocess()` (internal; also exported for direct use)                   |
| `docs`        | `docs.zig`        | `writeDocs(alloc, writer)` — emits the `bxp-fmt --docs` JSON              |
| `diagnostics` | `diagnostics.zig` | `Diagnostics`, `Diagnostic`, `Severity` — structured validation collector |

## Module details

### csv.zig

RFC 4180 CSV parser.

- `splitFields(record, buf, delim, quote_ch, alloc)` — splits one record into field strings,
  up to `buf.len` fields. Unquotes quoted fields.
- `LineIterator.init(bytes, quote, base_offset)` — quote-aware streaming
  iterator over records held in a single in-memory chunk; `next()` yields
  `LineSlice { bytes, byte_offset }` until the buffer is exhausted.
- Spaces are preserved per RFC 4180. The bxp pipeline intentionally trims them
  _outside_ csv.zig: field values at access time in `expr.Context.field`
  (`expr.zig:161`), header names when building `col_index` in
  `bxp-cli/src/pipeline.zig:1660`. Brokers frequently pad fields, so the rest
  of the pipeline (date parsing, numeric conversion, comparisons) sees clean
  values without csv.zig having to mutate the slices it returns.
- Unit tests inline (22 test cases).

### xlsx.zig

Converts `.xlsx` files (ZIP + XML) to intermediate CSV files.

- `xlsxToCsv(alloc, xlsx_file, sheets, out_dir, stem)` — extracts selected sheets to CSV.
- `SheetSpec` — `{ name, header_row, output_suffix }` describing one sheet to extract.
- Extracts to a temporary `.xlstmp` directory next to the output files; cleaned up on exit.
- Supported cell types: shared strings, inline strings, formula results, booleans,
  plain numbers, date/time (detected via styles.xml numFmtId).
- XML parts are assumed UTF-8 (what Excel always writes). A UTF-16 BOM on the
  sheet or sharedStrings XML returns `error.Utf16XmlUnsupported` instead of
  silently producing garbage; the pipeline turns that into a warn-and-skip
  (`hasUtf16Bom`). There is no `csv_*_encoding`-style transcode for xlsx — OOXML
  is effectively always UTF-8 in practice.
- Buffer sizes: `ZIP_READ_BUF_SIZE=8192`, `CSV_OUT_BUF_SIZE=65536`, `XLSX_MAX_FILE_SIZE=10MB`.
- Inline unit tests (11) cover the pure helpers: `colRefToIndex`,
  `normalizeNumber`, `excelSerialToDatetime`, `unixDayToYMD`, `decodeEntities`,
  `isDateFormatCode`, `isBuiltinDateFmt`, `getAttr`, `stripNs`, `writeCsvField`,
  `hasUtf16Bom`.
  End-to-end ZIP/XML parsing is still exercised via bxp-cli integration tests.

### expr.zig

Expression evaluator for `input_schema` and `row_rules` in bxp-cli.json.

- `eval(expr, ctx)` — parse and evaluate expression, returns `Value`.
- `evalString(expr, ctx)` — like `eval()` but coerces result to string.
- `Context` — per-row evaluation context: `fields`, `col_index`, `ticker_map`,
  `lookup_table`, `alloc`, `decimal_sep_in`, `quote_out`, `input_encoding`.
  `input_encoding` (Layer 0) transcodes each accessed field value to UTF-8 in
  `field()`; `.utf8` (default) is a zero-alloc pass-through.
- `Value` — union of `decimal: Decimal`, `string: []const u8`, `boolean: bool`.
  `Decimal` (in `decimal.zig`) is a fixed-point `i128` at scale 1e12 (12
  fractional digits): exact `+ −`, half-away-from-zero `× ÷` and `ROUND`. Replaces
  the former `f80` + `{d:.8}` print cap, so `0.02 + 0.08` is exactly `0.10`.
  Passthrough strings (coords, long IDs) bypass the core to keep full precision.
- `DATE_CONVERT()` date/time parsing and formatting is handled in-process by
  `datefmt.zig` (file-relative `@import`) — no external dependency. Pre-1970
  dates are fully supported (pure parse → format reshuffle, no epoch round-trip).
- Unit tests inline (136 test cases).

**Built-in functions:** IF, ABS, DATE_CONVERT, PRICE_VALUE, PRICE_CURRENCY,
TICKER, LOOKUP, SPLIT_PART, CONTAINS, REPLACE, TRIM, ROUND, FLOOR, CEILING,
NOW, RAND, COALESCE, FIELDS, UPPER, LOWER, UNACCENT, LEFT, RIGHT, SUBSTR,
STARTS_WITH, ENDS_WITH, NULLIF, IN, LEN, GREATEST, LEAST, DATEADD,
DATEDIFF, WORKDAY, YEAR, MONTH, DAY, WEEKDAY, EOMONTH, NTH_DOW.

**Doc catalog** (`pub const builtins`, `keywords`, `operators`, `tokens`): each
builtin sits next to its `FnDoc` declaration (search for `── <NAME> ──`
section headers). The `docs` module re-exports these tables verbatim — adding
a new builtin means writing the impl + `FnDoc` here once, no separate doc
file to keep in sync.

### unicode.zig

UTF-8 text operations behind expr.zig's `UPPER` / `LOWER` / `UNACCENT` builtins
(Layer 1 of the planned Unicode subsystem; the Layer 0 `csv_*_encoding`
transcoding comes later). File-relative `@import` by `expr.zig`, not a named
module.

- `toUpperStr(alloc, s)` / `toLowerStr(alloc, s)` — full-Unicode case mapping.
  Codepoint walk, not a byte loop, so output byte length may differ from input
  (`ß` → `SS`); callers must not pre-size to `s.len`. Latin/Greek/Cyrillic etc.
  map correctly; unicameral scripts (CJK/Arabic/Hebrew) pass through unchanged.
- `unaccentStr(alloc, s)` — Latin-scope diacritic stripping (`café`→`cafe`,
  `ß`→`ss`, `ø`→`o`). Recurses the canonical (NFD) decomposition, drops
  combining marks (non-zero canonical combining class), and keeps base letters;
  a small `latinHandlist` covers the non-decomposing Latin letters
  (`ß ø ł đ æ þ` …). Non-Latin keeps its base script (Greek `Ά`→`Α`, NOT `A`);
  compatibility decompositions (ligatures, `①`) are deliberately not folded.
- Data-lenient: a byte sequence that is not valid UTF-8 is emitted verbatim
  one byte at a time — never an error, never a crash (matches the previous
  ASCII byte loop's passthrough and the blank-field resilience contract).
- Unicode data comes from the `uucode` fetch dependency (see _External
  dependency_ below); this file is only the UTF-8 plumbing.
- Inline tests (12): case mapping (ASCII, Latin-1 accents,
  Swedish/German/Cyrillic/Greek, ß→SS, unicameral passthrough, empty,
  invalid-UTF-8); unaccent (Latin strip, hand-list letters, non-Latin
  base-script keep, empty + invalid-UTF-8 passthrough).

### encoding.zig

Layer 0 of the Unicode subsystem: legacy single-byte code page ↔ UTF-8
transcoding (the "iconv" job). No `uucode` dependency — just 256-entry mapping
tables. Drives the per-template `csv_input_encoding` / `csv_output_encoding`
config keys. **CSV only**: JSON (RFC 8259) and xlsx (XML-in-ZIP) are always
UTF-8 and never reach here.

- `Encoding` — enum: `utf8` (default), `windows_1250`, `windows_1252`,
  `iso_8859_1` (Latin-1), `iso_8859_2` (Latin-2), `iso_8859_15` (Latin-9).
  `Encoding.parse(str)` accepts canonical names + aliases (case-insensitive,
  null on no match); `canonicalName()` returns the GUI dropdown spelling.
- `decodeToUtf8(alloc, bytes, enc)` — legacy → UTF-8 (`.utf8` = verbatim dupe).
- `encodeFromUtf8(alloc, utf8, enc)` — UTF-8 → legacy; unrepresentable
  codepoints become `'?'`; invalid UTF-8 passes through verbatim.
- **Offset-safe by design**: in every code page the structural CSV bytes
  (delimiter, quote, CR, LF) are ASCII and map to themselves, so the pipeline
  parses records / counts `source_locator` offsets on the _raw_ bytes and only
  transcodes individual field values + header names (`expr.Context.field`
  decode at read; `pipeline.writeSafeValue` call sites encode at write). Trace
  drill-down offsets stay correct on the original file — no `ChunkReader` /
  fmt / GUI changes were needed.
- Tables are an identity base (byte == codepoint = Latin-1 / C1) plus
  per-code-page overrides where the mapping differs.
- Inline tests (12): parse aliases, ASCII passthrough, Latin-1/9 identity +
  divergence, Win-1250/1252 specials, Czech letters (CP1250 + ISO-8859-2),
  encode round-trips, unrepresentable → `?`, empty + invalid-UTF-8.

### config.zig

JSON5 configuration loader.

- `load(alloc, config_path)` — reads and parses bxp-cli.json; returns `Config`.
  Missing file → returns empty Config. Malformed JSON5 → returns error with diagnostics.
- `Config` — owns all heap memory; `deinit()` frees everything.
- `BrokerConfig` — per-template config struct (see field list in bxp-cli/CLAUDE.md).
- `BrokerConfig.validate(id, writer)` — validates config consistency (e.g. `$date` required
  when `date_filter_from_filename=true`).
- Config file size limit: `CONFIG_MAX_FILE_SIZE=1MB`.
- Internally uses `json5.zig` to preprocess JSON5 → standard JSON before `std.json` parsing.
- Inline unit tests (11) cover the pure did-you-mean / parsing helpers
  (`levenshteinIgnoreCase`, `closestBuiltin`, `closestKey`, `suffixOverlap`,
  `isAnnotationKey`, `extractQuotedName`, `jsonErrorDesc`) plus two
  `loadFromBytes` integration cases (enum/punctuation parse + invalid-enum
  warning). `loadFromBytes` allocates into a caller-owned arena — tests pass
  an `ArenaAllocator`, matching how bxp-fmt drives it.

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

Streaming JSON array-of-objects reader for bxp-cli input. Two-pass design
keeps RSS bounded (Scanner read buffer + one record at a time); no
whole-file slurp, no upper file-size limit.

- `scanColNames(name_alloc, io_reader, col_names)` — Pass 0: scans the
  whole array once, collects the union of object keys in first-seen order.
  Values are skipped via `skipValue`; no per-value allocation. Returns
  `error.JsonNotArray` / `error.JsonNotObjectArray` on shape mismatch.
- `RecordReader.init(self, parent_alloc, io_reader, col_index)` — opens
  a per-record streaming reader. Caller initialises in-place via `*Self`
  pointer (Scanner captures an Allocator handle into `self.scratch`;
  return-by-value would dangle that pointer → segfault on first alloc).
- `RecordReader.next(row_alloc)` — materialises the next record into a
  `[][]const u8` indexed by `col_index` order. Returns null at array end.
  Caller resets `row_alloc` between calls to bound per-row footprint.
- `RecordReader.recordStartOffset()` — source-file byte offset of the
  current record's `{` byte (CSV path emits the analogous offset via
  `LineSlice.byte_offset`).
- Pre_pass + main pass each rewind the file (`file.seekTo(0)`) and
  instantiate their own `RecordReader` against a fresh buffered reader.
- Value coercions: null → "", bool → "true"/"false", string → dupe,
  integer-like number → verbatim dupe, nested {}/[] → "". Plain non-integer
  decimals canonicalise via a **string-only trailing-zero trim** (no `f64`
  round-trip), mirroring the CSV passthrough invariant — so a high-precision
  JSON decimal (e.g. a 15-digit coordinate) survives intact. Scientific
  notation expands through the shared `decimal.zig` fixed-point core (exact
  to i128, float-free) — the same numeric core the CSV path uses at field
  access, so JSON and CSV turn an identical numeric string into an identical
  value. Out-of-i128-range literals pass through verbatim.

### btrace.zig

Binary framed trace stream emitted by `bxp-cli --trace`. The sole trace
format since the v0.3.0 NDJSON removal. Carries metadata only
(per-output-row pointers into source CSV/JSON, error list, pre_pass dump,
aggregate stats); per-row drill-down (vars, rules, output cell values) is
recomputed on demand by `bxp-fmt` seeking to a row's `source_locator`
byte offset.

- `Writer.init(w)` writes `FRAME_MAGIC` ("BXTB") once. There is no
  schema-version field — producer and consumer ship together in every
  release, so protocol drift is a build error, not a runtime concern.
- Writer methods: `writeFileStart`, `writeFileEnd`, `writeOutputRow`,
  `writeFilteredRow`, `writeErrorRow`, `writePrepassEntry`, `writeDone`.
- `Reader.init(r, alloc)` verifies the magic; `nextFrame()` returns
  `?Frame` (null at EOF). Unknown frame types are silently skipped via the
  `pay_len` prefix (forward compat).
- Each frame: `[1B type][2B chunk_id][4B pay_len][payload]`. `chunk_id` is
  reserved for future multicore chunk dispatch (always 0 today).
- Variable-length strings use length-prefix (lp): `[u32 len][bytes]`.
- Inline tests (14): per-frame roundtrip + adversarial UTF-8 + empty
  strings + forward-compat unknown-type skip + EOF returns null.

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

# Run unit tests (csv, json, btrace, expr, datefmt, decimal, unicode, json5, diagnostics, xlsx, config, docs):
cd bxp-core && zig build test
```

Module exports in `build.zig`: `csv`, `json`, `json5`, `xlsx`, `btrace`, `decimal`, `encoding`, `expr`, `config`, `docs`, `diagnostics`.
`expr` imports `datefmt.zig` and `unicode.zig` (both file-relative, not named modules) plus the named `decimal`, `uucode`, `encoding` modules; `config` imports `json5` (as `"json5.zig"` — internal import name), `diagnostics`, `expr`, `encoding`. `encoding` is a named module (not a file-relative @import) because it is shared by both `expr` and `config` — a file-relative @import from two modules would compile the file into each, a duplicate-symbol error (same reason `decimal` is named).
`docs` imports `config`, `expr`, `json5`; `diagnostics` has no bxp-core dependencies.

### External dependency: uucode

`bxp-core/build.zig.zon` pins one external (fetch) dependency: **uucode**
(MIT), the Unicode case-mapping / decomposition table library, on its
`zig-0.15` back-port branch (uucode's main line requires Zig 0.16 — revisit the
pin on the Zig 0.16 migration). `build.zig` requests only the `uppercase_mapping`
/ `lowercase_mapping` fields, so just those tables are generated + compiled in
(field selection keeps the binary small; the ReleaseSmall `bxp-cli` stays ~0.4 MB).
uucode is imported into the `expr` module and consumed by `unicode.zig`. Its own
table generator runs internally in Debug + LLVM, sidestepping the Zig 0.15.2
x86-backend codegen bug — our Debug `zig build test` is unaffected. `datefmt.zig`
and `decimal.zig` remain in-house with no dependency.

## Coding conventions

- All code comments and documentation in English.
- Zig 0.15.2 API.
- `processBroker()` in pipeline.zig and `load()` in config.zig are intentionally large
  (~320–336 lines) linear pipelines — do not split unless there is a concrete duplication problem.

## Known non-issues — deliberately not refactored

Audit follow-up rationale captured here so future audits don't re-flag
the same observations. If the rationale stops applying, revisit.

- **`xlsx.zig normalizeNumber` f64 sci-notation path — removed.** Up to
  2026-06-04 this expanded scientific notation through `f64` behind an
  `@abs(f) < 1e15` exactness guard. It now routes through the shared
  `decimal.zig` fixed-point core (exact across the full i128 range,
  float-free), the same numeric core json.zig and expr.zig use — so the
  xlsx, JSON and CSV input paths parse an identical numeric string into an
  identical value. The 1e15 guard is gone (Decimal is exact well past it),
  and fractional sci-notation now canonicalises too (`1.5E-3` → `0.0015`),
  not only whole-valued. Out-of-i128-range literals pass through verbatim.

- **`expr.zig adaptReplace` OOM detail.** A previous audit suggested
  routing OOM through the `setNotANumber` / `error_detail` convention so
  callers see a friendly diagnostic. Skipped: that convention works for
  type-mismatch errors (predictable, recoverable inputs), but OOM is
  systemic — the next `allocPrint` for the diagnostic itself would also
  OOM. We propagate `error.OutOfMemory` unchanged as a non-recoverable
  failure.

- **`config.zig loadFromBytes` partial `errdefer` coverage.** Only
  `data_dir` / `file_pattern_in` / `file_pattern_out` have `errdefer`s; the
  later locals (`ticker_map`, `input_schema`, `pre_passes`, `row_rules`,
  `output_schema`) leak if construction `return error.InvalidConfig`s
  mid-way (xlsx_sheet / csv_header_line / ticker_map bad-type). Harmless
  today: every production caller drives `loadFromBytes` with an
  `ArenaAllocator` and a config error exits the process (`process.exit(1)`),
  so the leak is reclaimed wholesale. Only matters if a future in-process
  caller (e.g. the GUI) ever catches `InvalidConfig` against a GPA and keeps
  running — add the missing `errdefer`s then. Flagged in the 2026-06-05 audit.

- **`expr.zig NOW()` builds its ISO string via `std.time.epoch`, not
  `datefmt`.** Cosmetic inconsistency with the "datefmt is the single date
  core" principle adopted after the sunrise removal. Harmless (current time is
  always positive, never hits the negative-year path), so not rerouted through
  `datefmt.epochDayToYmd` + `formatIsoDate`. Pure cleanup if ever touched.

- **Mixed `ArrayList` API style.** Most new code uses unmanaged `.empty` +
  `(alloc)` methods; a few spots keep legacy `std.array_list.Managed(...)`
  (`csv.zig unescapeQuotes`, `expr.zig normalizeMonthAbbrev`; `json.zig
  scanColNames` is `Managed` by signature, intentional). Works, just
  non-uniform — optional unifying cleanup, no functional impact.
