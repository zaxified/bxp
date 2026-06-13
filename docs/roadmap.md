# Roadmap

> [← docs/](README.md)

Backlog. Hand-maintained — entries get crossed out / deleted as work
lands on master. `CHANGELOG.md` is generated independently from `git log`
at release time by `scripts/release-changelog.sh` and is not coupled
to this file.

## v0.2.5

### External template JSON files

Today bxp-cli has no concept of a template library: all templates live
inside one user-owned config file (`bxp-cli.json`), and the starter
set ships as a single monolithic `resources/console/bxp-cli.examples.json`.
Users who want a specific broker template have to copy/paste it out of
the examples file into their own config. Split the starter set into a
per-broker template library so:

- A discovery dir (`templates/revolut.json`, `templates/trading212.json`,
  …) ships next to the binary; users can also drop their own files into
  a per-user dir and the discovery merges both with the user dir winning
  on name collision.
- bxp-mcp's `bxp_list_templates` / `bxp_fetch_template` work without a
  user-owned `bxp-cli.json` — they enumerate the discovered library.
- Per-broker variants can be added or revised independently without
  re-shipping one bloated examples file.

Open design questions to resolve before implementation:

- Discovery path order — bundled `templates/*.json` next to the binary,
  then `~/.config/bxp/templates/` (Linux) / `%APPDATA%\bxp\templates\`
  (Windows) / `~/Library/Application Support/bxp/templates/` (macOS)?
- JSON5 or strict JSON for template files? (consistency with config
  loader argues JSON5).
- Migration: keep `bxp-cli.examples.json` working during the transition
  or replace it outright on the v0.2.5 cut.
- `--list-templates` / `--fetch-template` semantics when the same name
  exists in bundle + user dir.

### Future example candidates (low priority)

Carried over from the (now-deleted) `DEV/*-todo` scratch when the example
backlog was otherwise exhausted:

- **`olist_ecommerce`** real-world multi-file normalisation — Kaggle
  CC-BY-NC-SA; the login wall conflicts with a no-login `fetch-full.sh` → needs
  a mirror or a different multi-file dataset.
- **`czech_public_contracts`** (smlouvy.gov.cz, CC0) — `DD.MM.YYYY` +
  space-thousands + contract-type maps; confirm a stable export URL + a cited
  problem first.
- **`basic/csv-to-json`** teaching example — isolated CSV → JSON array
  (`file_type_out: json`), the basic-tier mirror of `squirrel-census-json`. Low
  priority: JSON _output_ is already shown by `advanced/multi-stage-etl`.

## v0.3.0

### Auto-updater security audit & hardening

Shipped in v0.2.4: `_verifyChecksum` is fail-closed — missing
`SHA256SUMS`, fetch failure, asset not listed in SUMS, and hash mismatch
all refuse the install with a specific message. Release page link in
the dialog remains as the user's escape hatch.

Remaining hardening for v0.3.0 — treat as one cohesive audit pass:

- **Sign `SHA256SUMS`** (biggest gap). Checksum-only verification fails
  if a release is compromised wholesale (leaked PAT, account takeover):
  attacker uploads matching installer + matching SUMS. Add minisign /
  cosign signature (`SHA256SUMS.sig`) + embed public key in the binary;
  verify signature before trusting the SUMS contents. Trade-off: key
  storage + rotation policy on the release side.
- **Release-time tests so a broken release fails loudly.** Post-release
  smoke job in `.github/workflows/release.yml` that fetches
  `releases/latest`, asserts `SHA256SUMS` exists, and asserts every
  installer asset (`bxp-desktop-{windows-x86_64.exe, macos-arm64.dmg,
linux-x86_64.AppImage}`) has a matching line. Local gate inside
  `scripts/release-03-checksums.sh` to re-verify hashes + count lines
  before upload. Dart unit test for `UpdaterService` covering all four
  `_ChecksumResult` variants.
- **Shell injection surface in macOS installer dispatch.**
  `_installMacOS` uses `bash -c` with `$dmgPath` interpolated; today
  the asset-name regex blocks anything weird, but defensively switch
  to `Process.run('hdiutil', [...])` with argument arrays, or validate
  `assetName` against `[A-Za-z0-9._-]+` before use.
- **Path-traversal hardening on `assetName`.** `info.assetName` comes
  from the GitHub API and is joined into `tmpDir`; wrap with
  `p.basename(...)` so a malformed asset name can't escape the temp
  directory.
- **TOCTOU window on the AppImage path.** `_installLinuxAppImage`
  re-reads the verified file with `readAsBytes` after the hash check,
  reopening a swap window in `/tmp`. Either reuse the bytes already
  read during verification or stream both the hash and the write from
  one `RandomAccessFile`.

Track as a single "auto-update hardening" workstream — these layer on
each other (e.g. signed SUMS removes the need for parts of the CI
test, path validation removes part of the shell-injection concern).

## v0.4.0

### Streaming `.xlsx` ingest — SHIPPED 2026-06-13

CSV and JSON paths went streaming in earlier releases (CSV via
`ChunkReader` + `csv.LineIterator`; JSON via `std.json.Reader`). `.xlsx` was
the last path with an `O(workbook size)` ceiling; it is now streaming too.

**What shipped.** A new shared streaming-ZIP primitive
(`bxp-core/src/zipstream.zig`: central-directory walk + per-entry inflate,
exposing each member as a `*std.Io.Reader` over its decompressed bytes) plus a
reader-driven `XmlTok` (windowed pull-tokenizer that scans a 128 KiB window with
lazy O(n) compaction). Every XML part is now parsed by streaming it through the
tokenizer — no part is materialised whole; the worksheet never lands in RAM. The
shared-strings table is the only resident structure (cells index into it by
arbitrary position — irreducible, an industry-wide constraint), guarded
defensively by `XLSX_SHARED_STRINGS_CAP` (1 GiB) against a zip-bomb.

**Deleted as a result:** the dual extraction backend (`ZipParts`,
`extractZipToMemory`, the on-disk temp-dir path), `fixZipLocalVersionNeeded`
(zipstream reads local headers directly, so the XTB `version_needed` mismatch is
a non-issue), and _every_ size cap (`XLSX_MAX_FILE_SIZE`, `XLSX_INMEM_LIMIT`,
`XLSX_INMEM_TOTAL_CAP`). Temp-dir hygiene hazards (read-only data dirs,
antivirus) are gone with the temp dir.

**Measured** (ReleaseSmall, synthetic worksheet-dominated workbook): a 206 MB
uncompressed worksheet went **393 MB → 37 MB peak RSS** (~10×; the residual is
the downstream CSV-processing phase, not xlsx ingest), wall +18 %. Workbooks
above the old 100 MB-zip cutoff — which previously failed outright with
`FileTooBig` — now convert. Correctness gated byte-identical by the `xtb*`
datasets (real deflate + version mismatch).

**Decision:** went straight to true streaming (not the cheap cap-raise) because
the user wants the same primitive to back a future zipped-CSV pre-pass.

Remaining (not blocking):

- **Bench harness entry** for the synthetic `.xlsx` (the `DEV/xlsx-bench`
  generator exists; wire a point into `scripts/test-07-bench-guard.sh`).

### Zipped-CSV pre-pass (`zip_input`) — deferred, primitive ready

The `zipstream` primitive above was designed reusable for this. A template
opts in (config **A**, explicit: `zip_input: { entry_pattern: ".csv" }`); the
pre-pass enumerates **all** matching `.csv` members of each `*.zip` in
`data_dir` (N CSVs per zip, not 1:1) and streams each out to `data_dir` named by
its **entry name inside the zip**, then the normal CSV pipeline runs. Real
use-case: `ruian_adr.zip` (~8000 `cityname.csv` members). Mirrors `xlsxPrePass`.
No `zipstream` refactor needed — only `pipeline.zig` + a `config.zig` field.
Details to be settled when picked up.

### Future parallelism for ZIP ingest — deferred

The streaming conversion (`xlsxPrePass` / a future zipped-CSV pre-pass) is
single-threaded today. DEFLATE of **one** stream is inherently serial — each
block depends on the prior 32 KiB output window (LZ77 back-refs), so no ZIP
implementation parallel-decodes a single stream (pigz parallelises compression
only; bgzip/BGZF needs the writer to emit a special block format Excel doesn't).
Two real levers, revisit when ingest throughput matters:

- **Multi-entry parallelism (the big win for the zipped-CSV pre-pass).** A ZIP
  with many members is embarrassingly parallel — each entry is an independent
  DEFLATE stream. `zipstream.Archive` already enumerates entries; a worker pool
  could decompress N entries on N threads. Marginal for `.xlsx` (few parts) but
  ideal for `ruian_adr.zip` (~8000 CSVs).
- **Reader/worker pipelining (for one large worksheet).** Overlap the serial
  inflate+tokenise (producer) with the downstream parallel CSV processing
  (consumer) — convert block N+1 while processing block N. Doesn't make inflate
  parallel; hides its cost behind work already happening. Same lever as the CSV
  "reader cap" under _bxp-cli → Parallelism follow-ups_.

## Later (no specific version)

### CI hardening

The CI matrix (`.github/workflows/ci.yml`, shipped v0.2.4) runs
`scripts/test.sh` on every pull request and master push across
`ubuntu-latest` / `macos-latest` / `windows-latest`. `test.sh` is fully
cross-platform — including the perf bench, which self-measures wall + peak
RSS via bxp-cli's `BXP_METRICS` env var instead of GNU `/usr/bin/time`.
Remaining:

- Flutter `integration_test` smoke run inside CI (Xvfb on Linux runners,
  headless setup on Mac / Win). The current legs run `flutter analyze` +
  `flutter test` (widget/unit) but not a launched-app integration smoke.
- Pin `subosito/flutter-action` to an explicit Flutter version. CI's
  `channel: stable` floats ahead of local SDKs, so a newer `flutter
  analyze` can surface fresh `info` lints that fail CI while passing
  locally (hit 2026-06-07: `use_null_aware_elements` on stable 3.44.1 vs
  local 3.41.9). A pin makes CI reproducible; bump deliberately.

### Distribution polish

- Apple Developer ID notarisation for macOS `.app` (~$99/year).
  Eliminates the first-launch Gatekeeper warning.
- Windows Authenticode signing for the NSIS installer (~$200/year cert).
  Eliminates the SmartScreen warning.
- Flatpak publishing on Flathub. Review process takes weeks; defer
  until app is more stable.

### bxp-cli

- `xlsx_sheet.name` validation under the `--check-fs` umbrella. Verify
  the named sheet exists inside the `.xlsx` file during the filesystem
  check phase.

- **`data_dir` multi-dir / array (`data_dir: [...]` or a `*` glob segment).**
  Audit 2026-06-13, deferred. Brokers that export into dated
  subdirectories (`exports/2026-06/`) need config edits per month today.
  Accepting an array of dirs (process all listed) or a `*` glob path segment
  would close that recurring operator chore. Demand-driven — only if a real
  workflow asks; examples/ currently show flat dirs.

- **Parallelism follow-ups** (from a 2026-06-09 review of
  [judofyr/spice](https://github.com/judofyr/spice), a sub-ns-overhead
  fork/join library). Spice's heartbeat scheduling targets _irregular,
  recursive_ fork/join (unknown task granularity); our row pipeline is
  _regular, coarse-grained_ data-parallelism with a static even
  partition (`processBlockParallel` splits a block into `K = lines.len/K`
  equal slices), so heartbeat itself doesn't apply. Two takeaways do:
  - **Serial fast-path for tiny blocks (cheap, low-risk).** `processBlockParallel`
    routes through `spawnWg` + `WaitGroup` even when `K == 1` (single CPU)
    or the block is a handful of rows — pure barrier overhead. Add an inline
    branch (`K == 1` / block under a small row threshold → loop on the
    calling thread, no pool) so the small/serial case never pays the
    fork-join tax. This is Spice's "never regress the serial case" principle.
  - **Reader/worker pipelining (the real scaling lever, bigger).** Our cap
    is the serial read+parse phase that does not overlap with the workers
    (read block → fork → wait → drain → read next); that's an Amdahl
    serial-fraction limit (the bench "reader cap"), solved by
    double-buffering the reader (parse block N+1 while workers process N),
    **not** by finer scheduling. Separate, larger workstream.
  - Spice _would_ be the right tool if a recursive/irregular workload ever
    lands (e.g. large multi-sheet `.xlsx` with nested ZIP/XML walks).
    Revisit then.

### Real-world broker CSV quirks

Surfaced by readme-adequacy simulations against real broker formats
(Schwab brokerage, Lime.co via leppa/convert-to-wealthfolio). Each
quirk is a real broker-export pattern that the current bxp-cli template
language can't express cleanly; the workaround today is "tell the user
to pre-process the file" or "skip the affected rows".

- **Multi-CSV-in-one-file (blank-line separated).** Some brokers
  concatenate multiple sub-CSVs into a single `.csv`, separated by one
  or more empty lines, with each block having its own header row.
  Today bxp-cli would treat the second header as a data row and fail.
  Options: (a) add `csv_split_on_blank_line: true` flag — parser
  splits the file at empty-line boundaries and processes each block
  separately, or (b) treat blank line as end-of-stream and process
  only the first block (cheaper, less complete). Touches
  `csv.zig` + `config.zig` + `pipeline.zig`. Decide on (a) vs (b)
  based on the user's actual file.

- **Opt-in multiline quoted fields (`csv_multiline_quotes: true`).** Audit
  2026-06-13, deferred. `csv.LineIterator` deliberately uses
  lazy-quotes semantics (a newline always ends the record; documented + tested
  intent). Some broker exports carry embedded newlines in description/notes
  columns (RFC 4180 §2.6). An opt-in per-template flag could switch the
  iterator to RFC mode for those templates while keeping the safer lazy
  default. Cost: a `LineIterator` branch + config field + `FieldDoc`, and the
  per-block parallel pipeline needs care — record boundaries no longer align
  with `'\n'`, so chunk splitting must become quote-aware or fall back to
  serial for that template.

- **Wealthfolio target spec vocabulary expansion (remaining).** The
  readme now documents `TRANSFER_IN`, `TRANSFER_OUT`, and `SPLIT`
  alongside the eight standard actions. Real Wealthfolio also accepts
  `CONVERSION_IN`, `CONVERSION_OUT`, and `ADJUSTMENT` — confirm against
  the import contract and add to the readme if the existing
  `WITHDRAWAL`/`DEPOSIT` mapping for currency conversion is too lossy.
  Pure docs change.

- **Description-based ticker extraction.** Lime.co's dividend rows have
  empty `Symbol` and the ticker is embedded in `Description`
  (`"Qualified Dividend APPLE INC 100"`). Today there's no clean way
  to extract the ticker. Two design options: (a) document
  `ticker_map` keyed by company name (`"APPLE INC": "AAPL"`) — works
  with the existing engine, just needs a readme tip; (b) add a
  `REGEX_EXTRACT(s, pattern)` built-in (deferred to Zig 0.16
  migration — see "Expression builtins (regex)" under Tooling). (a)
  is cheap and unblocks today; (b) is a real feature later.

### Real-world data quirks (problem-first)

Surfaced by the problem-first examples initiative: start from a real,
documented data-cleaning problem, attempt it with bxp-cli, and record
genuine _feature_ gaps here (bugs — where BXP does something wrong — get
fixed before release instead, not parked here).

- **Forward-fill / unmerge-cells (`fill_down`).** Spreadsheets exported
  from merged cells leave the group label on the first row and blanks
  below it (`Fruit,apple` / `,banana` / `,cherry`). De-merging — carrying
  the last non-empty value down a column — is one of the most common
  spreadsheet-cleaning chores. bxp-cli can't do it today: it needs the
  _previous row's_ value (positional cross-row state), which the keyed
  `pre_pass`/`LOOKUP` model doesn't provide and which clashes with the
  per-block parallel pipeline (blocks are processed independently). Repro
  2026-05-31: blanks pass through unchanged. Feature: an opt-in
  `fill_down: ["colA", "colB"]` carried as serial pre-processing before the
  parallel main pass (a small single-threaded scan that materialises the
  filled column), or document it as Not-planned if the serial cost is
  judged to break the engine contract. Decide vs the stateless/parallel
  philosophy before implementing.

- **Timezone-aware datetimes → UTC.** `DATE_CONVERT` parses the wall-clock
  part of `2024-03-15T14:23:01+02:00` (or `…Z`) but silently drops the
  offset — there is no token for it and no conversion to a common zone.
  Reproduced 2026-05-31. For mixed-offset exports (a real pain in any
  multi-region dataset) you can't normalise to UTC. Feature: an offset/`Z`
  format token plus an optional "convert to UTC" mode in `DATE_CONVERT`.
  Date-only sibling problems (DST gaps, leap seconds) are out of scope.

  **TZ-help builtins — consider on a concrete use-case.** DST-aware offsets
  are now expressible without a dependency: `NTH_DOW(year, month, weekday, n)`
  shipped 2026-06-02 (the `datefmt` calendar primitive — last Sunday of March
  is `NTH_DOW(y, 3, 7, -1)`), so the EU Prague window in
  `examples/advanced/multi-stage-etl` reads cleanly. `datefmt` itself still has
  no timezone awareness. Two upgrades, both **deferred until a real multi-zone
  use-case** justifies the maintenance cost:
  - `TZ_OFFSET(date, zone)` — returns `+01:00`/`+02:00` for a curated zone set
    (Europe/{London,Prague,…}, America/{New_York,…}, Asia/{Tokyo,…}), computing
    DST internally via `NTH_DOW`. One call replaces the hand-rolled `DATEDIFF`
    window. Cost: a zone→(base offset + DST rule) table that goes stale on rule
    changes (EU 1996, US 2007) and is date-granularity only (transition-day
    ambiguity). Subsumes a simpler `IS_DST(date, rule)` boolean.
  - `TZ_CONVERT(ts, from_zone, to_zone)` — full Postgres-style normalisation
    backed by the IANA tz database (historical rules correct). Heavier: embeds
    tzdata + a parser in the static binary. Only if real historical multi-zone
    conversion appears. Excel offers neither (no TZ/DST concept at all), so
    these would put bxp ahead of the spreadsheet baseline, not just at parity.

- **Load-time warning on duplicate column headers** (surfaced 2026-05-31, low
  priority). `[name]` currently resolves last-wins silently, which can mask a
  malformed export.

- **Raise / make-configurable the 1024-column cap (`MAX_COLUMNS`).** Wide
  time-series exports exceed it: the Johns Hopkins COVID-19 daily series ships
  one column per day (1147 columns by March 2023), so everything past column
  1024 is silently dropped (`warning: '<file>' has more than 1024 columns;
extra columns are ignored`, reproduced 2026-05-31). 1024 is a deliberate,
  generous ceiling (the field buffer is `[MAX_COLUMNS][]const u8`), but
  day-per-column datasets are a real shape. Options: raise it, or make it a
  config/dynamic allocation. Note: such files usually _want_ unpivoting to long
  form anyway (bxp does that via multi-row `row_rules`), which sidesteps the
  width entirely once the columns are reachable.

- **Bracket-protected fields (web-server access logs).** Apache/nginx
  combined-log format is space-delimited but wraps the timestamp in
  `[10/Oct/2000:13:55:36 -0700]` — a group containing the delimiter. bxp-cli
  honours `"`-quoting but not `[...]`, so a space-delimited parse splits
  inside the bracket and shifts every subsequent column (reproduced
  2026-05-31). Web-server logs are one of the most common raw ETL inputs.
  Options: a `bracket_group: true` (treat `[...]` like a quote that protects
  the delimiter), a general `group_open`/`group_close` pair, or an explicit
  "logs are out of scope — pre-process with a log parser" note. Decide vs
  the CSV-tool scope. (The _date_ inside the bracket already parses fine via
  `DATE_CONVERT(..., 'DD/MMM/YYYY:hh:mm:ss', ...)`.)

- **Overload `REPLACE` for bulk/chained replace.** Consider on a concrete
  use-case. Templates that normalise several tokens at once today nest
  `REPLACE(REPLACE(REPLACE(x, 'a', '1'), 'b', '2'), …)` — unreadable past two
  or three pairs (the thousands-separator idiom `REPLACE(REPLACE(x,' ',''),
',','.')` is the common case, and a foreign-month-name normaliser would be
  another). **Decided 2026-06-05: extend the existing `REPLACE` rather than
  add a new `REPLACE_MAP` builtin** — this mirrors how scripting languages
  do it (Python `str.replace`, Ruby `gsub`, Pandas `replace` all overload
  one name with a dict/extra args; PHP `strtr($s, $array)` is the closest
  named precedent), so users learn no second name, and a Latin-only
  `TRANSLATE` name is avoided (that word means char-level in SQL/Perl).
  Today's 3-arg `REPLACE(s, from, to)` (single literal pair, all
  occurrences, left-to-right, non-overlapping, case-sensitive, backed by
  `std.mem.replaceOwned`) stays valid. New variadic form
  `REPLACE(s, 'a','1', 'b','2', …)` applies pairs **left-to-right in one
  pass** (one allocation, not one per nested call — the perf win over the
  nest, which does K allocations + 2K passes for K pairs). Open questions:
  variadic pairs vs also a config-level named map
  (`REPLACE(s, 'mymapname')`, mirroring `ticker_maps`); whether an earlier
  replacement's output is eligible for a later pair (it is in a nested
  chain — document whichever we pick). This is also the lightweight answer
  to the deferred `date_locales` idea (a named month-name map applied
  before `DATE_CONVERT`), avoiding a dedicated locale subsystem.

### bxp-gui

- **User-supplied themes from JSON files on disk.** Every field on
  `BxpTheme` ([bxp-gui/lib/ui/theme/bxp_theme.dart](../bxp-gui/lib/ui/theme/bxp_theme.dart))
  is either a `Color`, `Brightness`, enum-like preset id, or label string.
  Adding `BxpTheme.fromJson(Map<String,dynamic>)` factory + `toJson()` helper
  would unlock: (1) drop `~/.config/bxp-gui/themes/myname.json` and have it
  appear in the cycle without rebuild; (2) export the active preset for
  sharing or forking ("save as"); (3) optional theme marketplace later.
  Schema is already JSON-friendly — only `tones` (function pointer for
  FlexSeedScheme) needs a name → preset lookup. Built-in presets stay as
  fallback for corrupt/missing JSON.

- **Wide-CSV rendering: two possible future optimisation paths.**
  After the 2026-05-26 survival session, the GUI handles 900-col x
  100k-row CSVs but RSS scales linearly with `visible_rows × cols`
  (~13.5 GB at full-file scroll on the bench). Real-world data (broker
  exports 10-30 cols, NOAA GHCN 124 cols) sits well below the limit
  and current Pluto + the `kWideColLimit=64` gate is enough. Revisit
  these if a 1000+ col use case becomes real:
  - **Query-driven viewport (csvql or in-house slicer).** PlutoGrid
    becomes a windowed display of `~30 visible cols x ~50 visible rows`.
    On scroll, query a slice from disk
    ([csvql](https://github.com/melihbirim/csvql) or an in-house
    `getRowSlice(file, rowIds, colIndexes)` built on the
    existing lazy RAF). RSS becomes constant regardless of file size.
    Hard parts: synthetic scrollbars representing the full virtual extent,
    scroll → query latency budget (debounce + prefetch), viewport index
    ↔ virtual rowId mapping for drill-down, zip-merge per-row BXTB
    metadata (status / warnings) which csvql does not know about.
    In-house slicer is the cheaper start (no new dep); csvql wins if we
    also want SQL-style queries as a user feature (joins / aggregates).
  - **Custom table widget replacing PlutoGrid.** Our use is much
    narrower than what Pluto offers (no editing, sorting, reordering,
    type validation, context menus, frozen cols). A purpose-built
    widget could deliver 2D virtualisation (column headers virtualised
    same as body cells), no `MediaQuery` sandwich for the Scrollbar
    wiring, and tighter coupling with BXTB metadata. Cost: 2-4 weeks
    of focused work to reach feature parity (scroll sync between
    header strip and body, focus management, keyboard navigation,
    accessibility, IME) — Pluto has had years of upstream bugfixes.
    Reconsider if we hit a Pluto bug we cannot work around, or if the
    above query-viewport path lands and forces a custom widget anyway.

  Both paths are big — single-session POC is unlikely. Decision input:
  do we have a real workload that needs it, or is the current ceiling
  comfortable for shipping use cases?

- **Rendered output `.csvx` preview in the bottom pane.** Tabular view
  of generated output after a full-run, reusing PlutoGrid from the trace
  view. Users today alt-tab to Rainbow CSV / Excel for sanity-check.
  Small implementation; reconsider when a GUI workflow audit shows the
  alt-tab friction is frequent.

- **Raw input CSV / xlsx preview with `[ColumnName]` highlighting.**
  Tabular view of source file with columns referenced from `input_schema`
  highlighted. Killer use-case: AI handoff workflow — user could point
  the agent at a file rather than paste 5 rows. Reconsider when the
  import wizard below starts, or on explicit user request.

- **Import wizard from sample CSV.** Drop CSV onto empty-config state →
  GUI detects delimiter / decimal / quoting, header-similarity matches
  candidate `$variable` mappings (`Date` → `$date`, `Symbol` → `$ticker`,
  …), generates a skeleton template for the user to fill `row_rules`.
  Lowers first-template barrier from "expert" to "novice". Big feature,
  needs design sketches first. Reconsider on explicit user request or
  visible onboarding friction during a real session.

- **In-app diff actual vs expected `.csvx`.** Regression workflow without
  external `diff` tool — useful during template iteration; once stable,
  `scripts/test-02-datasets.sh` covers it from CI. Reconsider on request
  from a contributor maintaining > 3 templates.

### Tooling

- Zig 0.16 migration. Currently pinned to 0.15.2; 0.16 shipped
  2026-04-15 with breaking I/O API changes (~100–150 LOC affected).
  Assessment in `project_zig16_migration` memory. Bundle this with
  `REGEX_MATCH` / `REGEX_EXTRACT` below — the only mature native-Zig
  regex (zig-utils/zig-regex v0.2.0, 2026-05-18) requires Zig 0.16+.
  Note: the `uucode` dep is **not** a blocker — its master branch already
  supports 0.16; we deliberately pin the `zig-0.15` back-port branch for
  now, so migration just repoints the pin to master (+ new hash).

### bxp-api — HTTP adapter over the shared `inspect` core

The stateless `inspect` core (`bxp-core/src/inspect.zig`) already backs two
shipped adapters — `bxp-mcp` (MCP/stdio) and `bxp-gui-bridge` (FFI). A
third, **bxp-api**, would put the same core behind an HTTP/port transport
for a remote/web front-end. Needs concurrency (thread pool / event loop)
that stdio doesn't. Build only when a real web/remote case appears.

The `inspect` core is stateless (no `pre_pass`/`LOOKUP`), so full template
simulation stays CLI territory — hence `bxp_simulate` spawns `bxp-cli`
rather than running in-core.

### Expression builtins (regex)

- `REGEX_MATCH(s, pattern)` and `REGEX_EXTRACT(s, pattern)` — deferred
  from v0.2.4 (2026-05-26 decision). Real use: Lime.co dividend ticker
  extraction (`"Qualified Dividend APPLE INC 100"` → `"APPLE INC"`),
  generic user-defined patterns in templates. Surveyed regex options
  for Zig 0.15.2:
  - `tiehuis/zig-regex` — no capture groups, no UTF-8 → blocks `REGEX_EXTRACT`.
  - `zig-utils/zig-regex v0.2.0` — full feature set incl. named groups
    and lookaround, **requires Zig 0.16+**.
  - `alexnask/ctregex.zig` — patterns must be comptime-known, useless
    for runtime template strings.
  - POSIX `regex.h` via `std.c` — works on Linux/macOS but libc-managed
    memory (can't use Zig allocators) and Windows packaging pain.
  - libpcre bindings — +external dep ~700 KB, cross-platform build setup.

  Decision: bundle with the Zig 0.16 migration above, then adopt
  zig-utils/zig-regex. v0.2.4 ships the other 9 builtins; the remaining
  ~10 % of real-world need (regex) waits.

### Expression builtins (non-regex)

The high-value primary builtins (`CASE`, `IFERROR`, `LPAD`/`RPAD`, `POSITION`,
`PROPER`, `MOD`, `ISEMPTY`) and the per-file/row context builtins
(`FILENAME()`, `RECORD_NUM()`, `SHEET_NAME()`) have landed. What remains:

**Secondary / niche — on hold indefinitely.** No concrete use-case; add only
when a real one appears. All fit the existing `FnDoc` + `ArgKind` pattern
unless noted:

- String / parsing: `FIND` (exact alias of the shipped `POSITION`), `REPT(s, n)`.
- Calendar / clock components: `QUARTER(d)`, `WEEKNUM(d)`, `DATE_TRUNC(unit, d)`,
  `HOUR(d)` / `MINUTE(d)` / `SECOND(d)`. The time extractors need a canonical
  ISO-datetime input decision first (bxp's date model is date-only today).
  These are plain calendar/clock accessors — **distinct from** the timezone
  work under _Real-world data quirks → Timezone-aware datetimes_
  (`TZ_OFFSET` / `TZ_CONVERT` / `IS_DST`), which carries the DST/zone logic.
- Validation: `IS_NUMERIC(x)`, `IS_DATE(x)`.
- Math: `SIGN(x)`, `TRUNC(x)`, `MROUND(x, m)` are exact on the fixed-point
  decimal core. `POWER(base, exp)` and `SQRT(x)` are **blocked on a design
  call** — both need floating point, which conflicts with the deliberately
  float-free decimal core; revisit only with an integer-exponent-only `POWER`
  or an explicit float-approximation mode.

Regex builtins (`REGEX_MATCH` / `REGEX_EXTRACT`) are tracked separately above —
they need the Zig 0.16 migration + a new dependency.

### Encoding — more single-byte code pages

`encoding.zig` covers Win-1250/1252, ISO-8859-1/2/15 today. The 256-entry
override-table pattern makes each new code page ~mechanical (Win-1251
Cyrillic, ISO-8859-5, …). Marginal cost is low; no work until a broker
export actually demands one.

## Not planned

Features that surface repeatedly in audits and reverse-simulations but
are deliberately **out of scope** — documented here so the same
discussion doesn't keep restarting. Reopen only if the rationale changes.

- **Aggregation across rows (SUM / COUNT / GROUP BY).** Conflicts with
  bxp's row-by-row engine philosophy — every output row is a pure
  function of one input row plus the pre-pass lookup table, no global
  state. Adding aggregation would require fundamental engine redesign.
  Workaround: post-process the `.csvx` output in the destination tracker
  (Wealthfolio / brycht.app) or with a one-line `awk` / spreadsheet.
- **Multi-file input correlation (`LOOKUP` across files within one
  template).** Same row-engine constraint as aggregation: each input
  file is a self-contained unit. Workaround: concatenate the files
  before running bxp-cli, or split the template into two and feed the
  outputs to a third tool.
- **Routing to multiple output files based on `$action`.** One template
  produces one output stream (plus optional `combined_output`).
  Workaround: define two templates with different `row_rules` filters
  pointing at the same `data_dir`.
- **Inline test assertions inside a template** ("this row should match
  rule N"). The `datasets/<id>/sample.expected` baseline mechanism
  already covers this from outside the template; adding assertions
  inline would duplicate that surface area without adding new
  capability.
- **Step-through expression debugger.** The Expression Playground
  (single-eval against a sample row) plus per-call NDJSON traces from
  `--expr-trace` cover ~all real debugging needs. A breakpoint-style
  debugger would be massive surface area for marginal gain.
- **Output row deduplication (`dedup_output: bool`).** The re-import
  scenario it would solve — overlapping date ranges across successive
  broker exports producing duplicate `.csvx` rows — is a workflow
  problem solved upstream: discipline the export date ranges (every
  broker UI offers a "from / to" picker), wipe `data_dir` before
  re-import, or rely on the destination tracker's own dedup. Adding
  it inside BXP would require cross-run persistent state (a hash file
  next to each `data_dir`), which clashes with the stateless engine
  contract — every run today is reproducible from inputs alone. No
  user has reported the duplicate-row problem in practice.
- **Watch / daemon mode (continuous `data_dir` ingestion).** Audit
  2026-06-13. `cron` + `--fresh` already covers periodic ingestion
  idempotently (a skipped per-file output is never rebuilt; the combined
  roll-up is). A long-running daemon would add process state and a platform
  supervision surface for no capability the scheduled-run path lacks.
- **Single-file stdin→stdout mode.** Audit 2026-06-13. Ad-hoc agent
  evaluation is already served by the stateless inspect surface
  (`bxp-mcp` eval / eval-batch) and staged runs by `bxp_simulate`; a third
  entry path would reopen the "stateless eval vs LOOKUP orchestration"
  design split that was settled during the fmt removal.
- **Space / NBSP thousands grouping (`csv_thousands_separator_in`).**
  Space- or NBSP-grouped European numbers (`1 234 567,89`) are not
  auto-normalised: `parseGroupedNumber` disambiguates dot/comma grouping
  (because `csv_decimal_separator_in` declares the decimal char), but a
  space/NBSP thousands separator stays raw. Decided (user, 2026-06-04) **not**
  to add a `csv_thousands_separator_in` config for it — the user strips it
  themselves with `REPLACE(REPLACE([X], ' ', ''), ',', '.')` (and the 2-byte
  NBSP variant). Note: dot-grouped EU (`1.234.567,89`) **is** handled
  automatically — only the space/NBSP case is out of scope here.
