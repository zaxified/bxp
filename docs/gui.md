# BXP - GUI Developer Guide

> [← docs/](README.md)

Flutter desktop app (`bxp-gui`) that provides a visual config editor, dry-run
debugger, and expression playground on top of the `bxp-cli` / `bxp-fmt` CLI
pair. Runs on Linux, macOS, and Windows.

---

## Table of Contents

- [Why Flutter / Dart](#why-flutter--dart)
- [Getting started](#getting-started)
- [Development workflow](#development-workflow)
- [Architecture overview](#architecture-overview)
- [Source layout](#source-layout)
- [Subprocess wiring](#subprocess-wiring)
- [json5\_ast library](#json5_ast-library)
- [State management](#state-management)
- [Key patterns](#key-patterns)
- [Adding a new config field to the UI](#adding-a-new-config-field-to-the-ui)

---

## Why Flutter / Dart

bxp-gui replaced an earlier Electrobun + React + CodeMirror 6 frontend
(bxp-ui, shipped as v0.1.0). The switch to Flutter was driven by:

- **Cross-platform single binary.** Flutter desktop compiles to a
  self-contained executable with no webview runtime dependency. The same
  Dart source builds on Linux, macOS, and Windows from one codebase.
- **Subprocess streaming fits naturally.** `Process.start()` returns a stdout
  `Stream<List<int>>` that maps directly onto the NDJSON event model. No IPC
  bridge or marshaling layer — the stream is the protocol.
- **Hot reload.** Flutter hot-reloads UI and state-logic changes in ~1 s
  without losing app state. Zig backend changes still require a process
  restart, but Dart-only iterations are immediate.
- **Sound null-safety.** Dart's type system catches whole classes of runtime
  errors that were silent in the JS frontend. The `trace_model.dart` event
  mirrors are typed exhaustively.
- **Rich table widgets.** PlutoGrid provides a spreadsheet-like trace view
  for the dry-run debugger — reproducing it in a webview would have required
  a heavy JS dependency.

The app never calls bxp-core directly. All heavy logic stays in bxp-cli /
bxp-fmt subprocesses. Dart's role is: parse subprocess stdout, maintain UI
state, render widgets. This boundary keeps the Dart codebase thin, testable,
and decoupled from the Zig internals.

---

## Getting started

### Prerequisites

| Tool | Version | Notes |
| --- | --- | --- |
| Flutter SDK | ≥ 3.x | See `bxp-gui/pubspec.yaml` `environment.flutter` for the minimum. Install from [flutter.dev](https://flutter.dev) or via `fvm`. |
| Dart SDK | bundled | Ships with Flutter; no separate install. |
| Zig | 0.15.2 | To build bxp-cli and bxp-fmt. See [devel.md](devel.md) for the pinned version. |
| VS Code | any | + [Flutter extension](https://marketplace.visualstudio.com/items?itemName=Dart-Code.flutter). IntelliJ / Android Studio work too. |

### First run

```bash
# 1. Build the backend binaries (required before flutter run)
cd bxp-cli && zig build
cd ../bxp-fmt && zig build

# 2. Install Dart/Flutter dependencies
cd ../bxp-gui && flutter pub get

# 3. Run on your host platform
flutter run -d linux    # Linux
flutter run -d macos    # macOS
flutter run -d windows  # Windows (PowerShell)
```

The dev-tree binary fallback in `findBin()` walks up from the Flutter
executable until it finds the `bxp-gui/` segment, then resolves
`../bxp-cli/zig-out/bin/bxp-cli` and `../bxp-fmt/zig-out/bin/bxp-fmt`
automatically. No environment variables needed for local dev.

### Verify the install

On first launch the app probes `bxp-fmt --docs` to load the language catalog.
If bxp-fmt is missing or unbuilt a fatal error gate appears — build bxp-fmt
first. Then:

1. Open `DEV/bxp-cli.json` (the developer reference config) via the
   file-picker or drag-drop.
2. Select a template in the toolbar dropdown.
3. Click **Run** — the dry-run trace should populate the bottom panel.
4. Click any row to see per-variable and per-rule results.
5. Click any expression cell — the ExprPanel on the right shows a live
   evaluation playground.

---

## Development workflow

### Dart changes — hot reload

```bash
# Keep this terminal open while editing Dart
cd bxp-gui
flutter run -d linux

# r   — hot reload  (preserves app state, picks up most Dart changes)
# R   — hot restart (full Dart restart, clears state)
# q   — quit
```

VS Code users: the Flutter extension auto-hot-reloads on save when
"Hot reload on save" is enabled in settings. F5 launches with a full debugger
(breakpoints, variable inspector).

### Zig changes — rebuild + restart

Zig binaries are subprocesses; Flutter does not hot-reload them.

```bash
# Terminal 1 — rebuild after editing bxp-fmt or bxp-cli source
cd bxp-fmt && zig build   # or bxp-cli

# Terminal 2 — hot-restart the Flutter app to pick up the new binary
# Press Shift+R in the flutter run terminal, or quit and re-run
```

### Debugging with print()

`dev_trace.dart` provides `devTrace(tag, message)` — a `kDebugMode`-gated
`print('[bxp_gui] $tag: $message')` helper.

- Use the `[bxp_gui]` prefix so MCP `get_app_logs` can filter output.
- Use `print()`, **not** `developer.log()` — MCP `get_app_logs` captures
  stdout only; `developer.log()` is invisible to it.
- Gate all debug prints behind `kDebugMode` so release builds stay clean.

MCP live-debug cycle (when working with Claude Code):

```bash
# 1. Launch via MCP (root must be a plain path, not file://)
mcp__dart__launch_app(root: "/home/user/workspace/bxp/bxp-gui")

# 2. Edit → hot reload
mcp__dart__hot_reload()

# 3. Read recent print() output
mcp__dart__get_app_logs()
```

### Running tests

```bash
# Widget + unit tests (bxp-gui)
flutter test

# json5_ast unit tests (69 cases + round-trip suite)
dart test packages/json5_ast/

# Full desktop suite: flutter analyze + flutter test + dart test
bash scripts/test-02-desktop.sh
```

`flutter analyze` enforces sound null-safety and catches common issues. Run it
before committing — CI runs it on every release build.

---

## Architecture overview

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
        ↕  subprocess (Process.run / Process.start)
  bxp-cli  (conversions via --trace NDJSON stream)
  bxp-fmt  (validation, docs, expr eval)
```

The Flutter app never parses JSON5 directly for runtime data — all backend
operations go through bxp-cli or bxp-fmt as short-lived subprocesses.
The Dart `json5_ast` library is used only for in-place AST mutations of
the user's config file (parse → mutate → dump back preserving comments).

---

## Source layout

```text
bxp-gui/
├── lib/
│   ├── main.dart                    # Flutter entry: window sizing, theme, Provider wiring
│   ├── services/
│   │   ├── bxp_process_client.dart  # Process.run wrappers for bxp-cli / bxp-fmt
│   │   ├── ast_loader.dart          # Parse user config to JsonAstNode tree
│   │   ├── ast_patch_client.dart    # Apply AST mutations + dump back to disk
│   │   ├── op_log.dart              # In-memory undo/redo ledger of ConfigOps
│   │   ├── op_to_ast.dart           # Translate ConfigOp → AST mutation calls
│   │   ├── schema_gate.dart         # Schema-aware "may the user do X here?"
│   │   ├── dart_validator.dart      # Dart-side per-edit expression validator
│   │   ├── prefs_service.dart       # User preferences persistence (visible JSON file)
│   │   ├── updater_service.dart     # GitHub release poller + download/verify/install
│   │   └── dev_trace.dart           # kDebugMode-gated print() helper
│   ├── store/
│   │   ├── trace_store.dart         # Central ChangeNotifier (~2k lines)
│   │   ├── trace_builder.dart       # Fold NDJSON trace events into TraceStore
│   │   └── trace_model.dart         # Plain-Dart shapes for trace events
│   └── ui/
│       ├── main_view.dart           # 3-pane layout root
│       ├── config_view.dart         # JSON5 tree editor pane
│       ├── debug_panes.dart         # Trace/output bottom panes
│       ├── settings_inspector.dart  # Ctrl+Shift+S internal-state drawer
│       ├── layout_defaults.dart     # Fractional split sizes (single source)
│       ├── zoom_limits.dart         # Window / zoom guards
│       ├── theme/                   # App theme (bxp_theme.dart, bxp_text.dart, …)
│       └── components/
│           ├── json_tree.dart       # Recursive tree renderer with insert/edit slots
│           ├── expr_editor.dart     # Expression input with autocomplete
│           ├── expr_panel.dart      # Right-rail expression preview
│           ├── expr_playground.dart # Standalone expression sandbox
│           ├── expr_highlight.dart  # Token-aware syntax highlighter
│           ├── row_detail.dart      # Per-row variable/rule trace detail
│           ├── row_list.dart        # Master row picker
│           ├── file_list.dart       # Multi-file dry-run output list
│           ├── output_panel.dart    # bxp-cli stdout/stderr viewer
│           ├── top_bar.dart         # Title bar + actions
│           ├── panel_header.dart    # Reusable header chrome
│           ├── resize_handle.dart   # Splitter drag handle
│           ├── open_dialog.dart     # Recent-files / file picker
│           └── update_dialog.dart   # In-app updater prompt
├── packages/json5_ast/             # Dart JSON5 AST library (path dep)
│   ├── lib/
│   │   ├── ast.dart                # JsonAstNode hierarchy + public API
│   │   └── src/
│   │       ├── parser.dart         # JSON5 → AST
│   │       ├── tokenizer.dart      # JSON5 tokenizer
│   │       ├── dumper.dart         # AST → JSON5 text
│   │       ├── operations.dart     # Insert / delete / move / set mutations
│   │       ├── path.dart           # Dot-path resolver
│   │       └── value_builder.dart  # Typed value constructors
│   └── test/                       # ~69 unit tests + round-trip suite
├── linux/, macos/, windows/, web/  # Per-platform Flutter shells
├── test/                           # Widget tests
└── pubspec.yaml
```

---

## Subprocess wiring

`BxpProcessClient` is the single entry point for all binary calls.

### Binary resolution

Resolved in this order:

1. **Env override** — `$BXP_CLI_PATH` / `$BXP_FMT_PATH`. If set and non-empty,
   used absolutely (missing file → fatal error, no fallthrough).
2. **Bundle sibling** — `<name>` next to the Flutter executable inside the app
   bundle.
3. **Dev-tree fallback** — walks up from the exe dir until it finds a `bxp-gui/`
   segment, then looks for `<monorepo-root>/<name>/zig-out/bin/<name>`. This
   makes `flutter run -d linux` work without copying binaries after a bundle wipe.

### Client methods

| Method | Binary | Notes |
| -- | -- | -- |
| `validateConfig(path)` | `bxp-fmt --config` | Returns annotated JSON with `$err_*`/`$warn_*` siblings |
| `getDocs()` | `bxp-fmt --docs` | Cached at startup; drives FnDoc tooltips + SchemaGate |
| `listTemplates(path)` | `bxp-fmt --config … --list-templates` | Template id array |
| `validateExpr(text)` | `bxp-fmt --expr` | Returns `{error, offset, length}` on failure |
| `traceExpr(text, …)` | `bxp-fmt --expr-trace` | NDJSON stream of per-call values |
| `runDryRun(path, tmpl)` | `bxp-cli --trace` | NDJSON stream → `trace_builder.dart` |
| `getVersion(name)` | `bxp-cli --version` / `bxp-fmt --version` | Both write to stdout |

### Linux dev-tree gotcha

The Linux CMake config copies `bxp-fmt` into the bundle at build time. After
changing bxp-fmt, either run a clean Flutter build or rely on the dev-tree
fallback (option 3 above) which reads directly from `bxp-fmt/zig-out/bin/`.

---

## json5\_ast library

A standalone Dart package (`packages/json5_ast/`) that parses JSON5 to a
comment-preserving AST, applies mutations, and dumps back to text. Used to
edit the user's `bxp-cli.json` without reformatting comments or key order.

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

Verified by `scripts/test.sh`'s "AST round-trip" phase against
`DEV/bxp-cli.json`. The dumper produces deterministic output; first-save
canonicalizes formatting.

---

## State management

`TraceStore` (`store/trace_store.dart`) is the single `ChangeNotifier` driving
every pane:

- **Loaded config** — as both a `JsonAstNode` tree (for editing) and a
  `Map<String, dynamic>` view (for schema lookups).
- **Dry-run trace** — per-file and per-row trace data from `bxp-cli --trace`.
- **Op log** — undo/redo stack of `ConfigOp` entries.
- **Schema docs** — `FnDoc` / `FieldDoc` catalog loaded from `bxp-fmt --docs`.
- **Validation errors** — `$err_*` / `$warn_*` map from the last bxp-fmt run.

Edits flow back as `ConfigOp`s:

```text
UI widget  →  ConfigOp  →  op_log  →  op_to_ast  →  ast_patch_client  →  disk
```

Save runs `bxp-fmt --config` for a validation pass; results refresh the
error map and the tree highlight state.

---

## Key patterns

### Streaming rebuild storm — never call notifyListeners per trace event

Calling top-level `notifyListeners()` per NDJSON event causes PlutoGrid to
reallocate quadratically. Use per-cell `ValueNotifier` instead
(`traceLinesCounter`, `fileGen`, …). Top-level `notifyListeners()` fires
at most twice per dry-run stream (start + done).

### Fractional splitters

All resizable panels hold **fractions**, not pixels.
`lib/ui/layout_defaults.dart` is the single source of truth.
3-pane layout = 2 fractions + middle by subtraction.

### Global keyboard shortcuts

Use `HardwareKeyboard.instance.addHandler` in `initState`, not
`CallbackShortcuts` — the latter only fires when focus bubbles up, which
misses shortcuts while e.g. PlutoGrid has focus.

### Load-time vs mid-edit error gating

Load-time errors disable the readonly toolbar (`_loadedWithErrors`). Mid-edit
errors do not lock undo/redo — validation only runs on load and save, not
on every keystroke.

### Schema docs as single source of truth

`bxp-fmt --docs` is loaded at startup and drives FnDoc tooltips,
`SchemaGate` insert-position logic, autocomplete, and the
`_AddChildDialog` insert scaffolds. Do not reintroduce hardcoded fallback
catalogs — the startup gate fails fatally if the binary is missing.

---

## Adding a new config field to the UI

1. **Zig side** — add the field to the relevant struct in
   `bxp-core/src/config.zig` with a co-located `FieldDoc` entry (follow
   the existing `pub const fields = [_]FieldDoc{…}` pattern on each struct).
   `docs.zig` picks it up automatically.
2. **Validation** — if the field needs semantic checks, add them to
   `BrokerConfig.validate()` or the `validateCollect` path (for
   bxp-fmt diagnostics).
3. **GUI** — rebuild bxp-fmt and restart bxp-gui; the field appears in the
   tree editor's `_AddChildDialog` insert scaffold and tooltip automatically
   via `SchemaGate` + `FnDoc`/`FieldDoc`.
4. **Tests** — add a dataset fixture if the field affects output; add a
   bxp-fmt smoke test if it adds a new validation path.
