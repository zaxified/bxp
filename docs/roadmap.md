# Roadmap

> [← docs/](README.md)

Forward-looking milestones. Hand-maintained — `CHANGELOG.md` is the
shipped history; this file is what's planned. Items move out of here
into a `CHANGELOG.md` entry when their PRs land + a release is cut.
`scripts/release-changelog.sh` generates the `CHANGELOG.md` entry
automatically from `git log` when cutting a release.

## v0.2.4

### Expression built-ins — string and boolean utilities (shipped 2026-05-26)

Surfaced by the 2026-05-17 real-world-dataset session (HubSpot picklists,
NOAA sentinels, IMDb `\N` null markers, Inside Airbnb price prefixes).
Several patterns required nested-`IF` workarounds that single built-ins
collapse cleanly:

- `LEFT(s, n)` / `RIGHT(s, n)` / `SUBSTR(s, start, length)` — fixed-position
  slicing (ISIN country prefix, broker ticker suffix strip).
- `STARTS_WITH(s, prefix)` / `ENDS_WITH(s, suffix)` — anchored prefix/suffix
  match; `CONTAINS` was position-agnostic and false-positive-prone on
  picklist / category checks.
- `UPPER(s)` / `LOWER(s)` — ASCII case normalisation; non-ASCII bytes
  pass through unchanged.
- `NOT expr` — boolean negation keyword. Precedence between comparison
  operators and `AND` — `NOT [A] = 1` means `NOT ([A] = 1)`. Multiple
  NOTs stack.
- `NULLIF(value, sentinel)` — empty string when `value == sentinel`,
  otherwise `value`. Equality matches `=` semantics (numeric first,
  then string). Collapses NOAA `-9999`, IMDb `\N`, `"N/A"` sentinels.
- `IN(value, v1, v2, ...)` — variadic equality OR-chain. Replaces nested
  `IF([X] = 'A' OR [X] = 'B' ...)` patterns. Action picklists use the
  explicit listing (vs `STARTS_WITH` on a shared prefix) so that a
  broker adding a new action variant forces a template review.

Catalog grew from 18 to 27 functions and 2 to 3 keywords; corpus from
117 to 144 cases. Real-world validation: 78 `.csvx` byte-identical on
`DEV/` before/after rewriting 7 `OR`-chain `when` clauses to `IN`.

## v0.2.5

### External template JSON files

Today the conversion templates are baked into `bxp-cli` (and surfaced
through `bxp-fmt --list-templates` / `--fetch-template`). Move them out
to user-editable JSON files shipped alongside the binary so users can:

- Add or tweak templates without rebuilding bxp-cli.
- Ship per-broker variants without bloating the core binary.
- Override built-in templates locally (user dir wins over bundle dir).

Open design questions to resolve before implementation:

