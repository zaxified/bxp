# CLAUDE.md — bxp-core

Internal Zig library shared by bxp-cli (and future packages).
For monorepo-level context see [`../CLAUDE.md`](../CLAUDE.md).

## Purpose

**bxp-core** — shared Zig modules for CSV parsing, xlsx conversion, expression evaluation,
JSON/JSON5 handling, configuration loading, and documentation aggregation.
Consumed by bxp-cli (conversion engine) and the stateless-inspect adapters
(bxp-mcp + bxp-gui-bridge, both via `inspect.zig`) as a local path dependency.

## Module overview

| Module        | File              | Public API                                                                |
| ------------- | ----------------- | ------------------------------------------------------------------------- |
| `csv`         | `csv.zig`         | `splitFields()`, `LineIterator`                                           |
| `xlsx`        | `xlsx.zig`        | `xlsxToCsv()`, `SheetSpec` — streams every XML part via `zipstream`       |
| `zipstream`   | `zipstream.zig`   | `Archive`, `EntryReader` — streaming ZIP central-dir walk + per-entry inflate (named module; shared by `xlsx` ingest + bxp-cli's parallel `zipPrePass`) |
| `expr`        | `expr.zig`        | `eval()`, `evalString()`, `Context`, `Value`, `FnDoc` catalog             |
| `datefmt`     | `datefmt.zig`     | `parse()`, `format()`, civil/arithmetic helpers — date core (file-rel @import by `expr.zig`, not a named module) |
| `decimal`     | `decimal.zig`     | `Decimal` fixed-point i128 @ 1e12 — numeric core (named `"decimal"` module, shared by every input path) |
| `unicode`     | `unicode.zig`     | `toUpperStr()`, `toLowerStr()`, `unaccentStr()` — UTF-8 case mapping + diacritic stripping over `uucode` tables (file-rel @import by `expr.zig`, not a named module) |
| `encoding`    | `encoding.zig`    | `Encoding`, `decodeToUtf8()`, `encodeFromUtf8()` — Layer 0 single-byte code page ↔ UTF-8 (named module; shared by `expr` + `config`; no `uucode` dep) |
| `config`      | `config.zig`      | `Config`, `BrokerConfig`, `load()`, `validate()`, `FieldDoc`              |
| `json`        | `json.zig`        | `scanColNames()` + `RecordReader` — streaming JSON array-of-objects input |
| `btrace`      | `btrace.zig`      | Binary trace `Writer` / `Reader` for `--trace=bin`                        |
| `json5`       | `json5.zig`       | `preprocess()` (internal; also exported for direct use)                   |
| `docs`        | `docs.zig`        | `writeDocs(alloc, writer)` — emits the language/schema docs JSON                   |
| `diagnostics` | `diagnostics.zig` | `Diagnostics`, `Diagnostic`, `Severity` — structured validation collector |
| `inspect`     | `inspect.zig`     | Shared stateless core: `annotateRaw()`, `validateExpr()`, `validateExprJson()`, `evalExpr()`, `evalTrace()`, `evalBatch()`, `docsJson()`, `listTemplates()`, `fetchTemplate()` — wrapped by bxp-mcp + bxp-gui-bridge |

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
- **Fully streaming** (since 2026-06-13): every XML part (workbook, rels, styles,
  sharedStrings, each worksheet) is parsed by streaming its decompressed bytes
  through the reader-driven `XmlTok` windowed tokenizer — opened via the
  `zipstream` module (`Archive` central-dir walk + per-entry `EntryReader`
  inflate). Nothing is materialised whole; the worksheet never lands in RAM, so
  the memory ceiling is O(inflate window + 128 KiB token window + shared-strings
  table + one output row), independent of workbook size. There is no temp dir,
  no size cap, and no `version_needed` fixup (the streaming reader reads local
  headers directly, so the XTB local-vs-central mismatch is a non-issue).
- The shared-strings table is the one resident structure (cells index into it by
  arbitrary position — irreducible), guarded defensively by
  `XLSX_SHARED_STRINGS_CAP` (1 GiB) against a zip-bomb → `error.FileTooBig`.
- `XmlTok` returns token slices into its window, valid only until the next
  `next()` (lazy O(n) compaction). A value held across calls is copied — the
  worksheet parser copies the tiny `cell_type` attribute from the `<c>` open to
  its close. A single token must fit in half the window (64 KiB) else
  `error.XmlTokenTooLong`.
- Supported cell types: shared strings, inline strings, formula results, booleans,
  plain numbers, date/time (detected via styles.xml numFmtId).
- XML parts are assumed UTF-8 (what Excel always writes). A UTF-16 BOM on the
  sheet or sharedStrings XML returns `error.Utf16XmlUnsupported` (`XmlTok.peekUtf16Bom`)
  instead of silently producing garbage; the pipeline turns that into a
  warn-and-skip. No `csv_*_encoding`-style transcode for xlsx — OOXML is
  effectively always UTF-8 in practice.
- Buffer sizes: `CSV_OUT_BUF_SIZE=65536`, `ZIP_WINDOW_SIZE=64KB` (inflate
  history), `XML_WINDOW_SIZE=128KB` (tokenizer window).
- Inline unit tests cover the pure helpers (`colRefToIndex`, `normalizeNumber`,
  `excelSerialToDatetime`, `unixDayToYMD`, `decodeEntities`, `isDateFormatCode`,
  `isBuiltinDateFmt`, `getAttr`, `stripNs`, `writeCsvField`, `hasUtf16Bom`). The
  ZIP central-dir walk + store/deflate read is unit-tested in `zipstream.zig`;
  end-to-end streaming (real deflate + XTB version mismatch) is gated
  byte-identical by the `xtb*` datasets (test-02).

### zipstream.zig

Streaming ZIP-archive reader — the shared primitive behind xlsx ingest and
bxp-cli's `zipPrePass` (the zipped-CSV unpacker). Walks the central directory
once and exposes each member as an on-demand `*std.Io.Reader` over its
decompressed bytes; a consumer's memory ceiling is O(one inflate window)
regardless of archive/entry size.

- `Archive.init(self, alloc, file)` — in-place init (holds the file reader's
  self-pointer); walks the central directory recording every entry (name +
  location + sizes). Borrows the file (does not close it). `find` / `findSuffix`
  locate an entry by exact name / suffix.
- `EntryReader.init(self, archive, entry, window)` — in-place; seeks to the
  entry's compressed data (reads the **local** header directly, so the
  central-vs-local `version_needed` mismatch some writers emit is irrelevant) and
  sets up streaming inflate (deflate) or a limited reader (store). `reader()`
  returns the decompressed-byte `*std.Io.Reader`. One archive drives one file
  cursor — finish one `EntryReader` before opening the next. (This single-cursor
  contract is why bxp-cli's parallel `zipPrePass` opens one `Archive` per worker:
  concurrent `EntryReader`s would race the shared cursor.)
