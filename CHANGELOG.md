# Changelog

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
