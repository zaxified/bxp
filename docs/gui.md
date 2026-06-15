# BXP - GUI Developer Guide

> [← docs/](README.md)

Flutter desktop app (`bxp-gui`) that provides a visual config editor, dry-run
debugger, and expression playground on top of the `bxp-cli` conversion
pair. Runs on Linux, macOS, and Windows.

---

## Table of Contents

- [Why Flutter / Dart](#why-flutter--dart)
- [Getting started](#getting-started)
- [Development workflow](#development-workflow)
- [Architecture overview](#architecture-overview)
- [Source layout](#source-layout)
- [Subprocess wiring](#subprocess-wiring)
- [json5_ast library](#json5_ast-library)
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
  `Stream<List<int>>` that maps directly onto the BXTB frame reader (and the
  NDJSON line splitter used by `--expr-trace`). No IPC bridge or marshaling
  layer — the stream is the protocol.
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
the bxp-gui-bridge FFI. Dart's role is: marshal to/from the bridge, maintain UI
state, render widgets. This boundary keeps the Dart codebase thin, testable,
and decoupled from the Zig internals.

---

## Getting started

### Prerequisites

| Tool        | Version | Notes                                                                                                                             |
| ----------- | ------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Flutter SDK | ≥ 3.x   | See `bxp-gui/pubspec.yaml` `environment.flutter` for the minimum. Install from [flutter.dev](https://flutter.dev) or via `fvm`.   |
| Dart SDK    | bundled | Ships with Flutter; no separate install.                                                                                          |
| Zig         | 0.15.2  | To build bxp-cli, bxp-mcp, and the bxp-gui-bridge library. See [devel.md](devel.md) for the pinned version.                       |
| VS Code     | any     | + [Flutter extension](https://marketplace.visualstudio.com/items?itemName=Dart-Code.flutter). IntelliJ / Android Studio work too. |

### First run

```bash
# 1. Build the backend binaries (required before flutter run)
cd bxp-cli && zig build
cd ../bxp-gui-bridge && zig build

# 2. Install Dart/Flutter dependencies
cd ../bxp-gui && flutter pub get

# 3. Run on your host platform
flutter run -d linux    # Linux
flutter run -d macos    # macOS
flutter run -d windows  # Windows (PowerShell)
```

The dev-tree binary fallback in `findBin()` walks up from the Flutter
executable until it finds the `bxp-gui/` segment, then resolves
`../bxp-cli/zig-out/bin/bxp-cli` and the `bxp-gui-bridge` library
automatically. No environment variables needed for local dev.

### Verify the install

On first launch the app loads the language catalog in-process from the bridge.
If the `bxp-gui-bridge` library is missing or unbuilt a fatal error gate
appears — build it first. Then:

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
# Terminal 1 — rebuild after editing bxp-cli or bxp-gui-bridge source
cd bxp-cli && zig build   # or bxp-gui-bridge

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

# json5_ast unit tests (~105 cases + round-trip suite)
dart test packages/json5_ast/

# Full desktop suite: flutter analyze + flutter test + dart test
bash scripts/test-04-desktop.sh
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
        ↕  Two transport paths (see "Subprocess wiring" below)
        │      Process.start / Process.run      (Linux / macOS default)
        │      bxp-gui-bridge.{dll,so,dylib}    (Win mandatory; eval cross-plat)
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
│   │   ├── bxp_process_client.dart           # Subprocess wrapper — bridge on Win, Process.start elsewhere
│   │   ├── csv_row_fetcher.dart              # Random-access source/output row fetch by byte offset
│   │   ├── dart_validator.dart               # Dart-side per-edit expression validator
│   │   ├── debug_binding.dart                # WidgetsFlutterBinding hook for diagnostic capture
│   │   ├── debug_settings.dart               # Opt-in regression knobs (paint, hover, scroll filters)
│   │   ├── desktop_integration_service.dart  # First-run .desktop + hicolor icon writer (Linux AppImage)
│   │   ├── dev_trace.dart                    # kDebugMode-gated print() helper
│   │   ├── diagnostic_log.dart               # Opt-in NDJSON trace + engine stderr capture
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
├── test/                           # Widget + service tests (desktop_integration,
│                                   # expr_corpus_bridge, prefs_service, zoom_overflow)
└── pubspec.yaml
```

---

## Subprocess wiring

`BxpProcessClient` is the single entry point for all binary calls. Under the
hood there are two transports — out-of-process (`dart:io` Process.start) and
in-process FFI (`bxp-gui-bridge.{dll,so,dylib}`). `BxpProcessClient` picks
between them per call based on host OS and what the call needs.

### Transport paths

Since the v0.3.0 proxy flip the bridge is the **single backend on every
platform** — there is no `Process.start` path. All five entry points are
`bridge_*` calls:

| Transport                   | Used for                                                                              |
| --------------------------- | ------------------------------------------------------------------------------------- |
| `bridge_inspect`            | Stateless ops in-process: config validation, docs, list/fetch templates, eval-batch   |
| `bridge_eval_expr`          | expr editor live validation per keystroke (in-process) — avoids a ~50 ms spawn cost   |
| `bridge_eval_expr_trace`    | ExprPlayground per-call NDJSON (in-process), plus per-token trace stream               |
| `bridge_run_streaming`      | `bxp-cli --trace` dry-run / full-run — native pipe drain sidesteps dart-lang/sdk#1727  |
| `bridge_run`                | one-shot `bxp-cli --version` — same pipe-truncation workaround                         |

The bridge is implemented as a Zig shared library that links the
`bxp-core/inspect` + `expr` modules directly (in-proc paths) and spawns the
`bxp-cli` subprocess (proxy paths). For the **two-cause rationale** behind the in-proc / proxy split see
[`devel.md`'s "Why the bridge exists"](devel.md#why-the-bridge-exists)
section. The C-ABI surface and Debug→ReleaseSafe rewrite landmine live in
[`bxp-gui-bridge/CLAUDE.md`](../bxp-gui-bridge/CLAUDE.md).

**Mandatory on every platform.** Library probe failure at startup is fatal
(synthetic error surfaced through the normal startup gate, which also parses
the docs catalog). There is no subprocess fallback — Windows can't use
`Process.start` (dart-lang/sdk#1727) and the v0.3.0 flip deleted the
Linux/macOS `Process.start` route too.

**Reloading bridge changes.** `dlopen` mmaps the file at process start, so
editing a `.so`/`.dylib` and `mcp__dart__hot_reload` does NOT pick it up. After
`zig build` in `bxp-gui-bridge/`, fully stop and relaunch the Flutter app.

### Binary resolution

Resolved in this order:

1. **Env override** — `$BXP_CLI_PATH`. If set and non-empty,
   used absolutely (missing file → fatal error, no fallthrough).
2. **Bundle sibling** — `<name>` next to the Flutter executable inside the app
   bundle.
3. **Dev-tree fallback** — walks up from the exe dir until it finds a `bxp-gui/`
   segment, then looks for `<monorepo-root>/<name>/zig-out/bin/<name>`. This
   makes `flutter run -d linux` work without copying binaries after a bundle wipe.

### Client methods

| Method                  | Binary                                    | Notes                                                   |
| ----------------------- | ----------------------------------------- | ------------------------------------------------------- |
| `validateConfig(path)`  | `bridge_inspect {config}`                 | Returns annotated JSON with `$err_*`/`$warn_*` siblings |
| `getDocs()`             | `bridge_inspect {docs}`                   | Cached at startup; drives FnDoc tooltips + SchemaGate   |
| `listTemplates(path)`   | `bridge_inspect {list_templates}`         | Template id array                                       |
| `validateExpr(text)`    | `bridge_eval_expr`                        | Returns `{error, offset, length}` on failure            |
| `traceExpr(text, …)`    | `bridge_eval_expr_trace`                  | NDJSON stream of per-call values                        |
| `runDryRun(path, tmpl)` | `bxp-cli --trace`                         | BXTB frame stream → in-store reader                     |
| `getVersion(name)`      | `bridge_run` → `bxp-cli --version`        | Writes to stdout                                        |

### Linux dev-tree gotcha

The Linux CMake config copies the `bxp-gui-bridge` library (and `bxp-cli`) into
the bundle at build time. After rebuilding the bridge, either run a clean Flutter
build or rely on the dev-tree fallback (option 3 above) which reads directly from
`bxp-gui-bridge/zig-out/`.

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
> [`bxp-gui/packages/json5_ast/CLAUDE.md`](../bxp-gui/packages/json5_ast/CLAUDE.md)
> for the extraction recipe.

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
- **Schema docs** — `FnDoc` / `FieldDoc` catalog loaded from the bridge docs op.
- **Validation errors** — `$err_*` / `$warn_*` map from the last config-validation run.

Edits flow back as `ConfigOp`s:

```text
UI widget  →  ConfigOp  →  op_log  →  op_to_ast  →  ast_patch_client  →  disk
```

Save runs config validation (`bridge_inspect {config}`) for a validation pass; results refresh the
error map and the tree highlight state.

---

## Key patterns

### Streaming rebuild storm — never call notifyListeners per trace frame

Calling top-level `notifyListeners()` per BXTB frame causes PlutoGrid to
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
misses shortcuts while e.g. PlutoGrid has focus. The command modifier is
resolved per-host by `isCommandModifierPressed()` in
`ui/platform_shortcuts.dart` — `Cmd` (Meta) on macOS, `Ctrl` elsewhere —
so bindings follow host convention and don't clash with macOS
`Ctrl+Up`/`Ctrl+Down`.

### Load-time vs mid-edit error gating

Load-time errors disable the readonly toolbar (`_loadedWithErrors`). Mid-edit
errors do not lock undo/redo — validation only runs on load and save, not
on every keystroke.

### Schema docs as single source of truth

The docs catalog is loaded at startup (from the bridge) and drives FnDoc tooltips,
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
   config-validation diagnostics).
3. **GUI** — rebuild the bridge and restart bxp-gui; the field appears in the
   tree editor's `_AddChildDialog` insert scaffold and tooltip automatically
   via `SchemaGate` + `FnDoc`/`FieldDoc`.
4. **Tests** — add a dataset fixture if the field affects output; add a
   bxp-mcp smoke test (test-05) if it adds a new validation path.

---

## Deeper reference

This guide covers structure, dev workflow, and the patterns a new contributor
needs to ship a first change. Internal-API contracts and design-decision
rationales live in:

- [`bxp-gui/CLAUDE.md`](../bxp-gui/CLAUDE.md) — Flutter side: services /
  store / ui split, BxpProcessClient binary resolution, prefs path policy,
  auto-updater install paths, MCP debug workflow, conventions enforced.
- [`bxp-gui/packages/json5_ast/CLAUDE.md`](../bxp-gui/packages/json5_ast/CLAUDE.md) —
  json5_ast public API, comment-ownership rules, round-trip / idempotent
  canonicalisation contract, future extraction recipe.
