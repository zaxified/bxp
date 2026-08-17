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
| `csvstream`   | _(zig-libs dep)_  | `splitFields()`, `LineIterator`, `LineSlice` + `ChunkReader` — the CSV record model and the record-aligned streaming reader. **No longer in this tree**: the record half was `csv.zig` here, the `ChunkReader` half was private to bxp-cli's `pipeline.zig`; upstream holds one module for both |
| `xlsx`        | `xlsx.zig`        | `xlsxToCsv()`, `SheetSpec` — streams every XML part via `zipstream`       |
| `zipstream`   | _(zig-libs dep)_  | `Archive`, `EntryReader` — streaming ZIP central-dir walk + per-entry inflate (named module; shared by `xlsx` ingest + bxp-cli's parallel `zipPrePass`). **No longer in this tree**: consumed from the pinned `zig_libs` fetch dep, which adds CRC-32 verification, a decompression-bomb cap, a zip-slip predicate, central-directory pre-validation and zip64 reading |
| `expr`        | `expr.zig`        | `eval()`, `evalString()`, `Context`, `Value`, `FnDoc` catalog             |
| `datefmt`     | _(zig-libs dep)_  | `parse()`, `format()`, civil/arithmetic helpers, `partsToUnix`/`unixToParts` seconds-epoch, `ZZ` offset token — the date core. **No longer in this tree**: consumed from the pinned `zig_libs` fetch dep as the named `datefmt` module (wired into `expr` in `build.zig`). The former local `datefmt.zig` was a strict subset of the upstream module — identical civil core, parser, formatter and token table, plus coverage and an `xsd:dateTime` entry point bxp does not call |
| `tz`          | _(zig-libs dep)_  | `find()`, `offsetAt()` — IANA UTC-offset lookup. **No longer in this tree**: consumed from the pinned `zig_libs` fetch dep as the named `tz` module (wired into `expr` in `build.zig`). The offset tables compile in, so there is still no runtime dependency. The former local `tz.zig` was a strict subset of the upstream module; its generator moved to `scripts/tz-gen/` in that repo |
| `decimal`     | _(zig-libs dep)_  | `Decimal` fixed-point i128 @ 1e12 — numeric core (named `"decimal"` module, shared by every input path). **No longer in this tree**: consumed from the pinned `zig_libs` fetch dep. Same arithmetic, different API — fallible ops return `Error!Decimal` not `?Decimal`, and `toString` writes into a caller buffer instead of allocating |
| `numparse`    | _(zig-libs dep)_  | `parseGroupedNumber()` — grouped-number parsing (`1,234.56` / `1.234,56`) into a `Decimal`, or null. **No longer in this tree**: `expr.zig` aliases the named module. Extracted below file level (it was never its own file here), and the code is byte-identical to the local original |
| `unicode`     | `unicode.zig`     | `toUpperStr()`, `toLowerStr()`, `unaccentStr()` — UTF-8 case mapping + diacritic stripping over `uucode` tables (file-rel @import by `expr.zig`, not a named module) |
| `encoding`    | _(zig-libs dep)_  | `Encoding`, `decodeToUtf8()`, `encodeFromUtf8()` — Layer 0 single-byte code page ↔ UTF-8 (named module shared by `expr` + `config`; no `uucode` dep). **No longer in this tree**: consumed from the pinned `zig_libs` fetch dep. The former local copy was a strict subset — the five 256-entry tables and both transcode entry points were byte-identical |
| `config`      | `config.zig`      | `Config`, `BrokerConfig`, `load()`, `validate()`, `FieldDoc`              |
| `json`        | `json.zig`        | `scanColNames()` + `RecordReader` — streaming JSON array-of-objects input |
| `btrace`      | `btrace.zig`      | Binary trace `Writer` / `Reader` for `--trace=bin`                        |
| `json5`       | _(zig-libs dep)_  | `preprocess()` + `preprocessAnnotated()` — JSON5 → JSON. **No longer in this tree**: consumed from the pinned `zig_libs` fetch dep. Unlike the others this was NOT a strict subset — the local copy was an older line still carrying two crashes and two JSON5-spec deviations upstream had fixed |
| `docs`        | `docs.zig`        | `writeDocs(alloc, writer)` — emits the language/schema docs JSON                   |
| `diagnostics` | _(zig-libs dep)_  | `Diagnostics`, `Diagnostic`, `Severity` — structured validation collector. **No longer in this tree**: consumed from the pinned `zig_libs` fetch dep. The former local copy was a strict subset (identical collector, fields and count methods) |
| `inspect`     | `inspect.zig`     | Shared stateless core: `annotateRaw()`, `validateExpr()`, `validateExprJson()`, `evalExpr()`, `evalTrace()`, `evalBatch()`, `docsJson()`, `listTemplates()`, `fetchTemplate()` — wrapped by bxp-mcp + bxp-gui-bridge |

## Module details

### csvstream _(zig-libs dep)_

RFC 4180 CSV parser + record-aligned streaming reader. **No longer in this
tree** — and it is the migration that reunited two halves bxp had kept apart:
the record model was `src/csv.zig` here, while the `ChunkReader` that feeds it
was private to `bxp-cli/src/pipeline.zig`. Upstream holds one module for both,
which is also where the invariant that ties them together is now documented.

- `splitFields(record, buf, delim, quote_ch, alloc)` — splits one record into
  field strings, up to `buf.len` fields. Unquotes quoted fields.
- `LineIterator.init(bytes, quote, base_offset)` — quote-aware iterator over
  records held in a single in-memory chunk; `next()` yields
  `LineSlice { bytes, byte_offset, unbalanced_quote }`.
- `ChunkReader.init(io, alloc, file, chunk_size)` — file → record-aligned
  chunks (each ending on its last `\n`), so peak memory is the chunk size, not
  the file size. `chunk_start_in_file` is what makes a record's absolute offset
  composable — that offset is the `--trace=bin` `source_locator` the GUI seeks
  to for drill-down.
- **The lazy-quotes rule is load-bearing and survived the move verbatim**: a
  `\n` ALWAYS ends a record (deliberately not RFC 4180 §2.6), so a stray quote
  is a one-line problem instead of swallowing the rest of the file — and every
  `\n` is therefore a safe chunk boundary, which is what lets the pipeline
  split blocks for parallel workers at all. The diff against the local copy was
  byte-identical here.
- One upstream guard is new: `max_record_len` → `error.RecordTooLong` on a
  newline-free input past the chunk size. bxp-cli adopts it deliberately (see
  the call-site note in `pipeline.zig`) and translates it into a diagnostic
  naming the file and the classic-Mac-line-endings suspicion.
- Spaces are preserved per RFC 4180. The bxp pipeline intentionally trims them
  _outside_ the parser: field values at access time in `expr.Context.field`,
  header names when building `col_index` in `bxp-cli/src/pipeline.zig`. Brokers
  frequently pad fields, so the rest of the pipeline (date parsing, numeric
  conversion, comparisons) sees clean values without the parser having to
  mutate the slices it returns.
- Tests live upstream: all 22 that were here verbatim, plus two fuzz harnesses,
  five BOM cases, the streaming-layer suite and the `maxogden/csv-spectrum`
  acid-test corpus. bxp's own gate is the datasets regression (test-07) and the
  real-broker-data run.

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
  ZIP central-dir walk + store/deflate read is unit-tested upstream in `zipstream`;
  end-to-end streaming (real deflate + XTB version mismatch) is gated
  byte-identical by the `xtb*` datasets (test-02).

### zipstream _(zig-libs dep)_

Streaming ZIP-archive reader — the shared primitive behind xlsx ingest and
bxp-cli's `zipPrePass` (the zipped-CSV unpacker). Walks the central directory
once and exposes each member as an on-demand `*std.Io.Reader` over its
decompressed bytes; a consumer's memory ceiling is O(one inflate window)
regardless of archive/entry size.

- `Archive.init(self, alloc, file)` — in-place init (holds the file reader's
  self-pointer); walks the central directory recording every entry (name +
  location + sizes). Borrows the file (does not close it). `find` / `findSuffix`
  locate an entry by exact name / suffix.
- `EntryReader.initMax(self, archive, entry, window, max_output)` — in-place;
  seeks to the entry's compressed data (reads the **local** header directly, so
  the central-vs-local `version_needed` mismatch some writers emit is
  irrelevant) and sets up streaming inflate (deflate) or a limited reader
  (store). `reader()` returns the decompressed-byte `*std.Io.Reader`, which
  verifies the entry's CRC-32 at end-of-stream. One archive drives one file
  cursor — finish one `EntryReader` before opening the next. (This single-cursor
  contract is why bxp-cli's parallel `zipPrePass` opens one `Archive` per worker:
  concurrent `EntryReader`s would race the shared cursor.)
