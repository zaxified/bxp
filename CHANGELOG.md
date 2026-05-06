# Changelog

## 2026.05.06 — bxp-cli 0.2.0, bxp-fmt 0.2.0, bxp-gui 0.2.0

### Features

- feat: bxp-fmt $err_trace annotated JSON output + json5 error recovery
- feat: bxp-fmt annotated JSON v2 — $comm_<N> + $err_<N> in-place
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
- fix(bxp-gui): remove unused _previousBlockEnd and _extendBlockBack methods
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

- new icon test
- archive: move bxp-gui (DVUI/SDL3) out of monorepo
- bxp-ui: RUNNER tab, full-run button, keyboard shortcuts, save improvements
- bxp-ui: tab state persistence, F11 fullscreen, release inspect block
- bxp-ui: resizable panels via drag handles
- mv bxp.code-workspace .git/COMMIT_EDITMSG
- mv bxp.code-workspace bxp.code-workspace.bak
- mv bxp.code-workspace bxp.code-workspace.bak
- mv bxp.code-workspace bxp.code-workspace.bak
- new dev run environment shell script
- perf(bxp-gui): kill quadratic PlutoGrid rebuild during dry-run streaming
- new version of the CLI examples file, with updated sample data for the datasets.
- csv lines out of range added as showcase of filtration


All notable changes to BXP. New entries are prepended at the top by
`scripts/release-changelog.sh`; pre-existing release tags below are
hand-stubbed since they pre-date the automation.

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
