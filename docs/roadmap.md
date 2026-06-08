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
- `bxp-fmt --list-templates` / `--fetch-template` work without a
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

### Flip bridge proxy to default on Linux/macOS

Foundation shipped in v0.2.3: `bxp-gui-bridge.{so,dylib}` builds and
ships alongside `bxp-gui` on all three hosts; `bridge_eval_expr` /
`bridge_eval_expr_trace` already run in-process on every platform; the
subprocess proxy path (`bridge_run` / `bridge_run_streaming` for
spawning `bxp-cli` / `bxp-fmt`) compiles and works cross-platform
behind a `BXP_FORCE_BRIDGE_PROXY=1` smoke gate. Windows has used the
bridge proxy as its mandatory and only path since v0.2.2 to sidestep
dart-lang/sdk#1727 (Win pipe truncation) and engine-stderr capture
under `/SUBSYSTEM:WINDOWS`.

Plan for v0.3.0:

- Make the bridge proxy the default on Linux/macOS, removing the
  `Platform.isWindows` branches in
  [`bxp_process_client.dart`](../bxp-gui/lib/services/bxp_process_client.dart)
  and the `BXP_FORCE_BRIDGE_PROXY` opt-in.
- Drop the `Process.start` code path entirely once the bridge proxy
  has shipped in at least one production release on Linux/macOS with
  no regressions.
- Audit the per-host Flutter shells (`linux/`, `macos/`) for any
  remaining `Process.start`-specific assumptions before the flip.

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

### Raise XLSX cap + optimise large `.xlsx` ingest

CSV and JSON paths went streaming in earlier releases (CSV via
`ChunkReader` + `csv.LineIterator`; JSON via `std.json.Reader`).
Memory ceiling on those paths is now `O(longest row + pre_pass table)`,
so multi-GiB CSV / JSON inputs work fine.

`.xlsx` is the remaining ceiling. `bxp-core/src/xlsx.zig` caps the
file at **10 MB** (`XLSX_MAX_FILE_SIZE`), which rejects realistic
workbooks (multi-sheet broker exports, NOAA / public datasets
distributed as `.xlsx`). Raising the cap is cheap; making large
`.xlsx` ingest fast is the real work — ZIP central-directory parse,
DEFLATE inflate of `xl/sharedStrings.xml` and `xl/worksheets/sheet1.xml`,
and the XML walk that produces our row stream all currently materialise
intermediate buffers.

Plan for v0.4.0:

- Lift `XLSX_MAX_FILE_SIZE` from 10 MB to something workbook-realistic
  (256 MB candidate; multi-sheet bookkeeping rarely exceeds that).
  Keep as a sanity cap, not a feature limit.
- Profile a 50–100 MB workbook end-to-end. Likely hotspots:
  shared-strings table (loaded whole into RAM today), per-row XML
  parsing, and the intermediate CSV buffer we hand to `processBroker`.
- Stream the shared-strings table where possible (build a string-index
  → offset map and `pread` on demand) instead of slurping it all.
- Stream the worksheet `<row>` walk directly into the existing CSV
  pipeline (skip the intermediate full-file CSV buffer); each row
  becomes one `LineSlice`-equivalent record fed to the same
  `processBroker` chunk path.
- Bench harness entry: synthetic `.xlsx` matching the worst public
  dataset shape we want to support.

Trade-off: ZIP+DEFLATE has no random-seek primitive, so streaming
shared-strings means a second `inflate` pass when the worksheet row
walk first references each string. Acceptable if the total memory
ceiling drops from `O(workbook size)` to
`O(shared-strings index + one row)`.

### Unicode / text subsystem (one cohesive module)

> **Status 2026-06-08.** Layer 1 case mapping **shipped**: `UPPER` / `LOWER`
> are now full-Unicode (`café`→`CAFÉ`, `ß`→`SS`, `я`→`Я`; unicameral scripts +
> invalid UTF-8 pass through) via `bxp-core/src/unicode.zig`. The Unicode data
> tables come from the **uucode** library (MIT), a field-selected fetch
> dependency pinned in `bxp-core/build.zig.zon` — **not** in-house generation.
> The zero-external-dep stance was deliberately relaxed (it was a state, not a
> rule): uucode delivers correct full-Unicode case mapping incl. `ß`→`SS`, zero
> runtime allocation, and a ~5 MB field-pruned table source, which beat
> hand-generating + maintaining tables from UCD. See the `reference_zig_unicode_libs`
> memory for the uucode-vs-zg evaluation. **Remaining: `unaccent` (Layer 1) and
> the Layer 0 `csv_*_encoding` transcoding** (both still to build; uucode already
> exposes the decomposition fields `unaccent` needs).