- **Both bxp call sites use `initMax`, not `init`, deliberately.** `init`
  applies a 1 GiB `default_max_output` decompression-bomb cap; bxp passes
  `maxInt(u64)` instead, because a zipped broker CSV or a large worksheet can
  legitimately exceed that and neither path holds the entry in RAM (memory is
  O(inflate window)). bxp's size caps sit on the resident structures instead —
  see `XLSX_SHARED_STRINGS_CAP`. Revisit only if bxp ever unpacks an archive it
  did not get from the user.
- `isSafeEntryName(name)` — upstream's zip-slip predicate. bxp does **not** call
  it: `zipPrePass` derives its own flat output name (`zip_input.dir_mode`) and
  then rejects anything containing a separator, so its guard is strictly
  narrower than the predicate. Kept in mind if a future path ever writes member
  names through unchanged.
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
  `Decimal` (the zig-libs `decimal` module) is a fixed-point `i128` at scale 1e12 (12
  fractional digits): exact `+ −`, half-away-from-zero `× ÷` and `ROUND`. Replaces
  the former `f80` + `{d:.8}` print cap, so `0.02 + 0.08` is exactly `0.10`.
  Passthrough strings (coords, long IDs) bypass the core to keep full precision.
- `DATE_CONVERT()` date/time parsing and formatting is handled in-process by
  the zig-libs `datefmt` module (named import; the offset-table-free half of
  the date/TZ pair — no runtime dependency either way). Pre-1970 dates are
  fully supported (pure parse → format reshuffle, no epoch round-trip).