- Store + Deflate only; anything else is `error.UnsupportedCompressionMethod`.
- Both `Archive` and `EntryReader` carry internal self-pointers — init in place,
  never move after init.
- Inline unit tests are small + functional (store-only, hand-built zips):
  enumeration / `find` / `findSuffix` and the streaming read of two entries off
  the shared cursor. The deflate path is covered end-to-end by the xtb datasets.

### expr.zig

Expression evaluator for `input_schema` and `row_rules` in bxp-cli.json.

- `eval(expr, ctx)` — parse and evaluate expression, returns `Value`.
- `evalString(expr, ctx)` — like `eval()` but coerces result to string.
- `Context` — per-row evaluation context: `fields`, `col_index`, `maps`,
  `lookup_table`, `alloc`, `decimal_sep_in`, `quote_out`, `input_encoding`,
  plus the per-file/row source context `filename` / `sheet_name` / `record_num`
  (behind `FILENAME()` / `SHEET_NAME()` / `RECORD_NUM()`; default ""/""/0 for
  stateless eval). `input_encoding` (Layer 0) transcodes each accessed field
  value to UTF-8 in `field()`; `.utf8` (default) is a zero-alloc pass-through.
- `Value` — union of `decimal: Decimal`, `string: []const u8`, `boolean: bool`.
  `Decimal` (in `decimal.zig`) is a fixed-point `i128` at scale 1e12 (12
  fractional digits): exact `+ −`, half-away-from-zero `× ÷` and `ROUND`. Replaces
  the former `f80` + `{d:.8}` print cap, so `0.02 + 0.08` is exactly `0.10`.
  Passthrough strings (coords, long IDs) bypass the core to keep full precision.
- `DATE_CONVERT()` date/time parsing and formatting is handled in-process by
  `datefmt.zig` (file-relative `@import`) — no external dependency. Pre-1970
  dates are fully supported (pure parse → format reshuffle, no epoch round-trip).
- Unit tests inline (150 test cases).

