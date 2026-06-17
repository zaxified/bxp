# Changelog

## 2026.06.17 — bxp-cli 0.3.0, bxp-mcp 0.3.0, bxp-gui 0.3.0

### Features

- feat(core): Zig 0.16 — bxp-gui-bridge migrated; all 4 Zig packages green
- feat(expr): add REGEX_MATCH / REGEX_EXTRACT builtins
- feat(installer): ship a dark theme for the Windows NSIS installer

### Fixes

- fix(core): Zig 0.16 — give inspect eval Contexts a real Io (NOW/RAND)
- fix(cli): Zig 0.16 — self-declare psapi GetProcessMemoryInfo (Win peak RSS)
- fix(gui-bridge): Zig 0.16 — self-declare kernel32 TerminateProcess (Win cancel path)
- fix(test): Zig 0.16 — build bridge phases in ReleaseSafe (test-03/04)
- fix(test): make test.sh bash 3.2 compatible (macOS false-green)
- fix(test): portable trace-size check in test-07 (macOS BSD stat)

### Internal

- ci: skip the full test matrix on the release-prep commit
- docs(devel): point zig skill to nzrsky/zig-skills (Zig 0.16.0)
- build(core): flip uucode pin to main (Zig 0.16)
- test(gui): cross-platform bridge streaming-load probe (Zig 0.16 verification)
- test(cli): Zig 0.16 — io-thread the ChunkReader inline test
- docs: Zig 0.16 pre-release sweep — bridge layout + migration status
- refactor: Zig 0.16 — deprecated std.fs.path -> std.Io.Dir.path
- ci: persist a shared Zig build cache across runs
- ci: pin -Dcpu=baseline across the test gate (CPU-stable build cache)
- ci: bump Zig cache epoch to `base` for the baseline-CPU gate
- ci: pin Flutter 3.44.2 + cache the SDK (roadmap CI hardening)
- ci: trim the cached Flutter SDK to the desktop subset
- docs: record CI build-cache work + Windows reliability backlog item
- ci: skip the Flutter SDK cache on Windows
- docs(roadmap): drop the CI hardening section
- test(expr): add REGEX_MATCH / REGEX_EXTRACT corpus cases
- docs(examples): add freeform-payment-memos regex example
- docs: document REGEX_MATCH / REGEX_EXTRACT across docs + readme
- docs(cli): Zig 0.16 — refresh stale concurrency comments + CLAUDE.md notes

### Other

- release(scripts): refuse to tag a non 'release: prepare' HEAD
- wip(core): Zig 0.16 — containers unmanaged, Writergate, mem.trimEnd
- wip(core): Zig 0.16 — container ripple done + NOW/RAND io-based
- wip(core): Zig 0.16 — zipstream io threading; 318 tests pass, 2 errors left
- wip(core): Zig 0.16 — bxp-core/cli/mcp green + runtime-verified; bridge build.zig
- bench: record Zig 0.16 full-bench as the new S17 baseline
- lint: fix typos in documentation


## 2026.06.16 — bxp-cli 0.2.5, bxp-mcp 0.2.5, bxp-gui 0.2.5

### Features

