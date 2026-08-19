# Roadmap

Hand-maintained backlog — entries get crossed out / deleted as work
lands on master. `CHANGELOG.md` is generated independently.

## Milestones

### v0.3.1


### v0.3.2

Simplify manual page (resources/readme.md) - add url links to github mkdocs.
The plan: fold the distribution readme into `docs/` so it becomes part of the
published site, and let the copy that ships in the archives link out to both
the versioned `docs/` in the repo and the live Pages site. **Blocked on
reconciling the drift below — do that first.**

`LOOKUP` across templates within one bxp-cli run cycle

Output row deduplication in combined output files `combined_output_dedup: bool    // (default:false)`

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

### CSV formula-injection guard — quoted-path gap

**Correction (2026-08-16).** The zig-libs sweep recorded this as "we have no
guard at all" and queued `csvsafe` to supply one. That was wrong: `writeSafeValue`
in `pipeline.zig` has carried the guard since before v0.2 and it was refined in
`30ee2ac` (2026-06-02). It prefixes a single apostrophe on a leading `=`, `@` or
tab unconditionally, and on a leading `+`/`-` only when the next character is
not a digit or the decimal separator — the carve-out that keeps `+420 555 0101`
and `-12.34` intact. Adopting `csvsafe` would be a second guard over the first;
do not.

What IS open is narrower: **the prefix only runs on the unquoted path.** When
`csv_text_quote_out` is set and the value contains the output delimiter, the
quote char, CR or LF, `writeSafeValue` takes the RFC 4180 quoting branch and
returns before the prefix switch. Probed 2026-08-16 against the shipping
binary, with `csv_text_quote_out: "double"`:

| Output value | Guarded? |
| --- | --- |
| `=cmd\|'/c calc'!A1` | yes — `'=cmd\|…` (no delimiter, so no quoting) |
| `@SUM(A1)` | yes — `'@SUM(A1)` |
| `@SUM(1,1)` | **no** — `"@SUM(1,1)"` (comma → quoted branch) |
| `=HYPERLINK("http://evil","click")` | **no** — quoted, quotes doubled |

CSV quoting is stripped by the spreadsheet before the cell is parsed, so a
quoted `=…` still evaluates. The same early return applies to the pre-quoted
passthrough branch (values from `'''` expressions).

This is reachable in shipping configs — all four `xtb*` datasets and the
real-world examples set `csv_text_quote_out: "double"` — but only for a cell
that both starts with a formula character and contains a delimiter/quote. No
record of the quoted path having been considered when the guard was written, so
treat it as an oversight rather than a decision.

**Task: survey the consumer impact before touching the code.** Closing the gap
means writing an apostrophe into cells that do not have one today, and the
apostrophe is part of the value for anything that is not a spreadsheet. That is
exactly why the existing guard was kept conservative in `30ee2ac`, so the same
caution applies here: the change is cheap, deciding whether it is safe is not.
The survey has to answer, in this order:

1. **How often does the trigger actually fire?** The gap needs a cell that both
   starts with `=` / `@` / tab (or `+`/`-` followed by a non-digit) *and*
   contains the output delimiter, the quote char, CR or LF. Measure rather than
   guess: scan every output the repo can produce — `datasets/*`, every
   `docs/examples/**` config, and a real-broker run — for cells matching that
   shape. A zero count over the whole corpus would already downgrade this to a
   documentation item.
2. **What breaks downstream if the apostrophe appears?** The consumers are
   Wealthfolio's `.csvx` importer, brycht.app, Ghostfolio, the GUI's own output
   preview, and `datasets/*.expected` (a changed cell is a failing regression
   test by construction — that one is a *measurement*, not a breakage). A
   programmatic importer that reads the field verbatim would see `'=…` where it
   used to see `=…`. Check the two shipping targets specifically; a portfolio
   tracker importing a `comment` column is the realistic case.
3. **Confirm the threat, do not inherit it.** Verify in current Excel,
   LibreOffice Calc and Google Sheets that a *quoted* `=…` cell really does
   evaluate — the claim above is derived from how CSV quoting is stripped
   before cell parsing, not from a run. If a current spreadsheet already
   refuses it, the gap is theoretical.
4. **Check what comparable tools do.** Neither Go's `encoding/csv` nor Python's
   `csv` writer guards at all; the guard is a bxp addition. Whether OWASP's
   CSV-injection guidance distinguishes the quoted case is worth a look before
   inventing a rule.