**Built-in functions:** IF, CASE, IFERROR, ABS, DATE_CONVERT, PRICE_VALUE,
PRICE_CURRENCY, REMAP, LOOKUP, SPLIT_PART, CONTAINS, REGEX_MATCH,
REGEX_EXTRACT, REPLACE, TRIM, ROUND,
FLOOR, CEILING, MOD, NOW, RAND, FILENAME, RECORD_NUM, SHEET_NAME, COALESCE,
FIELDS, UPPER, LOWER, UNACCENT, LEFT, RIGHT, SUBSTR, LPAD, RPAD, POSITION,
PROPER, STARTS_WITH, ENDS_WITH, NULLIF, IN, ISEMPTY, LEN, GREATEST, LEAST,
DATEADD, DATEDIFF, WORKDAY, YEAR, MONTH, DAY, WEEKDAY, EOMONTH, NTH_DOW.
IF/CASE/IFERROR are lazy (parse their own arg lists; only the selected /
non-erroring branch is evaluated). FILENAME/RECORD_NUM/SHEET_NAME read the
per-file/row `Context` and are excluded from constant-folding (`isRowInvariant`).
REGEX_MATCH/REGEX_EXTRACT compile a regex literal per call through the Pike-VM
engine (`quangd/regex.zig` fetch dep, linear-time/ReDoS-safe) in Unicode-scalar mode;
`\d`/`\w`/`\s` stay ASCII, so accented runs use an explicit class like
`[A-ZÁ-Ž]`. A bad pattern is a loud, pattern-attributed template error
(`error.BadRegexPattern`); a non-matching row is the lenient "" / false case.

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
  an `ArenaAllocator`, matching how the inspect adapters drive it.

**Doc catalog** (`pub const FieldDoc`, plus `pub const fields = [_]FieldDoc{...}`
on each public struct + `pub const scaffold_template` where a struct can be
scaffolded by the GUI): co-located with the struct each entry describes —
same pattern as `expr.FnDoc`. Adding a config field = update the struct AND
its `fields` table in one place. Aggregated by `docs.zig`; serves
the docs catalog.

### docs.zig

Aggregator for the language/schema docs catalog. Single source of truth that
the GUI (bxp-gui) consumes at startup.

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
recomputed on demand by the GUI (via the bridge) seeking to a row's
`source_locator` byte offset.

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
- Used by the config validator's deep validation pass. bxp-cli passes a null sink; existing
  fail-fast/stderr behavior is preserved.
- Severity routing in the annotated JSON output: `.@"error"` → `$err_<N>` object,
  `.warning` → `$warn_<N>` object, `.info` → `$info_<N>` object. Each object may contain
  `message`, `off`, `len`, `suggest` fields.
- Unit tests inline (1 test case).

## Build

```bash
# Build all modules (no standalone binary):
cd bxp-core && zig build

# Run unit tests (csv, json, btrace, expr, datefmt, decimal, unicode, json5, diagnostics, zipstream, xlsx, config, docs, inspect):
cd bxp-core && zig build test
```

Module exports in `build.zig`: `csv`, `json`, `json5`, `xlsx`, `zipstream`, `btrace`, `decimal`, `encoding`, `expr`, `config`, `docs`, `diagnostics`, `inspect`.
`xlsx` imports the named `decimal` and `zipstream` modules; `zipstream` has no bxp-core dependencies (std only).
`expr` imports `datefmt.zig` and `unicode.zig` (both file-relative, not named modules) plus the named `decimal`, `uucode`, `encoding`, `regex` modules (`regex` is the Pike-VM engine behind REGEX_MATCH/REGEX_EXTRACT — a fetch dep, see _External dependencies_ below); `config` imports `json5` (as `"json5.zig"` — internal import name), `diagnostics`, `expr`, `encoding`. `encoding` is a named module (not a file-relative @import) because it is shared by both `expr` and `config` — a file-relative @import from two modules would compile the file into each, a duplicate-symbol error (same reason `decimal` is named).
`docs` imports `config`, `expr`, `json5`; `diagnostics` has no bxp-core dependencies.

### External dependencies

`bxp-core/build.zig.zon` pins two external (fetch) dependencies, both
content-addressed by hash and re-audited on any pin bump:

- **uucode** (MIT) — the Unicode case-mapping / decomposition table library,
  on its `main` line (which requires Zig 0.16 — the former `zig-0.15` back-port
  branch was dropped at the Zig 0.16 migration). `build.zig` requests only the
  `uppercase_mapping` / `lowercase_mapping` fields, so just those tables are
  generated + compiled in (field selection keeps the static binary small).
  Imported into the `expr` module and consumed by `unicode.zig`.