As bxp generalises beyond EU broker CSVs into a general CSV→JSON / data
cleaning tool, three separate gaps all turn out to be the same problem
seen from different angles — non-UTF-8 input files, ASCII-only `UPPER`/
`LOWER`, and no diacritic stripping. Rather than ship three ad-hoc
builtins that each re-derive UTF-8 iteration and Unicode tables, the text
operations live in **one `bxp-core/src/unicode.zig` module**, with the
Unicode tables supplied by uucode (case mapping today; decomposition for
`unaccent` next) and the encoding tables to be added in-house for Layer 0.

**Architecture — two layers, one currency.** Everything internal stays
**UTF-8**. The two layers share only the UTF-8 plumbing, never each
other's semantics (do not merge encoding detection with case mapping):

- **Layer 0 — encoding conversion (the "iconv" job).** Transcode a
  non-UTF-8 input file to UTF-8 **at read time** and back **at write
  time**, driven by config. The rest of the pipeline never sees a
  foreign encoding. New per-template config keys `csv_input_encoding` /
  `csv_output_encoding` (default `utf-8`). **CSV only** — JSON (RFC 8259)
  and xlsx (XML-in-ZIP) are always UTF-8, so they need no such key.
  Replaces today's detect-only behaviour (`pipeline.zig` already emits
  `warning: '<file>' is not valid UTF-8` but cannot transcode).
- **Layer 1 — text operations on UTF-8 cells (expr builtins).** Case
  mapping (`UPPER` / `LOWER`) and transliteration (`unaccent`), invoked
  per-field. These stop being byte loops and become UTF-8 codepoint
  walks (`std.unicode` iterators), so output length may differ from
  input (`ß`→`SS`) — no `s.len` pre-allocation.

**Scope decisions — "proper, but small" (resolved 2026-06-05):** the
right coverage differs per operation, and picking it per-operation lets
us be correct globally without bloat.

- **`UPPER` / `LOWER` → full Unicode — SHIPPED 2026-06-08.** Swedish
  `å ä ö`, Greek, Russian `я` all work correctly; unicameral scripts
  (CJK, Arabic, Hebrew) have no case and pass through unchanged; `ß`→`SS`
  expands on upper. No Latin-only MVP — done right from the start. The
  case tables come from uucode (`uppercase_mapping` / `lowercase_mapping`
  fields, generated from `UnicodeData.txt` + `SpecialCasing.txt`
  upstream), not hand-rolled here.
- **`unaccent` → deliberately Latin-scope (this IS the proper answer,
  not a shortcut).** Renamed from the working title `TO_ASCII` per user
  preference, matching Postgres's `unaccent` extension. Strips diacritics
  for Latin (`café`→`cafe`, `ß`→`ss`, `ø`→`o`). For non-Latin scripts the
  correct behaviour is **pass-through** (keep the UTF-8), NOT romanisation:
  `unaccent('日本語')`→`'Ri Ben Yu'` is lossy, ambiguous, and almost never
  wanted — which is exactly why Postgres `unaccent` is Latin-focused too.
  Full unidecode-style romanise-everything is explicitly out of scope.
  Generated from Unicode decomposition (NFD, strip combining marks) + a
  small hand-list for non-decomposing letters (`ß ø ł đ æ þ`), i.e. the
  CLDR `Latin-ASCII.xml` data Postgres's `generate_unaccent_rules.py`
  uses. Distinct table from the case table (`ü`→case `Ü`, translit `u`).
- **Encoding tables → tiered.** Ship **European single-byte first**
  (Latin-1, Windows-1252, Latin-2/9 — trivial 256-entry tables, a few KB
  total). **CJK multibyte** (Shift-JIS, GB18030, Big5, EUC-JP/KR) are
  larger (~tens to hundreds of KB each) — add as separate, optional
  table modules when a real user needs them. Note: this is a
  legacy-file feature regardless of region — modern Japanese / Swedish
  CSVs are overwhelmingly UTF-8 already, needing no conversion.

**Module shape.** `unicode.zig` exports `toUpper(cp)` / `toLower(cp)`
(feeds `UPPER`/`LOWER`), `toAscii(cp) []const u8` (feeds `unaccent`), and
`decodeToUtf8(bytes, enc)` / `encodeFromUtf8(utf8, enc)` (feeds the
`csv_*_encoding` config). A `build.zig` generator step emits the tables
from committed UCD / CLDR source files; regenerate on a Unicode version
bump. May later split into `encoding.zig` + `unicode.zig` if it grows.