- Discovery path order — bundled `templates/*.json` next to the binary,
  then `~/.config/bxp/templates/` (Linux) / `%APPDATA%\bxp\templates\`
  (Windows) / `~/Library/Application Support/bxp/templates/` (macOS)?
- JSON5 or strict JSON for template files? (consistency with config
  loader argues JSON5).
- Migration path for the templates currently embedded in `bxp-cli` —
  generate them out at release time vs ship as a one-shot extractor.
- `--list-templates` / `--fetch-template` semantics when the same name
  exists in bundle + user dir.

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

Planned for v0.2.4: switched `_verifyChecksum` to fail-closed — missing
`SHA256SUMS`, fetch failure, asset not listed in SUMS, and hash mismatch
all now refuse the install with a specific message. Release page link in
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

### macOS keyboard shortcut idiomatization

Today every app-level shortcut in `main_view.dart:_handleKey` uses
`Ctrl+...` regardless of host platform. On macOS the idiomatic modifier
for Save / Undo / Redo / etc. is `Cmd` (Meta), not Ctrl. A Mac user
pressing Control still triggers our handler, so nothing is broken, but
the binding is foreign to the platform conventions and clashes with
Mac muscle memory.

Two changes needed:

- **Modifier swap.** Switch `HardwareKeyboard.instance.isControlPressed`
  to `isMetaPressed` on macOS via a `defaultTargetPlatform`-aware
  constant. Linux / Windows stay on Ctrl.
- **Mission Control collision.** `Ctrl+Up` / `Ctrl+Down` is a default
  macOS system shortcut for Mission Control. Our move-tree-node binding
  is `Ctrl+Shift+Up/Down`, which the default Mission Control config
  doesn't intercept, but a user who has remapped Mission Control to the
  Shift variant in System Settings will lose tree move. Flipping the
  whole shortcut set to Cmd-prefixed makes the collision vanish (Cmd
  isn't in any Mission Control binding).

## v0.4.0

### Declarative arg-type contracts for expr builtins

The 2026-05-14 audit (commits `076ca9c` + `f51940e`) found three independent
`@intFromFloat` panic bugs in `expr.zig` builtins — `FIELDS`, `SPLIT_PART`,
`ROUND` — all stemming from the same pattern: each function gates its own
args (or forgets to), and `f < 1.0` doesn't filter `±Inf` or `NaN` because
IEEE comparisons against them return false. Quick fix shipped: shared
`toPositiveIndex` helper. The class of bug isn't structurally prevented —
a 19th builtin written the same way would crash again.

Plan for v0.4.0:

- Add `accepts: ArgType` field to `ArgDoc` in `expr.zig`. Types: `any_value`
  (default, no validation), `any_string`, `any_number`, `finite_number`,
  `positive_integer`, `integer_in_range{min, max}`.
- Move argument validation into the central `evalCall` dispatcher
  (`bxp-core/src/expr.zig:1169` area). Validator runs against declared
  types BEFORE the builtin impl is called — impls receive guaranteed-valid
  args and can drop their defensive boilerplate.
- Surface `accepts` in `bxp-fmt --docs` JSON so `bxp-gui` debugger can
  show arg-type hints in autocomplete and flag templates whose literal
  args fail static validation.
- Same validator becomes the single source of truth for `bxp-fmt --expr`
  and `bridge_eval_expr` (FFI), eliminating parity drift between the two
  evaluators ahead of TODO 4 Phase 3.

Full design + migration plan: `DEV/6-todo-builtin-arg-validation-design.md`.

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

## Later (no specific version)

### CPU parallelism (next perf priority)

After the 2026-05-24 NDJSON rip the three big memory/IO rocks landed:
RSS (10 GB → 13 MB stable), GUI memory (sparse trace model + lazy
source-CSV load), btrace size (4× faster trace=on, 206× smaller
stream). The remaining wall-time scaling lever is multi-core. Bench
machine has 8 cores; `bxp-cli` today processes one template
single-threaded, leaving 7 cores idle.

**Target bottleneck: one large source file.** The bench bottlenecks
that hurt — S1 2M rows off=42 s, S3 1024-col off=65 s — and the
real-world workloads (CRM migrations, single-broker exports) both
live in a single file. Multiple smaller files are not the pain point.

Three attack points, ranked by **value against the real bottleneck**
(not by implementation difficulty):

- **Per-chunk parallelism within a file (the only one that matters).**
  Harder to implement, but the only candidate that attacks "one big
  file" wall time. Pipeline becomes
  `reader → chunk queue → N workers → ordered writer`. Per-thread
  `chunk_arena`, per-thread output + btrace buffers, writer thread
  reassembles in chunk-sequence order. Pre_pass stays a barrier
  (read-only `lookup_table` post-barrier); pre_pass itself can also
  parallelise with thread-local partial maps + merge if it becomes
  the new bottleneck. JSON path (slurp-then-iterate) parallelises
  trivially by splitting `all_rows` into ranges.
- **Per-file parallelism.** Implementation-easy (files already
  independent), but does nothing for N=1. Useful only for the
  multi-broker concat case (one template, several input files)
  and even there the win is small because per-file work is already
  fast. Not the target.
- **Per-template parallelism.** Trivial to add but only matters when
  the user runs multiple templates in one invocation. Most runs are
  single-template.

Audit of serial state inside `processBroker` (per file) for the
per-chunk path: `chunk_arena` (per-chunk, reset on transition);
`ChunkReader + csv.LineIterator` (10 MiB streaming); `file_rows_written`
(monotonic, used as btrace `outputIdx`); `file_expr_errors` /
`file_warnings` (file-scoped counters); `fout` (`.csvx` writer,
order matters); `combined_fout` (cross-file, even more serial);
`btrace_writer` + `btrace_file_writer` (frame sequence
`file_start → prepass → output/filtered/error → file_end`);
`out.writer` for stderr (debug + warning prints). Everything in
`expr.Context` and `line_arena` is per-row scratch — safe.

`scripts/bench/` already supports `BENCH_PARALLEL=N` for the run
matrix; this work is about **internal** parallelism inside one
`bxp-cli` invocation.

### CI hardening

- `.github/workflows/ci.yml` — run `scripts/test.sh` on every PR. Today
  only the release workflow exists; PRs go untested by CI.
- Flutter `integration_test` smoke run inside CI (Xvfb on Linux runners,
  headless setup on Mac / Win).

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

- **CSV preamble / title line skipping.** Schwab's transactions CSV
  starts with `"Transactions for account XXXX-1234 as of …"` on line 1
  and the actual headers on line 2. bxp-cli has `xlsx_sheet.header_row`
  for xlsx but no equivalent for plain CSV. Add
  `csv_header_row: N` (default `1`) — skip the first `N-1` lines before
  treating line `N` as the header. Touches `pipeline.zig` (`ChunkReader`
  header skip) + `config.zig` (FieldDoc + load) + integration test.

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

- **Readme polish** — add an `OR` example to "Minimal examples"
  (`[Action] = 'Buy' OR CONTAINS([Action], 'Buy to')   → catch all buy
