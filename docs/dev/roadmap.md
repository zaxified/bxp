# Roadmap

Hand-maintained backlog — entries get crossed out / deleted as work
lands on master. `CHANGELOG.md` is generated independently.

## Milestones

### v0.3.1

Auto manual page (resources/readme.md) - AutoDoc

`LOOKUP` across templates within one bxp-cli run cycle

Output row deduplication in combined output files `combined_output_dedup: bool    // (default:false)`

### v0.3.2

Raise the macOS deployment target from 10.15 to 12 — **release blocker.**
Flutter 3.47 raised its own minimum supported macOS to 12 (to support
Xcode 27), while `bxp-gui/macos/Runner.xcodeproj/project.pbxproj` still
pins `MACOSX_DEPLOYMENT_TARGET = 10.15` in three build configurations.
The macOS leg of the release matrix has not been exercised since the SDK
pin moved to 3.47.0, so this is expected to surface first as a tag-push
failure. Bumping it consciously drops macOS 10.15 and 11 users.

Migrate off the SDK-bundled Material and Cupertino libraries. Flutter
3.47 split them into standalone `material_ui` / `cupertino_ui` packages;
the SDK copies still work but are scheduled for formal deprecation in the
November stable release. 26 files under `bxp-gui/lib/` import
`package:flutter/material.dart`. The migration is mechanical —
`dart fix --apply --code=migrate_design_widgets` rewrites the imports —
but must not be run on Dart 3.13.0, which fails to rewrite `export`
statements; that fix landed in 3.13.1. `MaterialUiCompatibilityBridge`
covers dependencies still on the legacy imports.

### v0.3.3

Transformation visualiser

### v0.4.0

GUI Config/Create - Import wizard from sample CSV
GUI updater progress bar
GUI input file viewer simple viewer

### v0.5.0

Full agentic automation - AI support for all steps in workflow

### v1.0.0

End Shared core libraries extraction

## Planned features - not version specific

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
  or replace it outright.
- `--list-templates` / `--fetch-template` semantics when the same name
  exists in bundle + user dir.

### New example candidates

Carried over from the (now-deleted) `*-todo` scratch when the example
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

### Interactive in-browser examples (wasm)

Run the documented examples *live* on the GitHub Pages docs site — the
reader edits an expression / a sample and sees the result recomputed in
their own browser, with nothing to download (no bxp-cli, no bxp-gui).
`bxp-core` is pure-computation Zig, so it compiles to a `wasm32` target
and becomes a fourth consumer of the same engine alongside bxp-mcp and
bxp-gui-bridge — not a reimplementation. WASM is only a compile target; the
sole genuine browser-sandbox limits are no threads (parallel `zipPrePass`
degrades to a serial scan — GitHub Pages can't set the COOP/COEP headers
`SharedArrayBuffer` needs) and no disk/subprocess (irrelevant here — inputs
are in-memory textbox strings). Two tiers:

- **A — Scratchpad demo (per-row playground).** Embeds the existing
  `inspect.evalBatch` (`bxp-core/src/inspect.zig`) behind a thin `wasm32`
  export: `headers + fields (one row) + exprs → output cells`, the same
  surface MCP's `bxp_eval_batch` and the bridge already drive. The reader
  types a formula, sees one row recompute live. Scope: a wasm export wrapper
  + ~30 lines of JS glue + an mkdocs snippet that turns a fenced block into
  the widget; the `.wasm` ships as a docs asset. Limit (an `evalBatch` API
  trait, *not* a wasm one): single-row eval — cross-row `LOOKUP` needs a
  pre-built lookups blob, so pre_pass demos either omit it or precompute the
  table.

- **B — Full-bxp demo (`sample.csv` → `final.csv`).** Runs a complete example
  transform end-to-end, bit-identical to the CLI: full config, multi-pass,
  pre_pass / cross-row `LOOKUP`, encoding transcode, date + decimal cores.
  The reader edits the config/formula and the whole `final.csv` re-renders.
  This needs the pure transform core lifted out of `bxp-cli/src/pipeline.zig`
  (today entangled with file I/O + threads) into `bxp-core` so it can be
  driven from in-memory strings — the same extraction the shared-core-lib
  track wants anyway. Bigger, but full fidelity.