Only then pick between (a) extending the prefix to the quoted branch and the
pre-quoted passthrough, (b) making the whole guard an opt-in config key and
extending it only there, or (c) recording the gap as accepted with the numbers
that justify it. Whichever wins, the `+`/`-` numeric carve-out must survive —
re-introducing `'+420 555 0101` would be a regression of the fix that created
it.

### Reconcile the readme reference against the catalogs before linking it out

Prerequisite for folding `resources/readme.md` into the site (v0.3.2). Before
a hand-written table can be replaced by a link, the two have to agree — and
measured 2026-08-17, they do not.

The **inventory** matches exactly: all 57 expression builtins appear in both
the readme and the generated `docs/reference/expr-functions.md`, with nothing
extra on either side. The **descriptions have diverged**, and in both
directions — word-overlap per function has a median of 0.38, with 39 of 53
comparable entries below 0.5. It is not only rewording; each side documents
facts the other omits:

| Builtin | Only on the site | Only in the readme |
| --- | --- | --- |
| `ROUND` | rounds half away from zero | negative `n` rounds tens / hundreds |
| `RAND` | not cryptographically secure | — |
| `FIELDS` | argument must be a positive integer | needed for `csv_header_line: 0` |
| `WORKDAY` | — | no exchange-holiday awareness |

So the work is not a swap, it is a merge, and it has a direction: **anything
the readme documents that is true and missing belongs in the `FnDoc` /
`FieldDoc` catalog**, from which the site page regenerates. Merging the other
way — editing the generated page — would be undone by the next `gen-docs.sh
--build`. Once the catalogs carry the union, the readme table has nothing the
link would lose.

The same comparison still has to be run for the other reference tables (CLI
flags, exit codes, config schema incl. the nested object schemas, date tokens,
MCP and gui-mcp tools); only the expression catalog was measured.

Worth deciding at the same time: the readme opens its reference half by
claiming it is written so an assistant can produce a working template *"given
only this file and `bxp-cli.examples.json`"*. Repeated attempts to do exactly
that have never yielded a working config, so the claim is not true today and
should not survive the rework unedited.

Optional, and cheap either way: a CI check that the catalog name sets and the
readme's name sets match — no prose comparison, just presence. That is what
would have caught the missing `--trace` / `--trace-file` / `zip_input` entries
the 2026-08-17 audit found by hand, and it is independent of whether the
tables end up inline or linked.

### The macOS updater never checks the host architecture

`UpdaterService._platformAssetPattern()` matches the release *asset name*
`bxp-desktop-macos-arm64.dmg`. Nothing anywhere reads the host architecture, so
an Intel Mac matches that asset, downloads it, and installs an arm64 build that
cannot run. The comment beside the pattern asserts the opposite — that Intel
Macs "fall through to the manual-update message" — and the user-facing docs
repeated that claim until this was found (2026-08-17); they no longer do.

Not reachable today only because the release matrix ships no Intel artifact and
the affected population is small, but the failure is silent and leaves the user
with a broken install rather than a message. Gate the macOS branch on the host
architecture and route anything that is not arm64 to the existing
manual-update path — the same path Linux non-AppImage builds already take.

### Cancelling a stream does not reach the child's grandchildren

`bridge_cancel` signals the direct child. A grandchild the child forked
inherits the stdout pipe, so the pipe stays open and `on_exit` does not fire
until that grandchild exits. Measured 2026-08-16, unchanged by the `procrun`
migration: cancelling `sh -c 'sleep 20'` takes the full 20 s, while
`sh -c 'exec sleep 20'` cancels in 0.3 s.

Not live today — the only thing the bridge spawns is `bxp-cli`, which forks
nothing (its parallelism is threads). The fix is now one flag away:
`procrun.Spec.new_process_group` puts the child in its own process group and
`Handle.cancelGroup` signals `-pgid`, reaching the whole tree. It was
deliberately NOT turned on with the migration, because it changes what a
cancel kills, and inheriting an upstream default silently is the mistake the
`zipstream` cap taught us to avoid. Decide it on its own merits if bxp-cli
ever spawns anything, or if a user reports a hung cancel.

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

- **Multiline quoted fields (`csv_multiline_quotes: true`).** `csvstream`'s `LineIterator`
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
  Workaround: strip it with `REPLACE(REPLACE([X], ' ', ''), ',', '.')`