- **regex** (`quangd/regex.zig`, Apache-2.0 OR MIT) — the Pike-VM
  regular-expression engine behind `expr.zig`'s `REGEX_MATCH` / `REGEX_EXTRACT`
  builtins. Pinned to an exact commit. Chosen by a 2026-06-17 security +
  capability audit for its zero transitive deps, OS-surface-free source (no
  `std.os`/`posix`/`net`/`process`/`fs`/`@cImport` anywhere), and guaranteed
  linear-time (ReDoS-proof) matching. The package exposes its engine as the
  module named `regex`; `build.zig` wires it into the `expr` module. Adds ~56 KB
  to the ReleaseSmall `bxp-cli` (engine + Unicode-scalar case-fold tables).

`datefmt.zig` and `decimal.zig` remain in-house with no dependency.

## Coding conventions

- All code comments and documentation in English.
- Zig 0.16.0 API.
- `processBroker()` in pipeline.zig (~930 lines) and `loadFromBytes()` in
  config.zig (~480 lines) are large, deliberately linear pipelines. Splitting
  them is pure reorganisation (no behaviour change), so weigh it against
  regression risk rather than doing it for line-count alone. `processBroker`'s
  combined-output path is now covered by `datasets/combined_output_demo`
  (test-02 gate); see the REFACTOR NOTE on the function. config's
  `loadFromBytes` is well-covered by test-01 + test-02 + inspect tests, so a
  per-section split there is lower-risk if a maintenance need arises.

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
  later locals (`maps`, `input_schema`, `pre_passes`, `row_rules`,
  `output_schema`) leak if construction `return error.InvalidConfig`s
  mid-way (xlsx_sheet / csv_header_line / maps bad-type). Harmless
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

### Audit notes (2026-06-14 full sweep — acknowledged, no action)

The 🔴/🟠/🟡 tiers from the 2026-06-14 audit are all fixed; these are the
residual 🔵 design observations. Greppable in-code marker: `AUDIT-OK`.

- **`csv.zig splitFields` silently drops fields past `buf.len`.** Correctness
  depends on the caller sizing `buf` ≥ the widest row. Resolved by the bxp-cli
  side: the body-row path sizes `field_buf` to `MAX_COLUMNS` and the header
  warning already flags any file wider than that (see the documented
  header/body asymmetry at `pipeline.zig fieldBufSlice`). A `MAX_COLUMNS`
  change must keep the two paths in sync.
- **`zipstream.zig` deflate path has no CRC32 / uncompressed_size check.** A
  corrupt/truncated entry yields whatever bytes inflate produced, silently —
  a data-integrity gap, not a memory-safety one (the consumer reads to EOF and
  stops; no zip-bomb exposure, that is window-bounded separately). Acceptable
  for the xlsx use case (the workbook is the user's own export).
- **`inspect.zig formatRootErr` shape ≠ injected-diagnostic shape.** Root
  errors emit `{"$err_1":"<msg>"}` (bare string); injected diagnostics emit
  `{"$err_N":{message,off?,len?,suggest?}}` (object). The in-code doc comment
  flags it; the GUI extractor branches on value type, so it is benign — but a
  new strict consumer must handle both. Worth unifying to the object form if
  the error surface is ever reworked.
- **`inspect.zig insertNumberedBefore` is O(K·N) per annotated object.** Each
  insertion re-dupes every key of the target object. Configs are ≤ 1 MB with
  small objects so cost is negligible; only a future "annotate a huge generated
  config" use-case would notice.
- **`inspect.zig` text entry points are uncapped.** `readFileCapped` enforces
  the 1 MB `CONFIG_MAX_FILE_SIZE` only on the `*FromFile` wrappers; the
  text-based entries (`annotateRaw`, `parseConfigText`, `evalBatch`) accept
  unbounded input by design — the size cap is the adapter's job (bxp-mcp
  request size, bridge FFI caller), and everything is arena-bounded + freed per
  request. Part of the cross-cutting "input caps live at the trust boundary"
  model (see the bxp-mcp / bxp-gui-bridge known-non-issues).
- **`config.zig diagDuplicateKey` compares only the trailing segment of an
  escaped key.** The non-allocating `std.json.Scanner` emits a final `.string`
  holding only the last segment of a key with JSON escapes, so the dedup
  compares tails and the caret column mis-points. Config keys with escapes are
  exotic (field names, `$vars`, headers), so impact is negligible.
- **`json5.zig preprocessAnnotated` recovery state machine** — `AUDIT-OK`
  anchor in-file: most intricate state machine in bxp-core, gate edits with the
  recovery unit tests + a fuzz pass. Not a bug today.