Open questions: mkdocs integration (raw HTML/JS snippet vs a small plugin
generating the widget from a fenced ` ```bxp-eval ` block); whether B's
in-browser output can double as a docs-correctness gate (examples run
against the real engine instead of frozen expected text).

### Distribution polish

- Apple Developer ID notarisation for macOS `.app` (~$99/year).
  Eliminates the first-launch Gatekeeper warning.
- Windows Authenticode signing for the NSIS installer (~$200/year cert).
  Eliminates the SmartScreen warning.
- Flatpak publishing on Flathub. Review process takes weeks; defer
  until app is more stable.

### bxp-cli

- **`data_dir` multi-dir / array (`data_dir: [...]` or a `*` glob segment).**
  Audit 2026-06-13, deferred. Brokers that export into dated subdirectories
  (`exports/2026-06/`) need config edits per month today. Accepting an array
  of dirs (process all listed) or a `*` glob path segment would close that
  recurring operator chore. Demand-driven — only if a real workflow asks;
  docs/examples/ currently show flat dirs.

### CSV formula-injection guard (`csvsafe`)

We have none. `pipeline.zig`'s `writeSafeValue` does RFC 4180 quoting only, so
a field whose first character is `=`, `+`, `-`, `@`, or a leading tab/CR is
written through verbatim and evaluated as a *formula* when the output is opened
in Excel / LibreOffice / Sheets — the DDE `cmd|'/c calc'!A1` class. zig-libs'
`csvsafe` is precisely this guard and nothing else (`needsGuard` / `writeSafe`,
prefixing a single apostrophe).

Marginal for a broker export loaded straight into Wealthfolio, but bxp is
documented as a general CSV ETL — `hubspot-to-salesforce`, the Chicago
licences, RÚIAN — and those outputs do get opened in a spreadsheet.

Must be an **opt-in config key**, not a silent default: the apostrophe changes
the cell's value, which would corrupt an import into a tool that reads the CSV
programmatically. Note `csvsafe` also takes a decimal separator
(`needsGuardSep`), so a leading `-` on a negative number is not mistaken for a
formula — that interacts with `csv_decimal_out` and needs checking against our
accounting-negatives handling.

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
  only the first block (cheaper, less complete).

- **Wealthfolio target spec vocabulary expansion — done.** The guide now
  documents `TRANSFER_IN`, `TRANSFER_OUT`, `SPLIT`, plus `CREDIT`,
  `ADJUSTMENT`, and `UNKNOWN` alongside the eight standard actions
  (`guide/targets.md`). `CONVERSION_IN` / `CONVERSION_OUT` were dropped:
  Wealthfolio v3 removed them and DB-migrated them to
  `TRANSFER_IN` / `TRANSFER_OUT`, so currency conversion stays on the
  `TRANSFER` (or `WITHDRAWAL`/`DEPOSIT`) mapping.

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

### bxp-gui

- **User-supplied themes from JSON files on disk.** Every field on
  `BxpTheme` ([bxp-gui/lib/ui/theme/bxp_theme.dart](https://github.com/zaxified/bxp/blob/master/bxp-gui/lib/ui/theme/bxp_theme.dart))
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
  (~13.5 GB at full-file scroll on the bench). Since the `MAX_COLUMNS`
  bump to 16384 (CLI can now emit far wider output), the grid hard-caps
  rendering at `kMaxDisplayCols = 200` columns with a banner — bxp-gui is
  a debug view, not a wide-CSV viewer, so the linear-RSS blow-up is bounded
  by construction. Real-world data (broker exports 10-30 cols, NOAA GHCN
  124 cols) sits well below the cap. Both paths below are therefore
  **deferred indefinitely** — revisit only if a genuine in-GUI wide-display
  (1000+ visible cols) use case appears:
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
  `scripts/test-07-datasets.sh` covers it from CI. Reconsider on request
  from a contributor maintaining > 3 templates.

### Shared core libraries — consume zig-libs

The seven forked `bxp-core` modules have migrated, then three more pieces that
were never files of their own: `numparse` (a function inside `expr.zig`),
`minisign` (the bridge's hand-rolled `.minisig` parser, replaced by the module
that implements the whole format against known-answer vectors from the real
`minisign` binary) and `procrun`'s reap core (the bridge's
`ensureChildReaping` / `waitTolerant`). What is left below is still open. None
of it promises a speed-up: where these overlap our code they are the same
algorithms, verified rather than assumed.

- **`csvstream`** — the largest overlap left, and the most delicate. Carries
  `LineIterator` / `splitFields` / `LineSlice` (our `bxp-core/src/csv.zig`)
  **and** `ChunkReader` (bxp-cli's `pipeline.zig`, tuned in its own bench
  session, S03). Two things must be audited before any swap, both load-bearing:
  our parser deliberately uses lazy-quotes semantics — a newline always ends a
  record, intentionally *not* RFC 4180 §2.6, validated on IMDb's 12.5M rows —
  and the parallel chunked pipeline depends on that property to split chunks at
  all. If upstream is strict RFC 4180 here, this is a policy decision like
  `zipstream`'s output cap, not a drop-in.

- **Transport core** — `http`, `rest`, `api`, `mcp`. The concrete piece is
  `bxp-mcp/src/server.zig` (384 lines: JSON-RPC 2.0 framing over stdio plus the
  MCP handshake), which the `mcp` module covers. `tools.zig` and `sim.zig`
  (1 270 lines) are bxp-specific and stay — they would need reseating on the
  upstream transport's API, which is what makes this a larger job than the
  items above rather than a swap.

- **`procrun`'s runner half** — only the reap core was taken. The capped
  3-thread stdio drain, the streaming handle with cancel/kill escalation and
  the backpressure ack are still the bridge's own, because that machinery
  dispatches into Dart ports rather than into caller buffers. Reseating
  `bridge_run_streaming` on `procrun.spawnStreaming` would be a rewrite of the
  bridge's threading model, not a swap — worth revisiting only if that model
  needs work for its own reasons.

- **Dart side** — `json5_ast` has no zig-libs equivalent (different language);
  still waits for a second Dart consumer.

Deliberately **not** adopted, recorded so the survey is not repeated:
`xml` builds an infoset tree where our `XmlTok` is a windowed streaming
tokenizer — taking it would forfeit the O(window) memory ceiling that is the
whole point of the xlsx path. `dataset` / `tabular` / `jsonshape` / `finstats`
are a materialised columnar stack, the opposite architecture to a row-streaming
pipeline. `workerpool` / `lockfree` would replace a tuned, green work-stealing
unpack with no measured problem to solve. `metrics` is a Prometheus registry
against our two-number `BXP_METRICS`.

### Expression builtins

**Secondary / niche — on hold indefinitely.** No concrete use-case; add only
when a real one appears. All fit the existing `FnDoc` + `ArgKind` pattern
unless noted:

- String / parsing: `REPT(s, n)`.
- Calendar / clock components: `QUARTER(d)`, `WEEKNUM(d)`, `DATE_TRUNC(unit, d)`,
  `HOUR(d)` / `MINUTE(d)` / `SECOND(d)`. The time extractors need a canonical
  ISO-datetime input decision first (bxp's date model is date-only today).
- Validation: `IS_NUMERIC(x)`, `IS_DATE(x)`.
- Math: `SIGN(x)`, `TRUNC(x)`, `MROUND(x, m)` are exact on the fixed-point
  decimal core. `POWER(base, exp)` and `SQRT(x)` are **blocked on a design call**,
  both need floating point, which conflicts with the deliberately float-free
  decimal core; revisit only with an integer-exponent-only `POWER` or an explicit float-approximation mode.

### Re-take the Linux bench reference on a quiet machine

The documented Linux reference is S17 (`results-20260616-160353.csv`,
22.36 s total). A 2026-08-16 run measured 26.23 s — but re-running the
*reference commit itself* on the same day gave 24.86 s, so most of the gap is
the machine, not the code: those runs happened under a load average of ~1.8
(browser + editor + language servers), whereas the reference was taken on an
idle box. The Ubuntu 24.04 → 26.04 upgrade (2026-06-29) is not implicated —
S17 predates it and the post-upgrade run matched it to within 0.03 s.

Take a fresh reference **after a reboot, with nothing else running**, and
record it as S18. Recording one now would bake ~11 % of ambient load into the
baseline and cause a false *improvement* next time.

While writing it up, add the protocol note that actually prevents false
alarms: a stored reference ages, so on any suspected regression re-run the
baseline commit in the same session and compare that pair. Comparing a fresh
run against a weeks-old stored number cannot separate code from machine.

### `fetch-full.sh` for the RÚIAN example

`docs/examples/real-world/ruian-address-points` is the only real-world example
without one, so its full-scale claim is the only one a reader cannot reproduce
by running a script. The portal is form-driven, but the published exports sit
at a stable path:

```text
https://vdp.cuzk.gov.cz/vymenny_format/csv/<YYYYMMDD>_OB_ADR_csv.zip
```

dated to a month end (`20260731` resolves; `20260801` 404s). The script should
discover the most recent available date rather than hard-coding one, drop the
archive in `./full/` like its siblings, and ship the matching `full.json`
(`sample.json` with `data_dir` repointed). Verified 2026-08-16: 61 MB archive,
6 258 members, 338 MB unpacked, 3 020 222 combined rows in 9.82 s at 29.9 MB
peak RSS on the shipped ReleaseSmall build — which matches the README's
"about 10 seconds at ~28 MB" as written.

### Cover the examples tree in the test suite

`scripts/test-07-datasets.sh` gates the 10 fixtures under `datasets/`, but the
32 `*.expected` files under `docs/examples/` are gated by nothing. They carry
edge cases the datasets do not — JSON-emitting templates, multi-hop pre_pass
chains, self-joins, wide-to-long unpivots, sexagesimal coordinates, HL7
segments — so a regression there currently reaches a release unnoticed. A
`test-08-examples.sh` would need two things `test-07` does not: outputs are
`*.csvx` **or** `*.json` (`file_type_out: json`), and committed output
artifacts must not be seeded into the work dir as inputs (multi-stage-etl's
`1-final.json` would otherwise be picked up by a later template's `data_dir`).
All 32 verified green by hand on 2026-08-16.

### Encoding — more single-byte code pages

The `encoding` module covers Win-1250/1252 and ISO-8859-1/2/15 today. The
256-entry override-table pattern makes each new code page ~mechanical
(Win-1251 Cyrillic, ISO-8859-5, …). Marginal cost is low; no work until a
broker export actually demands one — and note the module now lives in
zig-libs, so a new code page is an **upstream** change plus a pin bump here,
not an edit in this repo. The bxp-side work would be limited to the
`csv_encoding_values` dropdown, which is comptime-derived from the enum and
therefore picks a new arm up for free.

## Not planned

Features that surface repeatedly in audits and reverse-simulations but are
deliberately **out of scope** — documented here so the same discussion
doesn't keep restarting. Reopen only if the rationale changes.

- **Multiline quoted fields (`csv_multiline_quotes: true`).** `csv.LineIterator`
  deliberately uses lazy-quotes semantics — a newline always ends the record
  (design decision, validated on IMDb 12.5M rows). This is intentionally
  NOT RFC 4180 §2.6. An opt-in RFC mode would require quote-aware chunk
  splitting in the parallel pipeline or a serial fallback; no real broker
  file with embedded newlines has ever been confirmed.
- **Aggregation across rows (SUM / COUNT / GROUP BY).** Conflicts with
  bxp's row-by-row engine philosophy — every output row is a pure
  function of one input row plus the pre-pass lookup table, no global
  state. Adding aggregation would require fundamental engine redesign.
- **Routing to multiple output files** One template
  produces one output stream (plus optional `combined_output`).
  Workaround: define two templates with different `row_rules` filters
  pointing at the same `data_dir`.
- **Output row deduplication across output files** The re-import scenario
  it would solve — overlapping date ranges across successive broker exports
  producing duplicate `.csvx` rows.
  Workaround: use `date_filter_from_filename:true` in template.
- **Space / NBSP thousands grouping (`csv_thousands_separator_in`).**
  Space- or NBSP-grouped European numbers (`1 234 567,89`) are not
  auto-normalised: `parseGroupedNumber` disambiguates dot/comma grouping
  (because `csv_decimal_separator_in` declares the decimal char), but a
  space/NBSP thousands separator stays raw.
  Workarounf: strips it with `REPLACE(REPLACE([X], ' ', ''), ',', '.')`
