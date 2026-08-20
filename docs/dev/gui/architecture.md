---
description: "The services / store / ui split inside the Flutter app, and what owns which piece of state."
---

# Architecture

## Overview

Three layers, top-down:

```text
┌───────────────────────────────────────────────┐
│  ui/   (Provider widgets, no business logic)  │
│  ConfigOps flow down; notifyListeners up       │
├───────────────────────────────────────────────┤
│  store/   TraceStore ChangeNotifier            │
│  Single source of truth for all UI state      │
├───────────────────────────────────────────────┤
│  services/   Pure Dart, no Flutter imports    │
│  Subprocess wrappers, AST loader, prefs, ...  │
└───────────────────────────────────────────────┘
        ↕  Single backend: bxp-gui-bridge (see "Subprocess wiring" below)
        │      bxp-gui-bridge.{dll,so,dylib}    (single backend, all platforms)
        ↓
  bxp-cli  (conversions via --trace BXTB frame stream, proxied by the bridge)
  bxp-core (inspect.zig + expr.zig linked directly into the bridge — in-process
           validation / docs / expr eval / config annotation)
```

The Flutter app never parses JSON5 directly for runtime data — all backend
operations go through the bxp-gui-bridge (in-process inspect + proxied bxp-cli runs).
The Dart `json5_ast` library is used only for in-place AST mutations of
the user's config file (parse → mutate → dump back preserving comments).

---

## Source layout

```text
bxp-gui/
├── lib/
│   ├── main.dart                    # Flutter entry: window sizing, theme, Provider wiring
│   ├── services/
│   │   ├── app_runtime.dart                  # Top-level lifecycle helpers + startup gate
│   │   ├── ast_loader.dart                   # Parse user config to JsonAstNode tree
│   │   ├── ast_patch_client.dart             # Apply AST mutations + dump back to disk
│   │   ├── bridge_client.dart                # Dart FFI shim for bxp-gui-bridge (DLL on Win,
│   │   │                                     # .so/.dylib on Linux/macOS for bridge_eval_expr)
│   │   ├── btrace.dart                       # Dart-side BXTB binary-trace parser (mirrors btrace.zig)
│   │   ├── bxp_process_client.dart           # Backend client — all calls via bxp-gui-bridge (no Process.start)
│   │   ├── csv_row_fetcher.dart              # Random-access source/output row fetch by byte offset
│   │   ├── dart_validator.dart               # Dart-side per-edit expression validator
│   │   ├── debug_binding.dart                # WidgetsFlutterBinding hook for diagnostic capture
│   │   ├── debug_settings.dart               # Opt-in regression knobs (paint, hover, scroll filters)
│   │   ├── desktop_integration_service.dart  # First-run .desktop + hicolor icon writer (Linux AppImage)
│   │   ├── dev_trace.dart                    # kDebugMode-gated print() helper
│   │   ├── diagnostic_log.dart               # Opt-in NDJSON trace + engine stderr capture
│   │   ├── gui_mcp_server.dart               # Embedded gui-mcp server (localhost HTTP)
│   │   ├── op_log.dart                       # In-memory record of user edits since load
│   │   ├── op_to_ast.dart                    # Translate ConfigOp → AST mutation calls
│   │   ├── prefs_service.dart                # User preferences persistence (visible JSON file)
│   │   ├── schema_doc_lookup.dart            # Resolve a config-tree path against the FieldDoc catalog
│   │   ├── schema_gate.dart                  # Schema-aware "may the user do X here?"
│   │   └── updater_service.dart              # GitHub release poller + download/verify/install
│   ├── store/
│   │   ├── trace_store.dart         # Central ChangeNotifier (~4.1k lines, BXTB ingest inline)
│   │   └── trace_model.dart         # Plain-Dart shapes for trace frame payloads
│   └── ui/
│       ├── main_view.dart           # 3-pane layout root
│       ├── config_view.dart         # JSON5 tree editor pane
│       ├── debug_overlay.dart       # Floating debug counter overlay (BXP_DIAGNOSTIC)
│       ├── debug_panes.dart         # Trace/output bottom panes
│       ├── settings_inspector.dart  # Ctrl+Shift+S internal-state drawer
│       ├── layout_defaults.dart     # Fractional split sizes (single source)
│       ├── platform_shortcuts.dart  # Command-modifier helper (Cmd on macOS, Ctrl elsewhere)
│       ├── shader_warmup.dart       # Skia shader pre-warmup (Windows perf)
│       ├── zoom_limits.dart         # Window / zoom guards
│       ├── theme/                   # App theme (bxp_theme, bxp_text, bxp_text_scheme,
│       │                            # bxp_theme_animator, theme_inspector)
│       └── components/
│           ├── json_tree.dart         # Recursive tree renderer with insert/edit slots
│           ├── expr_editor.dart       # Expression input with autocomplete
│           ├── expr_panel.dart        # Right-rail expression preview
│           ├── expr_playground.dart   # Standalone expression sandbox
│           ├── expr_highlight.dart    # Token-aware syntax highlighter
│           ├── row_detail.dart        # Per-row variable/rule trace detail
│           ├── row_list.dart          # Master row picker
│           ├── file_list.dart         # Multi-file dry-run output list
│           ├── output_panel.dart      # bxp-cli stdout/stderr viewer
│           ├── top_bar.dart           # Title bar + actions
│           ├── panel_header.dart      # Reusable header chrome
│           ├── resize_handle.dart     # Splitter drag handle
│           ├── open_dialog.dart       # Recent-files / file picker
│           ├── integrate_dialog.dart  # First-run Linux desktop-integration prompt
│           └── update_dialog.dart     # In-app updater prompt
├── packages/json5_ast/             # Dart JSON5 AST library (path dep)
│   ├── lib/
│   │   ├── json5_ast.dart          # Top-level umbrella export
│   │   ├── ast.dart                # JsonAstNode hierarchy + public API
│   │   ├── parser.dart             # JSON5 → AST
│   │   ├── dumper.dart             # AST → JSON5 text
│   │   ├── operations.dart         # Insert / delete / move / set mutations
│   │   ├── path.dart               # Dot-path resolver
│   │   ├── value_builder.dart      # Typed value constructors
│   │   └── src/
│   │       └── tokenizer.dart      # JSON5 tokenizer (private)
│   └── test/                       # ~105 unit tests + round-trip suite
├── linux/, macos/, windows/, web/  # Per-platform Flutter shells
├── test/                           # Widget + service tests — bridge FFI surface
│                                   # (bridge_inspect, bridge_verify_minisign,
│                                   # expr_corpus_bridge, expr_batch), BXTB wire
│                                   # contract, gui_mcp_server over real HTTP,
│                                   # save_guard, prefs_service, zoom_overflow, …
└── pubspec.yaml
```