**Locale caveat (document, don't solve).** Use the root/invariant locale
for case mapping. The only real collisions are Turkish dotless `i`/`İ`
and German `ß`/`ẞ`; full locale-aware case (ICU-level) is a later upgrade
gated on a concrete use-case, not a v0.4.0 goal.

> This subsection supersedes the standalone "Input character-encoding /
> charset transcoding" item under _Later → Real-world data quirks_ — the
> `input_encoding` idea is folded in here as Layer 0 (`csv_input_encoding`).

## Later (no specific version)

### Single-source the console + desktop readmes

`resources/console/readme.md` and `resources/desktop/readme.md` today
duplicate a large shared body (template authoring, `$variable` /
expression reference, AI-assistant rules, self-test, locale parsing,
`bxp-fmt` reference, exit codes) and differ only in product-specific
framing (title, intro, GUI features, IO notes). The console readme is
meant to be a **subset** of the desktop one, but the two drift apart
whenever shared content is edited in only one — maintaining the subset
relationship by hand is error-prone (proven repeatedly: the EU
number-parsing section silently went stale in desktop, and self-test /
`bxp-fmt` content diverged during the 2026-06-07 edits).

Fix: **merge into one source readme** with GUI/desktop-only lines tagged
inline, e.g. a `!GUI-ONLY!` marker, and a small build step that emits the
two shipped variants:

- Console variant — strip every `!GUI-ONLY!` line (and its marker).
- Desktop variant — keep everything, strip just the marker token.

Open questions: marker syntax that survives Markdown rendering if a
generation step is ever skipped (HTML comment `<!-- GUI-ONLY -->` vs a
bare `!GUI-ONLY!` sentinel); whether the generator is a new
`scripts/` step wired into `release-*.sh` + a `test-*` drift guard that
fails if a committed variant doesn't match a fresh generation;
product-specific blocks that are not a clean line-strip (the title,
intro binary list, IO section) may need a block-level `!GUI-ONLY!` /
`!CLI-ONLY!` pair rather than per-line tags.

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

- **AI-authoring workflow — rethink fmt / `--debug` / `--trace=bin` split.**
  → Promoted to _Pre-release → Agent-driven configuration authoring_ at
  the top of this file (it now also owns the stale bundled-readme "Pass B"
  rewrite). Resolve there before adding flags.

### Real-world data quirks (problem-first)

Surfaced by the problem-first examples initiative: start from a real,
documented data-cleaning problem, attempt it with bxp-cli, and record
genuine _feature_ gaps here (bugs — where BXP does something wrong — get
fixed before release instead, not parked here).

- **Input character-encoding / charset transcoding.** → Promoted to
  v0.4.0 as Layer 0 of the _Unicode / text subsystem_ (`csv_input_encoding`
  / `csv_output_encoding`). A huge share of real-world CSVs — especially
  European and Windows-origin exports — are Windows-1252 / ISO-8859-1 /
  Latin-1, not UTF-8. bxp-cli reads bytes verbatim: it does not corrupt
  them, but it also does not transcode, so a Latin-1 `André`
  (`0x41 0x6e 0x64 0x72 0xe9`) passes straight through and the `.csvx` is
  then invalid UTF-8 for any downstream consumer that assumes UTF-8 (the
  GUI, Wealthfolio, a database import). Reproduced 2026-05-31. Note: a
  _known-pattern_ mojibake (`cafÃ©` → `café`) can already be patched today
  with explicit `REPLACE(...)`; the encoding feature is for the general
  case where the whole file is in one non-UTF-8 charset.

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

- **Basic expression builtins — top gaps.** Surfaced 2026-06-05 reviewing
  the 38-function catalog against the SQL / Excel baseline for a general
  CSV cleaning tool. Three stand out as cheap, common, and genuinely
  missing today (the rest — `MOD`, `POSITION`/`FIND`, `DATE_TRUNC`,
  `QUARTER`/`WEEKNUM`, `HOUR`/`MINUTE`/`SECOND`, `PROPER`,
  `IS_NUMERIC`/`IS_DATE`, `REPT`, and niche math `POWER`/`SQRT`/`SIGN`/
  `TRUNC`/`MROUND` — are parked as a secondary list, add per use-case):
  - **`LPAD(s, n, pad)` / `RPAD(s, n, pad)`** — pad a string to a fixed
    width. The most common real gap: zero-padding account numbers, ISINs,
    postal codes, fixed-width IDs. No way to express it today.
  - **`SWITCH` / `CASE`** — multi-branch conditional. Collapses the
    unreadable nested `IF(IF(IF(...)))` pyramid into one call; the single
    biggest readability win available. Decide `SWITCH(x, v1,r1, v2,r2, …,
default)` (Excel-style) vs SQL `CASE WHEN` shape — the variadic
    `SWITCH` form is closer to the existing builtin call style.
  - **`IS_EMPTY(x)`** — true when `x` is empty or whitespace-only. Cheap,
    and directly retires the documented `"0" == ''` coercion footgun
    (today the safe idiom is `LEN(TRIM(x)) = 0`, easy to get wrong as a
    bare `x = ''` which matches `'0'`). One builtin removes the trap.

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

### Bridge FFI expansion (more direct Zig calls)

- Grow the in-proc `bridge_eval_*` FFI family beyond today's
  `bridge_eval_expr` / `bridge_eval_expr_trace`. The intent: once
  `bxp-core` / `bxp-fmt` stop churning internally, move more stateless
  `bxp-fmt`-style calls off the subprocess path and link them directly
  into the GUI process. Deferred deliberately — not worth pinning the FFI
  surface to code that is still changing. Conventions every new export
  must follow are already written up: see
  ["Adding a new bridge FFI export"](devel.md#adding-a-new-bridge-ffi-export)
  in the developer guide.

### MCP + API library (external project)

Idea captured from a 2026-06-07 brainstorm — a **separate Zig project**,
not a per-app server. An embeddable agent-control / API layer that every
bxp binary (and future programs) links, so a program can be **driven by
an agent** instead of the `exe + flags → parse stdout/stderr` dance.

Shape and rationale from the discussion:

- **One core, thin adapters.** A clean Zig core (logic + structured
  types) with separate adapters on top: an **MCP** adapter (JSON-RPC,
  tools + notifications for an agent), an **HTTP** adapter (for a future
  web front-end doing file in/out manipulation), and a **C-ABI** adapter
  (link into Dart, as the existing `bxp-gui-bridge` already does). The
  core must not know who is calling it — that boundary is what separates
  "universal lib" from "MCP glued onto the bridge".
- **Generalises the bridge.** `bxp-gui-bridge` is already a C-ABI core
  called from Dart; this is its natural generalisation from "spawn a
  subprocess" to "be an agent endpoint".
- **Three intended jobs** (user framing): (1) let a program be
  agent-controlled instead of argv + stdout parsing; (2) replace the
  old NDJSON-style streaming API (the retired `--trace=json`) with
  structured JSON-RPC notifications; (3) be **bidirectional** — e.g. a
  long-lived GUI pushes debug info back to the agent (MCP natively
  supports server→client notifications / sampling / elicitation).
- **BXTB stays the internal fast-path.** The bridge/fmt could sit on the
  binary BXTB stream from `bxp-cli --trace` and translate it to JSON-RPC
  for the agent — so the agent never sees binary BXTB, and the
  performance path (cli → bridge) is unchanged. (1:1 frame→notification
  vs aggregated "simulate" result is a later detail.)
- **Three consumers justify the separate project:** individual bxp apps,
  an agent driving them, and a future web service — same core, different
  adapter, written once instead of three times.

Explicitly **not** the fix for agent-driven config authoring: that
brainstorm concluded MCP adds only marginal utility _for config
authoring specifically_ (the bottleneck is the structured `simulate`
data surface, not the transport — a plain `--json` would deliver the
same payload). That workflow was already unblocked the cheap way
(2026-06-07): `bxp-fmt` ships in the console archive and both bundled
readmes' self-test sections use the real `fmt --config` /
`fmt --expr-trace` / `cli --debug` / read-`.csvx` loop. Decided **not**
to re-add NDJSON to `bxp-cli` (CLI stays a workhorse). This library is
the longer-term platform play, deferred until the engine and its
structured surfaces stop churning (same pinning caution as the Bridge
FFI expansion above).

If a single-round-trip structured `simulate` surface is ever pursued
(matched + unmatched + errored rows, computed `$variable` values, chosen
rule index, resulting output row, for a _sample_ of rows), candidate
shapes are: a structured-JSON `--debug`, an N-row extension of
`bxp-fmt --expr-batch`, or a documented small BXTB parser — plus folding
in the GUI "import wizard" (under _bxp-gui_, Later). `fmt` is stateless
(no `pre_pass`/`LOOKUP`), so full template simulation stays CLI
territory.

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
- **Space / NBSP thousands grouping (`csv_thousands_separator_in`).**
  Space- or NBSP-grouped European numbers (`1 234 567,89`) are not
  auto-normalised: `parseGroupedNumber` disambiguates dot/comma grouping
  (because `csv_decimal_separator_in` declares the decimal char), but a
  space/NBSP thousands separator stays raw. Decided (user, 2026-06-04) **not**
  to add a `csv_thousands_separator_in` config for it — the user strips it
  themselves with `REPLACE(REPLACE([X], ' ', ''), ',', '.')` (and the 2-byte
  NBSP variant). Note: dot-grouped EU (`1.234.567,89`) **is** handled
  automatically — only the space/NBSP case is out of scope here.