- Unit tests inline (150 test cases).

**Built-in functions:** IF, CASE, IFERROR, ABS, DATE_CONVERT, PRICE_VALUE,
PRICE_CURRENCY, REMAP, LOOKUP, SPLIT_PART, CONTAINS, REGEX_MATCH,
REGEX_EXTRACT, REPLACE, TRIM, ROUND,
FLOOR, CEILING, MOD, NOW, RAND, FILENAME, RECORD_NUM, SHEET_NAME, COALESCE,
FIELDS, UPPER, LOWER, UNACCENT, LEFT, RIGHT, SUBSTR, LPAD, RPAD, POSITION,
PROPER, STARTS_WITH, ENDS_WITH, NULLIF, IN, ISEMPTY, LEN, GREATEST, LEAST,
DATEADD, DATEDIFF, WORKDAY, YEAR, MONTH, DAY, WEEKDAY, EOMONTH, NTH_DOW,
TO_UTC, TZ_OFFSET, TZ_CONVERT, IS_DST.
IF/CASE/IFERROR are lazy (parse their own arg lists; only the selected /
non-erroring branch is evaluated).
TO_UTC/TZ_OFFSET/TZ_CONVERT/IS_DST resolve IANA offsets via the zig-libs `tz`
module (pinned fetch dep — see _External dependencies_ below); the `ZZ` datefmt
token carries the parse/format offset. See the datefmt/tz note
under _Module overview_. FILENAME/RECORD_NUM/SHEET_NAME read the
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

### encoding _(zig-libs dep)_

Layer 0 of the Unicode subsystem: legacy single-byte code page ↔ UTF-8
transcoding (the "iconv" job). No `uucode` dependency — just 256-entry mapping
tables. **No longer in this tree** — the named `encoding` module comes from the
pinned `zig_libs` fetch dep; what bxp still owns is the *policy* that drives
it: the per-template `csv_input_encoding` / `csv_output_encoding` config keys
(config.zig) and the per-field decode / write-time encode call sites
(expr.zig, pipeline.zig). **CSV only**: JSON (RFC 8259) and xlsx (XML-in-ZIP)
are always UTF-8 and never reach here.

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
- Tests live upstream (17 + a codec fuzz harness + exhaustive cross-checks of
  all five high-tables against vendored normative WHATWG `index-*.txt` /
  Unicode.org `8859-1.TXT` sources). The bxp-side gate is the CSV edge:
  `datasets/ruian_zip_demo` (real Windows-1250 RÚIAN address data → UTF-8,
  byte-diffed against `.expected` by test-07).