---

## State management

`TraceStore` (`store/trace_store.dart`) is the single `ChangeNotifier` driving
every pane:

- **Loaded config** — as both a `JsonAstNode` tree (for editing) and a
  `Map<String, dynamic>` view (for schema lookups).
- **Dry-run trace** — per-file and per-row trace data from `bxp-cli --trace`.
- **Op log** — undo/redo stack of `ConfigOp` entries.
- **Schema docs** — `FnDoc` / `FieldDoc` catalog loaded from the bridge docs op.
- **Validation errors** — `$err_*` / `$warn_*` map from the last config-validation run.

Edits flow back as `ConfigOp`s:

```text
UI widget  →  ConfigOp  →  op_log  →  op_to_ast  →  ast_patch_client  →  disk
```

Save runs config validation (`bridge_inspect {config}`) for a validation pass; results refresh the
error map and the tree highlight state.

---

## json5_ast library

A standalone Dart package (`packages/json5_ast/`) that parses JSON5 to a
comment-preserving AST, applies mutations, and dumps back to text. Used to
edit the user's `bxp-cli.json` without reformatting comments or key order.

> **Standalone-library candidate.** `json5_ast` has no bxp-specific concepts —
> no `BrokerConfig`, no `FieldDoc`, nothing from the bxp domain. It lives
> inside the monorepo only because no second Dart consumer exists yet. When
> contributing here, prefer full JSON5 spec compliance over bxp-convenience
> shortcuts so future extraction stays cheap. See
> [`bxp-gui/packages/json5_ast/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-gui/packages/json5_ast/CLAUDE.md)
> for the extraction recipe.

### Parser depth guard

`parse` is recursive-descent, so a deeply nested config could blow the Dart
stack. `parser.dart` caps value nesting at `_kMaxDepth` (64) and bails with a
caught parse error instead of an uncatchable `StackOverflowError` — the loader
shows a clean diagnostic rather than crashing. `value_builder.dart` mirrors the
same limit on the build side.

### Mutation model

```text
parse  →  JsonAstNode tree  →  apply ops  →  dump  →  file
```

Operations (`operations.dart`): `insertChild`, `deleteChild`, `moveChild`,
`setValue`, `duplicateChild`. Each operates on a dot-path into the tree.

`op_to_ast.dart` translates high-level `ConfigOp` (the type stored in the
undo ledger) to concrete AST mutations. `ast_patch_client.dart` runs the
mutations and writes the result to disk.

### Round-trip identity

Verified by `packages/json5_ast/test/round_trip_test.dart` (run by both
`test-01-console.sh` and `test-04-desktop.sh`). The contract is **idempotent
canonicalisation**, not byte identity: the first dump may reformat the input,
but every subsequent parse → dump cycle must produce the same bytes. The older
`AST round-trip` phase in `scripts/test.sh` was retired because it read a
gitignored `DEV/bxp-cli.json` and so only worked on one machine.