- feat(expr): full-Unicode UPPER/LOWER via uucode
- feat(expr): add UNACCENT builtin (Latin diacritic stripping)
- feat(encoding): Layer 0 CSV input/output encoding + xlsx UTF-16 guard
- feat(mcp): bxp-mcp MCP server + shared inspect core (dedup fmt)
- feat(mcp): batch/template/simulate tools + per-request arena + bundling
- feat(mcp): bxp_eval_trace + share expr-trace core in inspect (#2)
- feat(gui): in-proc bridge_inspect — GUI stops spawning bxp-fmt (B)
- feat(gui): BXP_FORCE_BRIDGE — disable bxp-fmt fallback to test the bridge
- feat(mcp): protocol depth — structuredContent, outputSchema, 2025-11-25, bxp_simulate BXTB trace + progress
- feat(gui): single bridge backend — drop Process.start + bxp-fmt fallback
- feat(core): inspect is the single stateless core — rehome fmt tests + add validateExprJson
- feat(mcp): add bxp_validate_expr tool — agent parity with bridge_eval_expr
- feat(fmt)!: delete the bxp-fmt module
- feat(gui): surface bxp-mcp path + version in the runtime inspector
- feat(gui): embedded MCP server for agent-controlled GUI (Phase 1)
- feat(gui): GUI-MCP Phase 2 — open/reload/run/delete/exit tools
- feat(gui): GUI-MCP get_trace tool — expose btrace run summary
- feat(gui): make GUI-MCP agent actions visible (panel + reveal)
- feat(gui): GUI-MCP reachability + structural/template/drill-down tools
- feat(cli): --debug=json summary, FileTooBig caps, audit follow-ups
- feat(expr): 11 new builtins — CASE/IFERROR, context, string/math
- feat(cli): zip_input pre-pass — unpack zipped-CSV exports before the main loop
- feat(expr): REMAP builtin + unified `maps` registry, retire TICKER/ticker_map
- feat(xlsx): parallel multi-sheet extraction fan-out
- feat(check-fs): validate xlsx_sheet.name exists in the workbook
- feat(gui-mcp): headless auto-approve for agent-driven GUI testing
- feat(gui-mcp): persist auto-approve as a bxp-gui.json pref + inspector toggle
- feat(gui): resolve global maps in drill-down + fix drill-down RAF race; warn on duplicate CSV headers
- feat(wide-csv): raise CLI MAX_COLUMNS to 16384 + cap GUI render at 200 cols
- feat(updater): minisign signature verification + release hardening

### Fixes

- fix(release): backtick `@tokens` in changelog so they don't ping GitHub users
- fix(mcp): audit follow-ups — isError, per-tool structuredContent, record counts; add docs/mcp.md
- fix(bridge): survive inherited SIGCHLD=SIG_IGN in bridge_run
- fix(bridge): ECHILD-tolerant streaming wait (survive Dart VM child reaper)
- fix(gui): kill startup crash — lazy version probes + tolerant getVersion
- perf(expr): O(1) builtin dispatch, single-join parseCat, inline args
- perf(xlsx): in-memory ZIP extraction for files within 100 MB
- perf(xlsx): stream ingest via zipstream — flat memory, no size caps
- perf(cli): parallelise zip_input unpack via work-stealing
- fix(config): snapshot FS-check worker inputs to fix detached-worker UAF
- fix(expr): bound parser recursion depth to prevent stack-overflow SIGSEGV
- fix(config): range-guard xlsx_sheet.header_row before i64->u32 cast
- fix(cli): clamp worker count to MAX_WORKERS_LIMIT instead of aborting
- fix(mcp): reject path-traversal file_pattern_in before staging sim input
- fix(xlsx): harden cell-value path against hostile/corrupt workbooks
- fix(json5): bound parser recursion depth to prevent StackOverflowError
- fix(mcp): index newline offsets once for O(log n) trace line lookup
- fix(gui): cap gui-mcp request body, guard notify-after-dispose, align underline offsets
- fix(ci): SHA-pin third-party actions + hard-fail unsigned release on tag push
- fix(ci): force UTF-8 in gen-readme.sh for cp1252 Windows runners
- fix(ci): enable Python UTF-8 Mode harness-wide for cp1252 Windows runners
- fix(gui): per-user Windows installer + rename-swap self-heal for self-update
- fix(gui): report real PackageInfo version in gui-mcp /health + handshake
- fix(cq): single-source versions/caps + correct stale post-v0.3.0 comments
- fix(cq): repair botched fmt→bridge comment scars + expr builtin-list pointer
- fix(cq): clear botched-rename 'the matching the bridge stdout' comment scars
- fix(cq): English-only pipeline comments + stale 'drill-down in fmt'
- fix(cq): bridge header still claimed 'single exported function bridge_run'
- fix(cq): clear remaining bridge flag-attribution comment scars (wrapped)
- fix(cq): correct stale 'spawns drop --check-fs flag' in trace_store
- fix(cq): last stale 'Bxp-fmt's keys' ref in trace_store \_mergeMaps
- fix(cq): wrapped doubled-'the' before 'bridge error' in loadConfig
- fix(cq): garbled 'expr validator validate' doubled-verb in expr_panel
- fix(cq): drop stale hardcoded line number in pipeline comment
- fix(bridge): join stream readers before reaping to end fd race
- fix(scripts): scope check-formatting prettier to _*.md_ only

### Internal

- docs(roadmap): purge items shipped in v0.2.4 (CI matrix, cross-platform bench, updater fail-closed)
- chore(lint): exempt all CLAUDE.md files from markdownlint + prettier
- chore(gitignore): ignore codedb.snapshot (local code-intel cache)
- test(mcp): add test-05-mcp phase (build + unit tests + JSON-RPC smoke)
- refactor(bridge): share expr eval/trace core with inspect (dedup A)
- docs: correct stale 'bridge shipped only on Windows' note
- chore: pin Zig 0.15.2 + gitignore 0.16's project-local zig-pkg
- docs(roadmap): reconcile MCP/adapters section with shipped reality
- docs(roadmap): mark v0.3.0 bridge flip done + purge shipped items
- docs(bridge): drop stale bxp-fmt references — inspect core is the shared backend
- docs(cli): update drill-down comment — recomputed via bxp-cli, not bxp-fmt
- refactor(gui): drop bxp-fmt from the GUI entirely — bridge is the single backend
- build(scripts): rewire test oracle + release to MCP; add readme generator
- docs(resources): single-source the console + desktop readmes
- docs: rewrite developer + user docs off bxp-fmt onto inspect/mcp/bridge
- docs(root): drop bxp-fmt from repo map, CI, and lint config
- test: align bench-guard output with the shared step/summary column
- docs(roadmap): drop shipped + obsolete backlog entries
- docs(roadmap): note Spice-derived parallelism follow-ups under bxp-cli
- docs(roadmap): mark agent-controllable GUI (GUI-MCP) shipped
- docs(gui-mcp): document the agent workflow; prune shipped roadmap entry
- docs(roadmap): consolidate expr-builtin sections, drop shipped, English
- docs(examples): simplify expressions with CASE + ISEMPTY
- test(datasets): synthetic zip_input regression fixture
- docs(examples): RÚIAN address-points real-world example
- docs: document zip_input + parallel unpack, prune shipped roadmap
- test(bench): wire .xlsx + wide-column RSS points into the bench guard
- test(bench): xlsx multi-sheet fan-out RSS guard
- test(datasets): enforce the exit-0/no-warnings contract per fixture
- docs(cli): document intentional header/body over-width asymmetry
- chore(audit): close 2026-06-14 sweep — relocate residual notes, retire DEV reports
- test(gui): Windows bridge-streaming + GUI-MCP drive harnesses
- build(git): pin Flutter generated plugin registrants to eol=lf
- test(bench): Windows baseline (W01) + disk-safe low-disk & MSYS file-sink modes
- docs(roadmap): retire shipped v0.3.0 entries, add Zig 0.16 + extraction milestones
- test: unify test.sh on one optimize mode (ReleaseSafe) + reorder phases
- docs: refresh docs/ for the v0.3.0 bridge flip + recent features
- style: prettier-format remaining markdown (pre-release pass)
- docs(readme): position BXP as a professional product + fix Win install path
- docs: deep-audit pass over docs/, resources/, and CLAUDE.md
- chore(gui): drop superseded win_bridge_smoke harness
- docs: complete CLI flag / ENV coverage + flatten architecture bird's-eye

### Other

- md lint and prettier colision repairs
- prettier-check

## 2026.06.07 — bxp-cli 0.2.4, bxp-fmt 0.2.4, bxp-gui 0.2.4

### Fixes

- fix(bxp-gui): correct DartValidator positive_integer ArgKind drift

### Internal

- docs: architecture.md — fix mermaid syntax in validation + run-state diagrams
- docs: explain custom expr DSL choice + defer REGEX to Zig 0.16
- docs: relocate bridge FFI conventions + note template-strict/data-lenient policy
- test: add coarse perf-regression guard phase (test-07-bench-guard)
- docs: correct noaa "no column cap" claim + roadmap the 1024-column ceiling
- docs: comment/doc review sweep — stale refs, misattributed doc-comments, @-typos
- docs: comment/doc review sweep — bxp-gui/lib (store + main + ui + json_tree)
- docs: accuracy review sweep — CLAUDE.md + README + docs/ + examples
- docs: prettier --write (markdown table realignment)
- test(bxp-gui): add Windows bridge transport smoke harness
- test: make scripts/test.sh green on the Windows runner (CI-hardening prep)
- ci: cross-platform PR/push test workflow + portable bench-guard probe
- test(bench): self-measure wall+RSS so perf guard & bench run on macOS/Windows

### Other

- community: add PR template + SECURITY policy + README install polish
- scripts: test-05 — add mermaid block parse check
- bxp-cli: lift file-size cap to 1 GiB + MAX_COLUMNS to 1024
- examples: real-world dataset showcase with autoindex generator
- scripts: add bench harness for bxp-cli RAM/wall-time matrix
- scripts: add verify-output.sh + post-refactor bench result
- bxp-cli: stream input in 10 MiB chunks, bound peak RSS by chunk size
- bxp-cli: right-size ChunkReader buffer by remaining file bytes
- bxp-cli: reuse RowIterator row_buf across rows
- scripts/bench: sort + parallel + atomic input cache
- scripts/bench: post-row_buf-fix parallel matrix (2 min, full 25/25)
- bxp-cli: TraceMode enum + scaffolding for selective trace modes
- bxp-core: NDJSON writer fast-path in json.zig + Output.event delegation
- bxp-cli: propagate Safe through splitFields + row_start/row_output/var_eval
- bxp-cli: refactor rule_match via generic event() + trace snapshot in test-02
- scripts/bench: pre/post fast-path matrix (5 runs across 4 commits)
- bxp-core: add btrace module for binary --trace=bin stream
- bxp-cli: track per-record file byte offset in ChunkReader + RowIterator
- bxp-cli: wire --trace=bin through Output + main.zig
- scripts/test-02-datasets.sh: smoke --trace=bin magic + version per dataset
- scripts/bench: BXP_BENCH_TRACE_FORMAT=bin + M12 matrix vs M9 baseline
- bxp-gui: PR-A — Dart-side btrace parser (pure additive, no UI wiring)
- bxp-core: btrace v2 — symbol pools in file_start + 5 detail frame types
- bxp-cli: SymbolPools + per-row detail bin emit + --trace-file flag
- bxp-gui: Dart btrace parser updated to schema v2 (file_start pools)
- scripts/test-02-datasets.sh: bump expected bin magic to schema v2
- bxp-fmt: add --expr-batch subcommand for GUI drill-down re-eval
- bxp-core+bxp-cli: btrace schema v3 — drop per-row detail by default
- bxp-gui: SDK primitives for btrace-driven drill-down
- bxp-gui: btrace browser view — on-disk drill-down at 500 ms target
- bxp-gui: migrate RUNNER pipeline to live btrace stream (--trace=bin)
- scripts/bench: add results-20260522-010048 — 25/25 wall wins vs 18/05 baseline
- bxp: RUNNER btrace path completion + UX polish
- bxp-gui: Win bridge stdin + binary streaming + lazy source-CSV load
- bxp-gui: lazy source-CSV iterations — UX polish from Linux smoke
- bxp-gui: rows-out via re-eval, drop csvx fetch from drill-down
- bxp-gui: cleanup dead csvx I/O + eager btrace runtime publish
- bxp: rip NDJSON trace path — bin BXTB is the only --trace format
- bxp: shrink btrace to 7 metadata frames, drop schema version
- bxp-gui: refresh stale 'NDJSON mode' docstrings + comments
- bxp-gui: read _visibleRowIds fresh in PlutoGrid onSelected
- scripts/bench: add NDJSON→BIN comparison + clean post-rip baseline
- scripts/bench: add PROGRESS.md — wall/RSS progression across 13 sessions
- scripts/bench: prettier fmt for COMPARISON + PROGRESS markdown
- bxp-gui-bridge: drop dead line-mode streaming path
- bxp-core/json5: drop stale Phase-5d FIXME block
- bxp-cli, bxp-core/csv: drop dead row_safe / safe_buf fast-path
- bxp-gui/services: drop stale binary_mode JSON field
- bxp-gui/store: drop archaeological comments about ripped csvx path
- docs, CLAUDE.md: surgical NDJSON→BXTB drift fixes
- docs, bxp-core/expr: rewrite trace docs for BXTB protocol
- docs/roadmap: add CPU parallelism + themes, drop stale Win runner entry
- bxp-core/csv, bxp-cli: foundation for per-block parallel pipeline
- bxp-cli: extract per-row eval helper + add parallel worker primitives
- bxp-cli: wire per-block parallel CSV pipeline into processBroker
- scripts/bench: S14 results — per-block parallel CSV pipeline
- bxp: smp_allocator + worker btrace gate + sunrise FBA vendor patch
- docs/devel: ReleaseSmall vs ReleaseFast bench section
- bxp-core/json, bxp-cli: streaming JSON path + parallel per-block dispatch
- resources, lint: OR example in Minimal examples + bench work dir ignore
- bxp-cli, bxp-core: drop dead RowIterator + csv.splitRecords
- bxp-core/expr: add LEFT/RIGHT/SUBSTR/UPPER/LOWER/STARTS_WITH/ENDS_WITH
- bxp-core/expr: add NOT keyword + NULLIF and IN builtins
- resources/console: rewrite 7 row_rules OR-chains as IN()
- docs/roadmap: collapse v0.2.4 expr backlog to shipped summary
- docs/roadmap: drop shipped Wide-CSV section
- bxp-gui: survive wide-CSV (>64 col) drill-down without crashing
- docs/roadmap: note two future wide-CSV optimisation paths
- docs/devel: define BXTB acronym (BXP Trace Binary)
- bxp-cli/fmt: accept both --flag=value and --flag value forms
- docs/roadmap: align with backlog model + delete CPU-parallelism (shipped)
- expr: handle EU thousands grouping at field-access (no new JSON flag)
- bxp-gui: idiomatize keyboard shortcuts on macOS (Cmd vs Ctrl)
- docs/roadmap: drop macOS keyboard idiomatization (shipped)
- bxp-fmt/gui: ship v0.2.3 audit follow-on cluster
- audit v0.2.3: close gui diagnostics + bridge dedup/flake + core validator test
- expr: ship LEN/GREATEST/LEAST builtins
- expr: ship date builtin cluster (DATEADD/DATEDIFF/WORKDAY + components)
- docs/roadmap: triage post-v0.2.4 audit follow-up
- expr: unify builtin arg-metadata into one ArgKind domain system
- docs/expr: drop shipped arg-validation plan + roadmap entry
- expr/gui: clickable FUNCTIONS doc panel with runnable examples
- gui: open-dialog "create examples" button + bundle examples in desktop archive
- expr: preserve leading-zero & oversized-integer strings in evalString
- docs/roadmap: add problem-first findings from the real-world examples sweep
- examples: full-scale fetch infrastructure + fixes for the existing real-world set
- examples: add french-dvf-realestate + chicago-business-licenses (problem-first)
- examples: add covid-wide-to-long (unpivot wide→long via multi-row row_rules)
- examples: relocate synthetic hubspot to teaching tier + group index by tier
- examples: add gtfs-stops-selfjoin (pre_pass + LOOKUP self-join)
- expr: preserve passthrough precision in evalString (string-path canonicalisation)
- examples: 5 real-world + 8 teaching examples (problem-first + messy-idiom set)
- scripts: docs format/lint → pre-release-only check-formatting.sh
- roadmap: TZ-help builtins + 3 pre-release polish items
- examples: 7 multi-file COMBINE patterns + signpost index + per-readme run cmd
- roadmap: BUG-3 (DATE_CONVERT pre-1970) + future example candidates
- bxp-core: accept symlinks in data_dir filesystem validation
- bxp-fmt: tolerate ragged rows in --expr-batch / --expr-trace
- bxp-gui: pass singlePrepassName to row_rules override evalBatch
- bxp: fix CSV-injection + over-prefix + wire orphaned unit tests
- bxp-core: replace sunrise dependency with in-house datefmt.zig
- expr: add NTH_DOW builtin (nth/last weekday of month) + post-sunrise bench baseline
- roadmap: defer TZ_OFFSET/TZ_CONVERT + REPLACE_MAP to use-case-driven
- bxp-cli: --fresh always rebuilds combined_output roll-up (bug #5)
- roadmap: decide decimal numeric core (f80 → i128 @ 1e12)
- bxp-fmt: --expr emits {"ok":true} on success
- bxp-core: fixed-point decimal numeric core (f80 -> i128 @ 1e12)
- bxp-cli: constant-fold row-invariant input_schema vars (Phase 3A)
- bxp-cli: date-prefilter drops out-of-range rows before eval (bod 1)
- bxp-cli: skip input_schema vars overwritten by the winning rule (bod 2)
- change: update bxp-cli.examples.json
- bxp-cli/core: compile-once expr scaffold + ColRef node (Phase 3B.0-1)
- bxp-core/cli: tokenize-once for input_schema + row_rules (Phase 3B)
- bench: new baseline matrix after per-row expr eval perf arc
- bxp-core: route JSON/xlsx scientific notation through decimal core
- expr: fix optimization-path field-access bugs; bracket refs are name-only
- expr: treat numeric bracket [4] as a plain column name everywhere
- config: add csv_header_line (headerless / preamble CSV support)
- docs/roadmap: mark CSV preamble/headerless skipping done; sci-notation follow-up
- docs/roadmap: move space/NBSP thousands grouping to Not planned
- examples/hl7: use csv_header_line: 0 (the headerless case it motivated)
- csv: lazy-quotes (newline ends record) + RAND(n) + roadmap purge
- gui/runner: last-run duration in status bar + rows-in status filter
- docs/roadmap: unify Unicode/text subsystem (v0.4.0) + REPLACE overload + basic-builtin top gaps
- changed:   resources/console/bxp-cli.examples.json
- bxp-gui: remove never-wired _buildModelFromBtrace offline path
- bxp-gui: retire dead BtraceLoader; reshape its test to the live streaming reader
- bxp-gui/updater: indeterminate progress when Content-Length is absent
- scripts: fix publish-doc drift (semver not CalVer) + document test-07/bench + stop tracking bench-run CSVs
- bxp-fmt: unify std.Io.Writer casing (audit 🔵#2)
- json5_ast: fix off-by-one col on trailing-sign EOF + document dual comment-walker invariant
- bxp-cli: document date_fast_path error-accounting + decline epilogue dedup (audit close)
- bxp-core: guard negative-year `@intCast` UB in datefmt + audit doc fixes
- bxp-gui-bridge: raise shutdown flag before kill+join in streaming rollback (audit ⚠️#1)
- changed recomendation mermaid
- docs+release: ship bxp-fmt in console archive, fix agent self-test docs, reconcile readmes

All notable changes to BXP. New entries are prepended at the top by
`scripts/release-changelog.sh`; pre-existing release tags (v0.1.0,
v0.1.1) are hand-stubbed since they pre-date the automation.

## 2026.05.16 — bxp-cli 0.2.3, bxp-fmt 0.2.3, bxp-gui 0.2.3

Quality and tooling release. Fixes expression-evaluator crashes on
out-of-range inputs, hardens the bridge and updater, adds
`combined_output` template merging, ships three brycht.app tracker-mode
templates, and delivers a wave of tree UX and editor validation polish
in the GUI.

### Features

- feat(bxp-core,bxp-cli): `combined_output` template field — when
  `true`, all input files additionally write their rows into one merged
  file `1-{template_id}-combined{file_pattern_out}` inside `data_dir`,
  alongside the normal per-file outputs. Useful for tracking tools that
  import a single combined history file.
- feat(resources): three brycht.app tracker-mode templates —
  `trading212_to_brychtapp`, `xtb2_cash_to_brychtapp`,
  `xtb2_closed_to_brychtapp` — convert Trading 212 and XTB (new format)
  exports to the brycht.app CSV import format.
- feat(bxp-gui-bridge): cross-platform in-process expression
  evaluation — `bridge_eval_expr` / `bridge_eval_expr_trace` now
  available on Linux and macOS (previously Windows-only). The GUI
  expression validator and playground use the bridge path on all
  platforms for consistent latency and NDJSON trace parity.
- feat(bxp-gui): expression static-arg checks reach the editor
  first-pass — type and range errors reported as red underlines in the
  editor before the user runs a validation.
- feat(bxp-gui): case-insensitive function-name matching — editor
  highlights and the Zig evaluator agree on `IF` vs `if` etc.
- feat(bxp-gui): tree UX polish wave — sticky action overlay per row,
  custom schema tooltip without Flutter Tooltip focus capture, runner
  read-only mode (hover-on-matched + lookup popup + sort), map-key
  inline rename, add-child insert templates.
- feat(bxp-gui): validator UX — create-dir prompt on missing
  `data_dir`; fix `UnknownField` false-positive on valid keys.
- feat(bxp-gui): expression corpus cross-runner parity gate —
  `test/expr_corpus_bridge_test.dart` verifies bridge and `bxp-fmt`
  evaluate identically for all 112 corpus expressions.
- feat(bxp-core): Inf/NaN and out-of-range safety gates for
  `FIELDS(n)`, `SPLIT_PART(…, n)`, and `ROUND(…, n)` — previously
  panicked or produced junk on negative/zero/non-finite index
  arguments.
- feat(release): Linux desktop now ships as AppImage-only with
  versionless asset names (`bxp-desktop-linux-x86_64.AppImage`) and
  stable `releases/latest/download/` URLs. `.deb` and plain tarballs
  retired.
- feat(bxp-gui): first-run AppImage desktop integration — prompts
  once to write `.desktop` file + hicolor icons; toggle in Settings.
- feat(bxp-gui): fail-closed auto-updater — all four
  checksum-verify outcomes (mismatch, download error, missing
  `SHA256SUMS`, unexpected format) refuse to install.

### Fixes

- fix(bxp-gui-bridge): kill child process before joining reader
  threads on rollback to prevent a hang on bridge teardown.
- fix(bxp-fmt): route `--help` and `--version` output to stdout —
  previously went to stderr, breaking callers that captured stdout.
- fix(bxp-gui): guard `notifyListeners()` after `prefs.set` with
  `_disposed` check to prevent async setState-after-dispose assertion.
- fix(bxp-gui): close download sink on stream error to prevent file
  descriptor leak in the auto-updater.
- fix(bxp-core): defer `deinit` of seen-key hashmap in
  `readJsonRecords` so the map outlives the caller's arena.
- fix(scripts): cross-platform BSD/GNU `sed -i` divergence and
  macOS `sha256sum` / `shasum -a 256` fallback.

### Internal

- test(scripts): expression corpus regression gate (`test-06`) — runs
  the full 112-expression corpus through both `bxp-fmt --expr` and the
  bridge on every CI pass.
- chore: GitHub community standards — Code of Conduct, issue
  templates, license identifier fix.
- audit: pre-release 5-layer sweep — stripped 34 rotted `bxp-ui`
  provenance comments from `bxp-gui`; refreshed all 7 CLAUDE.md files
  (added a new `bxp-gui-bridge/CLAUDE.md` covering the C-ABI surface,
  Debug→ReleaseSafe rewrite, and Win-mandatory / cross-platform roles);
  refreshed 7 `docs/` files (incl. new bird's-eye bridge subgraph,
  per-call routing table in devel.md, transport-paths section in gui.md,
  trace-protokol ArgKind drift, architecture.md mermaid file refs);
  cleaned speculative TODOs.

## 2026.05.10 — bxp-cli 0.2.2, bxp-fmt 0.2.2, bxp-gui 0.2.2

Windows-focused release. Adds an FFI subprocess bridge that fixes
several pipe-truncation and freeze symptoms on Windows; everything
else (Linux, macOS) is unchanged on the user-facing surface.

### Features

- feat(bxp-gui-bridge): introduce native FFI subprocess bridge
  (`bxp-gui-bridge.dll`) — replaces `dart:io` Process pipes on Windows
  to work around the ~8 KB pipe truncation that broke `--docs`,
  `--config`, and `--trace` calls (dart-lang/sdk#1727). Bridge is
  mandatory on Windows; Linux/macOS still use Process.start directly.
- feat(bxp-gui): stream `--trace` output through the bridge in 100-line
  batches so file-list and per-row counters update mid-run instead of
  arriving as one final chunk after child exit.
- feat(bxp-gui): opt-in NDJSON diagnostic trace
  (`BXP_DIAGNOSTIC=1`) — writes engine stderr + bridge events to a
  local file under `%APPDATA%\bxp-gui\` for Windows freeze
  investigation.
- feat(bxp-gui): pre-compile common Skia shaders via `PaintingBinding`
  warm-up — ~10 % startup latency reduction on Windows release builds.
- feat(bxp-gui): open the user config in the system default editor via
  `explorer.exe` on Windows (the only Win launcher that respects the
  default-app association reliably).
- feat(bxp-gui): upgrade Windows installer to NSIS Modern UI 2 with
  branding bitmaps regenerated from the canonical sand-80 icon.
- feat(bxp-gui): rename "BXP GUI" → "BXP" and lowercase the install
  path (`Program Files\bxp-gui\`, `/opt/bxp-gui/`,
  `~/Library/Application Support/bxp-gui/`).
- feat(bxp-gui): drop bundled Inter / Noto Sans fonts; ship Roboto
  only — single text-metric source across Linux/macOS/Windows.

### Fixes

- fix(bxp-gui): drain subprocess stdout synchronously to survive the
  Windows pipe race (early-bridge fix; bridge later replaces this
  path entirely).
- fix(bxp-gui): drop `subscription.asFuture<void>()` — yield+cancel
  instead, sidestepping a hang on subscription teardown.
- fix(bxp-gui): add idle watchdog to the streaming subprocess
  pipeline — kills the child if no stdout arrives for 10 s
  (SIGTERM → SIGKILL).
- revert(bxp-gui): drop the 5 s → 30 s `--docs` timeout band-aid; the
  bridge makes the original timeout sufficient.

### Internal

- chore(bxp-gui): reframe diagnostic-mode flags as opt-in regression
  knobs (defaults match the production GUI baseline).
- test: pin dataset fixtures to LF endings via `.gitattributes` —
  Windows checkout default would CRLF-convert and break the dataset
  diff loop in `scripts/test.sh`.
- test: split `test.sh` into per-area phases with sub-second timing
  (Console / Datasets / Desktop) and a shared section/step/summary
  helper lib.
- docs: synthesize Windows performance notes + VMware SVGA known
  issue into `docs/devel.md` and `bxp-gui/CLAUDE.md`.
- docs: refresh root + bxp-gui CLAUDE.md and README files for the new
  `bxp-gui-bridge` module.
- docs: clarify the Windows bridge subprocess transport split in
  `docs/architecture.md` (key-invariant 4) and `docs/roadmap.md`
  (cross-platform consolidation queued for v0.3.0).
- docs: align stale code comments — Roboto in
  `ExprValidationBadgeSlot`, bridge mandatory in `findBridgeLibrary`
  docstring, batch-size constant in
  `bxp-gui-bridge/src/main.zig`.
- build: simplify the release flow —
  `release-tag.sh` now derives the tag from
  `bxp-cli/build.zig.zon`, dropping the CalVer fallback that drifted
  out of sync with the manifest version. Single source of truth for
  the next release cut.
- build(bxp-gui-bridge): add to `release-changelog.sh` MANIFESTS so
  the bridge bumps in lockstep with every other module on the next
  release.
- ci(bxp-gui): subprocess fallback diagnostics +
  Windows `getDocs` retry workflow during pre-bridge investigation
  (superseded by the bridge itself; kept in history for context).
- chore(bxp-gui): freeze-investigation iteration series (iter6–iter14)
  — exploratory commits that progressively stripped Tooltip, hover
  state, hidden trailing-action buttons, and InkWell hit-testing
  from tree rows; added a live debug panel, frame timing overlay,
  and counter overlay. Root cause turned out to be VMware SVGA D3D11
  TDR + Flutter engine recovery loop (see Known issues below), not
  a tree-rendering bug.

### Known issues

- VMware Workstation SVGA D3D11 driver exhibits a 1–3 s lag on
  swap-chain reallocation when transitioning to ultra-wide
  resolutions (>1920×1200; e.g. maximize). Initial paint at the
  same target resolution is fluid — only the size-change event
  triggers it. VirtualBox SVGA and bare-metal Windows are
  unaffected. Upstream Flutter / Win32 D3D11 behaviour, not
  patchable in the runner. See
  [`docs/devel.md`](docs/devel.md#known-issues) for the full note.

## 2026.05.07 — bxp-cli 0.2.1, bxp-fmt 0.2.1, bxp-gui 0.2.1

### Bug fixes

- fix(bxp-gui): resolve sibling `bxp-cli` / `bxp-fmt` binaries via
  `path.join` and append `.exe` on Windows, so installed Windows
  builds can find the bundled companion binaries instead of failing
  startup with `bxp-fmt binary not found` and a malformed
  `C:\Program Files\BXP/bxp-fmt` search-path message.

## 2026.05.06 — bxp-cli 0.2.0, bxp-fmt 0.2.0, bxp-gui 0.2.0

### Features

- feat: bxp-fmt $err_trace annotated JSON output + json5 error recovery
- feat: bxp-fmt annotated JSON v2 — `$comm_<N>` + `$err_<N>` in-place
- feat(bxp-cli): emit output_headers in file_start trace event
- feat: add bxp-gui Flutter app, archive bxp-ui Electrobun
- feat(bxp-gui): redesign OpenDialog with sidebar, search, and Places
- feat(bxp-gui): UX polish wave (zoom persist, shared ExprEditor, status bar redesign)
- feat(bxp-gui): zoom overflow guard with 3-layer defense
- feat(bxp-gui): add FTX Terminal theme (amber on near-black)
- feat(bxp-core,bxp-fmt): emit byte-span meta tags for CST-preserving save
- feat(bxp-gui): CST-preserving save, live validation, global shortcuts
- feat(bxp-gui): fractional split panes + template selector hover
- feat(bxp): expr-fndoc single source of truth + GUI template UX + tree polish
- feat(bxp-gui): editable comments with row-by-row reorder + nested-span swap fix
- feat(bxp): row-transform UX overhaul with click-to-jump and per-token hover
- feat(bxp-gui): SettingsInspector drawer + auto-derived versions; fix CLI warning routing
- feat(pre_pass): allow multiple named pre_pass blocks per template
- feat(bxp-gui): JSON5 AST library prototype (Phase 0)
- feat(bxp-gui): JSON5 AST mutation API (Phase 1)
- feat(bxp-gui): wire AST patcher behind feature flag (Phase 2)
- feat(bxp-gui): drop CST byte-patcher (Phase 3)
- feat(bxp-gui): AST as primary loader, bxp-fmt as background validator (Phase 5a)
- feat(bxp-gui): developer.log traces for trace_store + AST patcher (Phase 5a debug)
- feat(bxp-gui): SchemaGate + Add-property dialog suggestions + comment newline gate (Phase 5b)
- feat(bxp-gui): action.* devTrace coverage for user-driven events (Phase 5g)
- feat(bxp-gui): ergonomics polish — tree edit, expr-editor, action slots, comment ops, save guard
- feat(bxp-fmt+bxp-gui): Phase 5f — canonical insert positions + insert templates
- feat(bxp-gui): Phase 5h — auto-focus into newly-inserted leaf cells
- feat(bxp-gui): Phase 5h — auto-focus expression cells via ExprPanel
- feat(bxp-core): phase 4C — deterministic pre_passes iteration order
- feat(json5_ast): phase 4D — full spec coverage for comment placement
- feat(json5_ast): phase 4E — tokenizer + dumper canonicalisation
- feat(json5_ast): phase 4F — comment-peer guards + duplicateAt trailing fix
- feat(bxp-cli): platform-aware validatePath + skip per-template error summary
- feat(bxp-cli): phase 5E — observability + safety warnings (3 items)
- feat(bxp-gui): phase 5F — 10 audit polish items + 5 manual-UX fixes
- feat(bxp-core,bxp-fmt,bxp-gui): phase A — diagnostics plumbing (no behavior change)
- feat(bxp-core,bxp-fmt): phase B — loadFromBytes per-template diagnostics
- feat(bxp-core,bxp-fmt): phase C — JSON5 syntax errors path-aware with line/col
- feat(bxp-core,bxp-fmt): phase D — wrong-type-silent warnings
- feat(bxp-core,bxp-fmt): phase E — cross-template file_pattern collision warning
- feat(bxp-core,bxp-fmt): phase F — filesystem invariants (data_dir existence)
- feat(bxp-core,bxp-fmt): phase G — expression parse-time validation with did-you-mean
- feat(bxp-core,fmt,cli,gui): unified --check-fs=N opt-in FS validation
- feat(bxp-core,fmt): phase G follow-ups G3 + G5 + G6
- feat(bxp-core,fmt): phase G follow-ups G7 + G8 (config hygiene pass)
- feat(bxp-core,fmt,gui): phase G follow-up G1 — token offset/len in diagnostics
- feat(bxp-cli): promote validateExprsCollect to fail-fast load path
- feat(bxp-cli): promote validateUnusedCollect to load path (warnings)
- feat(bxp-cli,bxp-core,bxp-fmt): promote validateUnknownKeysCollect to fail-fast load
- feat(bxp-core,bxp-fmt): G4 reopen — strict DATE_CONVERT format check (fatal)
- feat(bxp-cli,bxp-core): G2 reopen — runtime [FieldName] cross-ref (fatal)
- feat(bxp-core,bxp-fmt): G2 layer B — load-time field-name clustering
- feat(bxp-gui): VALIDATE toolbar button + Ctrl+E shortcut
- feat(bxp-core): FnDoc/FieldDoc metadata + unified static-arg checker
- feat(bxp-gui): native Dart validator + autocomplete + token underline
- feat(bxp-gui): Phase 1 — visible bxp-gui.json prefs file
- feat(bxp-gui): Phase 2 — pure-Dart auto-updater
- feat(bxp-gui): Phase 6 — sand-60 icon set + bxp-gui.desktop
- feat: Phase 7 — release-desktop.sh + Linux/Win/Mac packagers
- feat: Phase 8 — GitHub Actions release pipeline + SHA256SUMS
- feat: release-changelog.sh + release-tag.sh + scripts/README.md

### Fixes

- fix(bxp-gui): keep JsonTree array paths raw, only labels go real-only
- fix(bxp-gui): _deepEquals must compare Map keys in insertion order
- fix(bxp-gui): remove unused `_previousBlockEnd` and `_extendBlockBack` methods
- fix(bxp-gui): final traceLinesCounter sync after stream end
- fix(bxp-fmt): wrap runExpr allocator in arena to plug eval leaks
- fix(bxp-gui): op_apply trailing-comma on dup/insert of last sibling
- fix(bxp-gui): unify comment model in JSON5 AST library (Phase 4)
- fix(bxp-gui): _CommentWalker double-counted trailing on container array elements (Phase 5a)
- fix(bxp-gui): switch dev_trace to print() so MCP get_app_logs sees it
- fix(bxp-gui): unify $comm_/keys — trailing inline comment is now a peer (Phase 5e)
- fix(scripts): test.sh — replace deleted op_apply_roundtrip_test with AST round-trip
- fix(bxp-gui/json_ast_proto): array path indices use RAW positions
- fix: 5 audit findings — broker leak, errdefer, schema drift, path navigation, control-char escaping
- fix(bxp-gui): 6 audit findings — ast robustness, comment ownership, ui shortcut trap, validator hygiene
- fix(bxp-cli): 4 audit findings — diagnostics routing, date-range validation, silent expr errors
- fix(bxp-core): phase 4A — xlsx_sheet hard-fail, validate text alignment, pre_pass docs
- fix(bxp-gui): invalidate path-keyed state on AST mutation
- fix(bxp-cli): exit-code precedence — fatal must win over warnings
- fix(bxp-cli): G2 layer A — Levenshtein-gated warning, drop fatal
- fix(bxp-gui,bxp-core): Phase 5b polish from end-to-end testing
- fix(bxp-gui): close Phase 5b polish backlog
- perf(bxp-gui): kill quadratic PlutoGrid rebuild during dry-run streaming

### Internal

- chore: remove bxp-gui entry from .gitignore
- chore(bxp-gui): remove leftover test_ffi.dart scratch file
- refactor(bxp-gui): fractional splitter layout via LayoutDefaults
- refactor(bxp-gui): AST as live mutation source — Phase 5c-A
- refactor(bxp-gui): output_panel walks AST for column headers (Phase 5c-C1)
- refactor(bxp-gui): settings_inspector + view gating walk AST (Phase 5c-C2)
- refactor(bxp-gui): json_tree walks AST directly (Phase 5c-C3)
- refactor(bxp-gui): drop adapter, AST is the only state (Phase 5c-D)
- chore(bxp-core/json5): annotate annotated-output emitters as 5d-CANDIDATE
- chore(bxp-core/json5): Phase 5d — strip dead $comm_*/$meta_* emitters
- refactor(bxp-core+bxp-fmt): move --docs catalog into bxp-core, co-locate FieldDoc with config structs
- docs(CLAUDE.md): refresh module docs after docs catalog refactor + add bxp-gui guide
- chore(docs): fix CLAUDE.md markdownlint warnings
- chore(bxp-gui): drop `flutter create` placeholders (calculate(), bxp_gui.dart, bin/, placeholder test)
- test(bxp-fmt): inline annotated-config tests, drop datasets/_annotated_fixtures
- refactor(bxp-gui): move json_ast_proto → packages/json5_ast, rename + drop bin/, wire dart tests
- test(bxp-fmt): pure string-in tests via annotateRaw + config.loadFromBytes
- chore: audit follow-up phase 1 — tests, dead code, doc fixes
- chore: audit follow-up phase 2 — robustness, lifecycle, API hygiene
- chore: audit follow-up phase 3 — CLI hygiene, output safety, polish
- docs(bxp-fmt): phase 4B — clarify root-err disjoint output paths
- docs: phase 5A — audit follow-up doc-only batch (9 items)
- chore: phase 5B — internal hygiene + defensive guards (8 items)
- chore: phase 5C — services + store internals (6 items)
- chore: phase 5D — backend + library hygiene (3 items)
- docs: persist skip-rationale for bxp-core + bxp-fmt audit observations
- test: anycoin fixture now exercises live date_filter (no warnings)
- chore(scripts): silence harmless bxp-fmt test stderr leak in test.sh
- refactor(bxp-gui): drop live config validation — load/save only
- chore: Phase 3 — bxp-console package rename + resources/console/ split
- chore: Phase 4 — split release + test scripts into console / desktop
- chore(bxp-gui): Phase 5 — bxp-gui binary + io.github.bxp.gui app ID
- docs: Phase 9 + 10 — test-desktop.sh + CLAUDE.md / docs refresh
- chore: rename scripts to NN-prefixed step ordering
- docs: add CHANGELOG.md with historical v0.1.0 / v0.1.1 stubs
- docs: bootstrap docs/roadmap.md from session memory

### Other

- feat: add CSV out-of-range row filtering as a dataset showcase
- chore: refresh `bxp-cli.examples.json` with updated sample data
- chore: archive bxp-ui (Electrobun) and bxp-gui (DVUI/SDL3) prototypes
  in favour of the Flutter rewrite

## v0.1.1 — 2026-04-15

Re-tag of v0.1.0 with no code changes.

## v0.1.0 — 2026-04-15

Initial public release of `bxp-cli`, the broker CSV → Wealthfolio
conversion engine. Shipped as
`bxp-cli-v0.1.0-{linux-x86_64.tar.gz, windows-x86_64.zip, macos-aarch64.tar.gz}`
under the pre-split `releases/` directory layout (before
`bxp-fmt` and `bxp-gui` were extracted).

Supported brokers: Anycoin, Revolut X, Trading 212, XTB (xtb1 + xtb2
formats).