variants`). Tiny.

- **`csv_decimal_separator_in: ","` consistency.** Surfaced by
  Comdirect-style German locale simulation (2026-05-07). The current
  implementation pre-converts UNAMBIGUOUS comma-decimals at field-access
  time (`75,00` → `75.00` string) but leaves multi-`.`-multi-`,` values
  raw because it can't disambiguate. Expressions then receive a mix of
  pre-converted and raw strings, which forces template authors to write
  a defensive `IF(CONTAINS([X], ','), strip+swap, [X])` wrapper around
  every numeric expression. Fix options: (a) convert ALL comma-decimal
  fields consistently using a paired `csv_thousands_separator_in: "."`
  flag; (b) always normalise at field-access time using a smarter
  heuristic (last non-numeric char wins as decimal); (c) leave behaviour
  alone but add a built-in `PARSE_EU_NUMBER([X])` function that does the
  strip+swap+ABS in one call. Decide by feasibility: (c) is cheapest.

- **Mutually-exclusive `--trace` and `--debug` is awkward for self-test.**
  AI agents authoring a template need both: `--debug` for runtime expr
  errors and unmatched-row JSON; `--trace` for per-row event detail.
  Today they must run two passes. Could `--trace --debug` be allowed,
  with the debug JSON written to stderr (alongside warnings) so the
  BXTB frame stream on stdout stays clean? Touches `bxp-cli/main.zig`
  arg validation + `Output` struct. Small change, big workflow win.

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

### Tooling

- Zig 0.16 migration. Currently pinned to 0.15.2; 0.16 shipped
  2026-04-15 with breaking I/O API changes (~100–150 LOC affected).
  Assessment in `project_zig16_migration` memory. Bundle this with
  `REGEX_MATCH` / `REGEX_EXTRACT` below — the only mature native-Zig
  regex (zig-utils/zig-regex v0.2.0, 2026-05-18) requires Zig 0.16+.

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

## Done

Historical milestones live in `CHANGELOG.md`. This section stays empty
on purpose — once a roadmap item ships, it moves to the changelog entry
for that release (generated by `scripts/release-changelog.sh`) and the
line here is deleted.
