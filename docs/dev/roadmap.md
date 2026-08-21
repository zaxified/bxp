---
description: "Planned work by version, and the things deliberately not planned, with the reasoning for each."
---

# Roadmap

Hand-maintained backlog — entries get crossed out / deleted as work
lands on master. `CHANGELOG.md` is generated independently.

## Milestones

### v0.3.1

`LOOKUP` across templates within one bxp-cli run cycle

### v0.3.2

### v0.3.3

Transformation visualiser

### v0.4.0

GUI Config/Create - Import wizard from sample CSV
GUI updater progress bar
GUI input file viewer simple viewer

Adopt `material_ui` 1.x — the real Material implementation, not the 0.0.1
facade the imports point at today. Blocked on `pluto_grid`, `pluto_menu_bar`
and `flex_seed_scheme`, which all still build on the SDK's Material: under a
`material_ui` `MaterialApp` their `TextField` / `showDialog` / `PopupMenu`
would not find the SDK `MaterialLocalizations` they assert on, and
`flutter analyze` cannot see that. Move once those three ship material_ui
builds, or replace them.

### v0.5.0

Full agentic automation - AI support for all steps in workflow

## Planned features - not version specific

### External template JSON files

Today bxp-cli has no concept of a template library: all templates live
inside one user-owned config file (`bxp-cli.json`), and the starter
set ships as a single monolithic `resources/console/bxp-cli.examples.json`.
Users who want a specific template have to copy/paste it out of
the examples file into their own config. Split the starter set into a
per-source template library so:

- A discovery dir (`templates/revolut.json`, `templates/trading212.json`,
  …) ships next to the binary; users can also drop their own files into
  a per-user dir and the discovery merges both with the user dir winning
  on name collision.
- bxp-mcp's `bxp_list_templates` / `bxp_fetch_template` work without a
  user-owned `bxp-cli.json` — they enumerate the discovered library.
- Per-source variants can be added or revised independently without
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

**Sugar over idioms that already work — on hold.** Each of these is one
existing expression away. The spellings below were evaluated rather than
assumed, so what a builtin would add here is discoverability, not capability;
add one when a real workflow keeps tripping over the idiom.

- `DATE_TRUNC(unit, d)` — snapping a date to the start of its period. Start of
  month is `DATE_CONVERT([D], 'YYYY-MM-DD', 'YYYY-MM') & '-01'`; start of the
  ISO week is `DATEADD([D], 1 - WEEKDAY([D]))`; start of year is the same trick
  through `YYYY`. All three are in the dates guide.
- `MROUND(x, m)` — rounding to a multiple: an exchange tick, a lot size.
  `ROUND([Price] / 0.05, 0) * 0.05` is exact on the decimal core. The likeliest
  of the three to earn its place, because tick sizes are real broker data and
  the idiom is easy to write slightly wrong.
- `SIGN(x)` — direction carried in the sign of an amount reads better spelled
  out: `IF([Amount] < 0, 'SELL', 'BUY')`.

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
- **Output row deduplication.** The re-import scenario it would solve —
  overlapping date ranges across successive broker exports producing
  duplicate `.csvx` rows. Dropping duplicates inside the combined roll-up
  is no cheaper: the sink is fed pre-serialised bytes assembled in parallel,
  so it would need either a shared lock in the per-row path or a serial
  pass over the finished file.
  Workaround: use `date_filter_from_filename:true` in template.
- **Space / NBSP thousands grouping (`csv_thousands_separator_in`).**
  Space- or NBSP-grouped European numbers (`1 234 567,89`) are not
  auto-normalised: `parseGroupedNumber` disambiguates dot/comma grouping
  (because `csv_decimal_separator_in` declares the decimal char), but a
  space/NBSP thousands separator stays raw.
  Workaround: strip it with `REPLACE(REPLACE([X], ' ', ''), ',', '.')`