### config.zig

JSON5 configuration loader.

- `load(alloc, config_path)` — reads and parses bxp-cli.json; returns `Config`.
  Missing file → returns empty Config. Malformed JSON5 → returns error with diagnostics.
- `Config` — owns all heap memory; `deinit()` frees everything.
- `BrokerConfig` — per-template config struct (see field list in bxp-cli/CLAUDE.md).
- `BrokerConfig.validate(id, writer)` — validates config consistency (e.g. `$date` required
  when `date_filter_from_filename=true`).
- Config file size limit: `CONFIG_MAX_FILE_SIZE=1MB`.
- Internally uses the `json5` module to preprocess JSON5 → standard JSON before `std.json` parsing.
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
  notation expands through the shared `decimal` fixed-point core (exact
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

### json5 _(zig-libs dep)_

Preprocessor that converts JSON5 source to standard JSON. **No longer in this
tree** — the named `json5` module comes from the pinned `zig_libs` fetch dep.

- `preprocess(alloc, input)` — strips `//` and `/* */` comments, converts unquoted keys
  to quoted keys, removes trailing commas, converts single-quoted strings to double-quoted.
- `preprocessAnnotated(alloc, input)` — the recovering variant behind
  `inspect.annotateRaw`: same transform, but syntax errors become sibling
  `$err_<N>` entries instead of aborting, so the GUI can render diagnostics
  against a still-parseable document.
- Implemented as a single-pass tokenizer — no external dependencies.
- Tests live upstream (27 + two fuzz harnesses + the json5/json5-tests
  conformance corpus).
- **This module is the one migration that changed behaviour** (2026-08-16).
  The local copy was an older line; upstream's fuzzer and the conformance
  corpus had already fixed four things it still carried:

  | Input | local copy | upstream |
  | ----- | ---------- | -------- |
  | `{a b` (unquoted key, no `:` before EOF) | out-of-bounds slice → **panic** | `$err_trace` diagnostic |
  | trailing `\` inside a string | `skipValue` returns `len + 1` → **OOB read** | clamped to `len` |
  | `//` comment ended by a bare `\r` | swallows the rest of the file | `\r` terminates the comment |
  | `/* …` with no `*/` | silently stripped to EOF (**accepted**) | bytes pass through → `std.json` rejects |
  | `[,]`, `{,}`, `[1,,]` | comma elided → `[]` / `{}` (**accepted**) | left in place → rejected |

  The last two are must-reject cases in the conformance corpus, so the local
  copy was not merely lenient — it did not conform. The first two were live
  crashes: a typo'd config aborted the process with a core dump.
  Migration was gated on all 63 configs in the repo + the real working config
  producing **byte-identical annotated output**, so the GUI contract is
  unchanged for anything that was already valid.

### decimal _(zig-libs dep)_

Fixed-point `i128` at scale 1e12 — the numeric core behind `Value.decimal` and
the csv / json / xlsx number canonicalisation. **No longer in this tree.**

The arithmetic is unchanged: same representation, same half-away-from-zero
rounding on `×` `÷` `ROUND`, same parse acceptance and same formatted output.
Verified on a 1766-row × 23-column operand matrix (40 618 cells, spanning
1e-12 to the i128 ceiling, both signs, half-way values, scientific notation,
grouped/European forms) against a pre-migration binary: byte-identical,
including all 126 per-cell expression errors.

The **API** did change, and the call sites in `expr.zig` / `json.zig` /
`xlsx.zig` were rewritten for it:

- Fallible operations return `Error!Decimal` (`add`/`sub`/`mul`/`neg`/`abs`/
  `fromInt`), `DivError!Decimal` (`div`), `ParseError!Decimal` (`parse`) —
  not `?Decimal`. bxp maps them back onto its own error names
  (`NumberOverflow`, `NumberOutOfRange`, `NotANumber`) so user-facing messages
  are unchanged; `fromIntChecked` in expr.zig is that adapter.
- `toString` writes into a caller-provided `[Decimal.str_buf_len]u8` and
  returns a slice into it, instead of allocating. Callers that need the result
  to outlive the frame `dupe` it. This removed an allocation per numeric
  output cell and is why the migration made the binary ~2 KB smaller.
- `parseGroupedNumber` deliberately keeps its `?Decimal` contract
  (`catch null` internally): its callers treat "not a number" as a fallback
  condition, not an error to propagate, so the optional stops at that boundary.
  That function has since moved out of `expr.zig` too — see `numparse` below.

The typed error set also fixed a live crash. `div` previously returned plain
`null` for a zero divisor and `@intCast`-panicked on overflow — the caller
could not tell the two apart, so a template like `[big] / 0.000000000001`
aborted the process with a core dump. `error.DivisionByZero` and
`error.Overflow` now split at the call site: the first keeps the documented
blank-cell behaviour for blank divisors, the second is a loud
`NumberOverflow` exactly like `*` already was. Upstream also added overflow
guards to `floor`, `ceil` and `parse`; those are forward cover — probing
confirmed they are not reachable through the expression surface today.

### numparse _(zig-libs dep)_

`parseGroupedNumber(s, thousands_sep, decimal_sep) ?Decimal` — the
thousands-grouped number parser behind three `expr.zig` call sites:
`Value.toNumber`'s fallback after a plain `Decimal.parse` fails,
`stringIsNumeric` (which argument GREATEST/LEAST blames), and
`normalizeFieldDecimalSep`'s European grouped shape. **No longer in this tree**
— `expr.zig` aliases the named module (`const parseGroupedNumber =
@import("numparse").parseGroupedNumber;`).

This is the first migration where the extraction went **below file level**: the
function never had a file of its own here, so no local file was deleted — only
the definition and its two tests. The diff against the local original was
byte-identical code; every hunk was a comment, a parameter rename
(`thousands`/`decimal` → `thousands_sep`/`decimal_sep`, avoiding a collision
with the `decimal` dependency's name) or `pub`. Upstream adds two reject-case
tests (more than 3 leading digits; a trailing decimal separator with no digits
after it).

Grammar and contract are unchanged and still load-bearing here: at least one
thousands group is required (so plain `"123"` / `"1.5"` stay `Decimal.parse`'s
job and this is only ever the fallback), the structural validation is strict
(1–3 leading digits, exact 3-digit groups, no trailing junk — what keeps
`"2025,06,01"` and American input read under European separators from parsing
as numbers), and the return stays `?Decimal` rather than an error union.

The bxp-side gate was a 50-row × 8-column fixture run under **both** separator
conventions (100 rows, 800 cells) against the pre-migration binary: valid
American and European grouped forms, the reject shapes above, i128-boundary
and over-length inputs, high-precision coordinates, `nan`/`inf`, and
double-separator junk. Byte-identical, including all 318 per-cell expression
errors. `.text` and `.rodata` came out byte-identical too.

### diagnostics _(zig-libs dep)_

Structured diagnostics collector for config/json5/expr validation. **No
longer in this tree** — the named `diagnostics` module comes from the pinned
`zig_libs` fetch dep; the local copy was a strict subset. The one thing its
header carried that upstream's does not is the bxp-specific
`$err_`/`$warn_`/`$info_` severity routing, which now sits next to the switch
that implements it in `inspect.zig`.

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

# Run unit tests (json, btrace, expr, unicode, xlsx, config, docs, inspect):
cd bxp-core && zig build test
```

Module table in `build.zig` — 14 names in two halves. Seven are `b.addModule` entries built from this package's own sources: `json`, `btrace`, `xlsx`, `expr`, `config`, `docs`, `inspect`. Seven are zig-libs modules pushed into the table by the local `reexport()` helper so downstream packages can ask for them by name: `json5`, `diagnostics`, `minisign`, `procrun`, `mcp`, `csvstream`, `zipstream`. Everything else bxp-core takes off the zig-libs handle — `decimal`, `encoding`, `numparse`, `tz`, `datefmt` — is a plain local binding wired into the imports below; nobody downstream asks for those by name, so they are deliberately **not** re-exported.
`xlsx` imports the named `decimal` and `zipstream` modules; `zipstream` has no bxp-core dependencies (std only).
`expr` imports `unicode.zig` (file-relative, not a named module) plus the named `decimal`, `numparse`, `uucode`, `encoding`, `regex`, `tz`, `datefmt` modules (`regex` is the Pike-VM engine behind REGEX_MATCH/REGEX_EXTRACT; `tz`, `datefmt`, `encoding` and `numparse` come from zig-libs — all fetch deps, see _External dependencies_ below); `config` imports `json5`, `diagnostics`, `expr`, `encoding`, `xlsx` (the last one for `xlsx.listSheets`, which backs the sheet-name resolution in template validation). `encoding` being a named module matters for the same reason `decimal` is one: it is shared by both `expr` and `config`, and a file-relative @import from two modules would compile the file into each — a duplicate-symbol error.
`docs` imports `config`, `expr`, `json5`; `diagnostics` has no bxp-core dependencies.

### External dependencies

`bxp-core/build.zig.zon` pins three external (fetch) dependencies, all
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
- **zig_libs** (MIT, `zaxified/zig-libs`) — the module collection supplying
  the **twelve** modules below. Eight of them used to live in `src/` (`tz`,
  `datefmt`, `encoding`, `json5`, `decimal`, `zipstream`, `diagnostics` and
  the `LineIterator`/`splitFields` half of `csvstream`, which was `csv.zig`);
  `numparse` came from below file level, a function inside `expr.zig`.
  The remaining three — `minisign`, `procrun`, `mcp` — were never bxp-core
  sources at all, and neither was `csvstream`'s `ChunkReader` half (that one
  was private to `bxp-cli`'s `pipeline.zig`):

  - `tz` — IANA UTC-offset lookup behind `TO_UTC` / `TZ_OFFSET` /
    `TZ_CONVERT` / `IS_DST`.
  - `datefmt` — the date core behind `DATE_CONVERT` and every calendar
    builtin.
  - `encoding` — single-byte code page ↔ UTF-8 behind `csv_*_encoding`.
  - `json5` — the JSON5 → JSON preprocessor behind config loading and
    `inspect.annotateRaw`. This one is also re-exported into bxp-core's own
    module table (`b.modules.put`), because a downstream package asks for it
    by name: `core_dep.module("json5")` in `bxp-cli/build.zig`.
    `dependency().module()` alone does not register it, and the downstream
    build panics with "unable to find module 'json5'".
  - `decimal` — the fixed-point numeric core behind `Value.decimal` and the
    csv / json / xlsx number canonicalisation.
  - `zipstream` — the streaming ZIP reader behind xlsx ingest and
    `zipPrePass`. Re-exported like `json5` (bxp-cli asks for it by name).
  - `diagnostics` — the structured validation-finding collector behind the
    inspect core's deep validation pass. Also re-exported (bxp-cli asks for
    it by name).
  - `numparse` — the grouped-number parser (`1,234.56` / `1.234,56`) behind
    `expr.zig`'s numeric coercion fallback. The one extracted from below file
    level: it was never its own file here, only a function.
  - `minisign` — the signature format behind the GUI updater's
    `bridge_verify_minisign`.
  - `procrun` — the reap-race-tolerant `waitTolerant` / `ensureChildReaping`
    behind the bridge's `bxp-cli` spawns.
  - `csvstream` — the CSV record model + `ChunkReader` behind every CSV input
    path. Re-exported like `json5` / `zipstream` (bxp-cli asks for it by name).
  - `mcp` — the MCP / JSON-RPC 2.0 server transport behind `bxp-mcp`. The one
    module that travelled the other way first: upstream's copy is this repo's
    former `bxp-mcp/src/server.zig`, extracted 2026-07-04 and hardened there,
    then consumed back on 2026-08-16.

  `minisign`, `procrun` and `mcp` are the modules bxp-core does **not** import
  at all: they are re-exported purely so `bxp-gui-bridge/build.zig` and
  `bxp-mcp/build.zig` can take them off this package's single pin instead of
  adding a second `zig_libs` entry of their own that would have to be bumped in
  lockstep.

  Pinned to the commit behind a dated release tag (upstream tags
  `YYYY-MM-DD`, no semver). `build.zig` takes all of them off **one shared
  `b.dependency` handle** — that is what makes them one compilation rather
  than several; `tz` imports `datefmt` internally, so while the local copy
  existed the binary carried two separate date cores. The 600-zone offset
  tables are compiled into `tz`, so this stays a build-time dependency only —
  no runtime tzdata lookup, exactly as the former in-tree copies behaved.
  Size effect on the ReleaseSafe `bxp-cli`: `tz` added ~8 KB (the extra
  `Jn`/`n` POSIX rule forms), `datefmt` gave ~4 KB back (the duplicate core
  collapsed), `encoding` and `json5` were neutral — measure in the SAME
  working tree, a `git worktree` build inflates the apparent delta by ~18 KB
  of longer path strings in ReleaseSafe panic data.

  **Treated as a foreign upstream** — read-only, pinned, never edited from
  this repo. Zig's package manager offers no floating "latest" mode: the
  `hash` field is mandatory and content-addressed, so any upstream movement
  must land as an explicit `zig fetch --save` edit to `build.zig.zon`.
  Finishing the extraction is the `v1.0.0` milestone in `docs/dev/roadmap.md`;
  the modules taken so far, with their measured divergence, are the table
  above plus the per-module sections in this file.

The split is now clean. What remains in `src/` is bxp's own domain layer —
`json`, `xlsx`, `btrace`, `expr`, `config`, `docs`, `unicode`, `inspect` — and
every general-purpose primitive underneath it (`datefmt`, `tz`, `encoding`,
`json5`, `decimal`, `zipstream`, `diagnostics`, `numparse`, `csvstream`)
comes from zig-libs. Anything new that is not bxp-specific belongs upstream,
not here.

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
  `decimal` fixed-point core (exact across the full i128 range,
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
- ~~**`zipstream` deflate path has no CRC32 / uncompressed_size check.**~~
  **Resolved 2026-08-16** by the zig-libs migration: `EntryReader` now
  accumulates a CRC-32 over every decompressed byte and checks it at
  end-of-stream. Before that, a stored entry whose content had been altered
  while its checksum was left intact converted with `exit 0` and produced
  silently wrong output — demonstrated against the pre-migration binary.
  Both ingest paths translate the mismatch rather than passing the generic
  `ReadFailed` through (the Reader vtable has a fixed error set, so zipstream
  reports the reason out of band via `EntryReader.crcMismatch()`):
  `zipPrePass` → `error.ZipEntryCorrupt`, and `xlsx.zig`'s `PartCtx.mapCrc`
  → `error.XlsxEntryCorrupt`, applied at all three entry points that drive a
  part read (`Workbook.init`, `extractSheet`, `xlsxToCsv`) — `extractSheet` is
  the one bxp-cli's sheet fan-out actually calls.

  **This was not an XTB workaround.** XTB's known quirk is a different one —
  `version_needed` 45 in local headers vs 20 in the central directory, which
  `std.zip.extract` rejected outright until the streaming rewrite made it moot
  (the local header is read directly). All 18 real XTB workbooks verify clean
  against `zipfile.testzip()`, and the live run puts every one of them through
  the CRC-verifying reader.
- **`inspect.zig formatRootErr` shape ≠ injected-diagnostic shape.** Root
  errors emit `{"$err_1":"<msg>"}` (bare string, reachable for `op:config`
  only when the file cannot be read or preprocessed); injected diagnostics
  emit `{"$err_N":{message,off?,len?,line?,col?,suggest?}}` (object). The
  in-code doc comment flags it. **The "benign" claim this note used to make
  was wrong** — it held for the GUI's *display* extractor
  (`TraceStore._extractDiagnostics`, which branches on value type) but not
  for its *pre-save guard* (`TraceStore._firstErrTraceIn`), which matched
  `$err_*` only when the payload was a bare `String`. Once the injected
  markers became objects, that guard matched nothing the bridge produces at
  save time, so a config whose only error is a Zig-side cross-field rule
  (e.g. `date_filter_from_filename` without `$date` in `input_schema` — the
  Dart validator has no counterpart) saved successfully and cleared the undo
  stack over a broken file. **Fixed 2026-08-17**: the guard now delegates
  payload extraction to the same `_diagMessage` helper the display extractor
  uses, so both shapes work and the two walkers cannot drift apart again;
  pinned by `bxp-gui/test/save_guard_test.dart`. The dual shape itself
  remains — a new strict consumer must still handle both. Worth unifying to
  the object form if the error surface is ever reworked.
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
- **`preprocessAnnotated` recovery state machine** — carries an `AUDIT-OK`
  anchor in the upstream `json5` module: the most intricate state machine
  either tree has, so gate edits with the recovery unit tests + a fuzz pass.
  Now upstream's concern, not this repo's.
