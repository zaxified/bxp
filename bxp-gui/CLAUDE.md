# CLAUDE.md — bxp-gui

Guidance for Claude Code when working with the bxp-gui package.
For monorepo-level context see [`../CLAUDE.md`](../CLAUDE.md).

## Purpose

**bxp-gui** — Flutter desktop app (Linux/macOS/Windows) that replaces the
older Electrobun-based bxp-ui. Edits JSON5 conversion configs, validates
them on load and save, runs dry-runs and conversions through the bxp-cli engine, and
inspects per-row expression traces.

The Flutter side does not parse JSON5 itself for runtime conversions —
every backend operation goes through bxp-cli or bxp-fmt as a short-lived
subprocess. The local **Dart JSON5 AST** library (`packages/json5_ast/`)
is used for in-place editing of the user's config file: parse → mutate →
dump back, preserving comments and formatting.

## Source layout

```text
bxp-gui/
├── lib/
│   ├── main.dart           # Flutter entry; window + theme + provider wiring
│   ├── services/
│   │   ├── app_runtime.dart                  # Top-level lifecycle helpers + startup gate
│   │   ├── ast_loader.dart                   # Parse the user config to a JsonAstNode tree
│   │   ├── ast_patch_client.dart             # Apply AST mutations + dump back to disk
│   │   ├── bridge_client.dart                # Dart FFI shim for bxp-gui-bridge (DLL on Win,
│   │   │                                     # .so/.dylib on Linux/macOS for bridge_eval_expr)
│   │   ├── bxp_process_client.dart           # Subprocess wrapper — bridge on Windows, Process.start elsewhere
│   │   ├── dart_validator.dart               # Dart-side per-edit expression validator (DartValidator)
│   │   ├── debug_binding.dart                # WidgetsFlutterBinding hook for diagnostic capture
│   │   ├── debug_settings.dart               # Opt-in regression knobs (paint, hover, scroll filters)
│   │   ├── desktop_integration_service.dart  # First-run .desktop + hicolor icon writer (Linux AppImage)
│   │   ├── dev_trace.dart                    # kDebugMode-gated print() helper
│   │   ├── diagnostic_log.dart               # Opt-in NDJSON trace + engine stderr capture (BXP_DIAGNOSTIC=1)
│   │   ├── op_log.dart                       # In-memory record of user edits since load
│   │   ├── op_to_ast.dart                    # Translate ConfigOp → AST mutations
│   │   ├── prefs_service.dart                # User preferences persistence
│   │   ├── schema_doc_lookup.dart            # Resolve a config-tree path against the FieldDoc catalog
│   │   ├── schema_gate.dart                  # Schema-aware "may the user do X here?"
│   │   └── updater_service.dart              # GitHub release poller + download/verify/install
│   ├── store/
│   │   ├── trace_store.dart         # ChangeNotifier — central state (~2.9k lines)
│   │   ├── trace_builder.dart       # Build per-row trace data structures
│   │   └── trace_model.dart         # POJO shapes for trace events
│   └── ui/
│       ├── main_view.dart           # 3-pane layout root
│       ├── config_view.dart         # JSON5 tree editor pane
│       ├── debug_overlay.dart       # Floating debug counter overlay (BXP_DIAGNOSTIC)
│       ├── debug_panes.dart         # Trace/output bottom panes
│       ├── settings_inspector.dart  # Ctrl+Shift+S internal-state drawer
│       ├── layout_defaults.dart     # Centralised fractional split sizes
│       ├── shader_warmup.dart       # Skia shader pre-warmup (Windows perf — see below)
│       ├── zoom_limits.dart         # Window/zoom guards
│       ├── theme/                   # App theme (bxp_theme, bxp_text, bxp_text_scheme,
│       │                            # bxp_theme_animator, theme_inspector)
│       └── components/
│           ├── json_tree.dart         # Recursive tree renderer with insert/edit slots
│           ├── expr_editor.dart       # Expression input with autocomplete
│           ├── expr_panel.dart        # Right-rail expression preview
│           ├── expr_playground.dart   # Standalone expression sandbox
│           ├── expr_highlight.dart    # Token-aware syntax highlighter
│           ├── row_detail.dart        # Per-row variable/rule trace details
│           ├── row_list.dart          # Master row picker
│           ├── file_list.dart         # Multi-file dry-run output
│           ├── output_panel.dart      # bxp-cli stdout/stderr viewer
│           ├── top_bar.dart           # Title bar + actions
│           ├── panel_header.dart      # Reusable header chrome
│           ├── resize_handle.dart     # Splitter drag handle
│           ├── open_dialog.dart       # Recent-files / file picker
│           ├── integrate_dialog.dart  # First-run Linux desktop-integration prompt
│           └── update_dialog.dart     # In-app updater prompt
├── packages/json5_ast/              # Path-dep Dart JSON5 AST library
│   ├── lib/                         # parser, tokenizer, ast, dumper,
│   │                                # operations, path, value_builder —
│   │                                # all pure Dart, no bxp-specific code
│   ├── test/                        # ~105 unit tests incl. round-trip
│   │                                # canonicalisation
│   ├── pubspec.yaml                 # name: json5_ast — candidate for
│   │                                # extraction to a standalone repo
│   │                                # once a second Dart consumer exists
│   └── (post-Phase-5e replacement for the deleted CST byte-patcher)
├── linux/, macos/, windows/, web/   # Per-platform Flutter shells
├── test/
│   ├── desktop_integration_service_test.dart
│   ├── expr_corpus_bridge_test.dart      # cross-runner expr corpus parity (bridge vs bxp-fmt)
│   ├── prefs_service_test.dart
│   └── zoom_overflow_test.dart
├── pubspec.yaml
└── README.md
```

## Architecture overview

Three layers, top-down:

1. **services/** — wraps everything that talks to the outside world: the
   bxp-cli/bxp-fmt subprocesses, the local AST library, the user's
   filesystem. Pure Dart, no Flutter imports.
2. **store/** — `TraceStore` is the single `ChangeNotifier` driving every
   pane. Holds the loaded config (as both `JsonAstNode` and
   `Map<String, dynamic>` views), the current dry-run trace, the op log,
   schema docs, and validation errors.
3. **ui/** — Provider-based widgets that consume `TraceStore`. Edits flow
   back as `ConfigOp`s; live save runs through `op_to_ast` →
   `ast_patch_client`.

## Subprocess wiring

`BxpProcessClient` ([lib/services/bxp_process_client.dart](lib/services/bxp_process_client.dart)) is the
single entry point for binary calls. Two transport paths exist; the
choice is hard-coded by host OS:

- **Windows** — every call goes through `bxp-gui-bridge.dll` (a Zig
  shared library, see [`../bxp-gui-bridge/`](../bxp-gui-bridge/)).
  The DLL is mandatory; probe failure at startup is fatal (synthetic
  error surfaced through the normal startup gate). The bridge sidesteps
  dart:io's Win pipe truncation (dart-lang/sdk#1727) on `--docs` /
  `--config` / `--trace`.
- **Linux / macOS** — direct `Process.start`. The bridge is dormant on
  these hosts (cross-platform consolidation is on the v0.3.0 roadmap).

Binary location for `bxp-cli` / `bxp-fmt` is resolved in this order on
both transports:

1. `BXP_CLI_PATH` / `BXP_FMT_PATH` env vars (developer override)
2. Sibling binaries inside the Flutter bundle (`bundle/data/flutter_assets/`
   / Linux `bundle/lib/`)
3. Workspace-root fallback when running `flutter run` from a dev tree
   (`../bxp-cli/zig-out/bin/bxp-cli`, etc.)

The bridge DLL itself (Windows) is resolved by `findBridgeLibrary()` in
[lib/services/bridge_client.dart](lib/services/bridge_client.dart)
using the same sibling-then-dev-tree walk.

**Linux dev tree gotcha:** the Linux CMake config copies `bxp-fmt` into
the bundle at build time. After changing bxp-fmt, run a clean Flutter
build (or maintain the symlink under `linux/`); the production release
script (`scripts/release-02-desktop.sh`) overwrites both companions with
release builds before packaging.

## User preferences

`PrefsService` ([lib/services/prefs_service.dart](lib/services/prefs_service.dart))
persists 5 keys (`bxp-ui.theme`, `bxp-ui.textScheme`, `bxp-gui.zoom`,
`bxp-ui.recent`, `bxp-gui.customPlaces`) to a single visible JSON file:

- Linux: `~/.local/share/bxp-gui/bxp-gui.json`
- macOS: `~/Library/Application Support/bxp-gui/bxp-gui.json`
- Windows: `%APPDATA%\bxp-gui\bxp-gui.json`

Path resolution is **manual** (HOME / APPDATA env vars), NOT
`path_provider.getApplicationSupportDirectory()` — the latter appends
the bundle-id and would couple the prefs path to the Phase 5 identifier
rename. Keeping it bundle-id-independent means upgrades across
identifier changes don't lose user state.

## Auto-updater

`UpdaterService` ([lib/services/updater_service.dart](lib/services/updater_service.dart))
polls `api.github.com/repos/zaxified/bxp/releases/latest` 5 s after
launch and every 6 h thereafter; if a newer tag is found, surfaces an
`UpdateInfo` via ChangeNotifier. The dialog
([lib/ui/components/update_dialog.dart](lib/ui/components/update_dialog.dart))
is mounted by `_UpdaterListener` in `main.dart` so it can fire from any
route.

On accept, the matching native installer is downloaded to the system
temp dir, verified against `SHA256SUMS` published with the release, and
dispatched to a platform-native install:

- Windows: `setup.exe /S` (NSIS silent) + `exit(0)`; post-install
  relaunches the GUI.
- macOS: `hdiutil` mount → `cp -R` to `~/Applications/` → `open -n`.
- Linux AppImage: atomic-replace the running AppImage + re-`exec()`.
- Linux `.deb` / tarball: open release page via `url_launcher` (the
  in-place self-update path is AppImage-only).

`kDebugMode` skips the auto-check during dev runs.

The client maps each subcommand to a method:

- `validateConfig(path)` → `bxp-fmt --config <path>` → annotated JSON with
  `$comm_*`/`$err_*` siblings.
- `getDocs()` → `bxp-fmt --docs` → cached at startup, drives FnDoc
  tooltips, the schema gate, and `_AddChildDialog` insert scaffolds.
- `listTemplates(path)` → `bxp-fmt --config ... --list-templates`.
- `validateExpr(text)` → `bxp-fmt --expr ...`.
- `traceExpr(text, headers, fields)` → `bxp-fmt --expr-trace` (NDJSON
  stream).
- `runDryRun(path, template)` → `bxp-cli --trace ...` (NDJSON stream of
  per-row trace events).
- `getVersion(name)` → `bxp-cli --version` / `bxp-fmt --version` (both go
  to stdout, not stderr).

## AST library (packages/json5_ast)

A standalone Dart package that parses JSON5 to a comment-preserving AST,
applies mutations (insert / delete / move / set), and dumps back to text.
Used for the user's `bxp-cli.json` so saves don't reformat the file.
Replaces the older `bxp-fmt`-based byte-patcher pipeline.

Round-trip identity is verified by `scripts/test.sh`'s "AST round-trip"
phase against `DEV/bxp-cli.json`.

## Build and run

```bash
# Dependencies
cd bxp-gui && flutter pub get

# Linux desktop dev run
flutter run -d linux

# Tests
flutter test
```

The dev run picks up sibling `bxp-cli`/`bxp-fmt` binaries; build them
first if you haven't.

## MCP development workflow

For interactive Flutter debugging use the `dart` MCP server tools in
preference to shell calls:

- `mcp__dart__launch_app` — start the app under MCP control. The `root`
  parameter must be a plain absolute path, NOT a `file://` URL.
- `mcp__dart__get_app_logs` — captures `print()` output only (NOT
  `developer.log`); use the `[bxp_gui]` prefix and `kDebugMode` gate via
  `dev_trace.dart`.
- `mcp__dart__hot_reload` — reload after Dart changes. Reload + log read
  is the live debug cycle.

## Conventions

- All code comments and documentation in English.
- Layout: every resizable splitter holds **fractions**, not pixels —
  `lib/ui/layout_defaults.dart` is the single source. 3-pane layout = 2
  fractions plus the middle by subtraction.
- Load-time errors gate the readonly toolbar (`_loadedWithErrors`); mid-edit
  errors do not lock undo/redo, since validation only runs on load and save.
- `--docs` JSON is the single source of truth for FnDoc/FieldDoc — no
  hard-coded fallback catalogs. Startup gate fails fatally if the binary
  is missing.
- Streaming traces: never call top-level `notifyListeners()` per trace
  event. Use per-cell `ValueNotifier` (e.g. `traceLinesCounter`,
  `fileGen`) to avoid quadratic PlutoGrid rebuild storms.
- Global keyboard shortcuts (Ctrl+S/Z/Y) use
  `HardwareKeyboard.instance.addHandler` in `initState`, not
  `CallbackShortcuts` — the latter only fires when focus bubbles up.

## Windows performance notes

Three Windows-only concerns shaped the current architecture:

- **Skia shader pre-warmup** — `BxpShaderWarmUp`
  ([lib/ui/shader_warmup.dart](lib/ui/shader_warmup.dart)) renders the
  bxp paint mix (filled / stroked rect, divider line, shadow rounded
  rect, AA circle, AA path, 3 text runs) onto an offscreen 100×100
  canvas the first time `PaintingBinding` initialises. Wired in
  [lib/main.dart](lib/main.dart) BEFORE the binding constructs itself —
  otherwise `initInstances` runs the default empty warmup. Effect:
  ~10 % startup latency reduction on release builds. Does NOT mitigate
  the resize-event lag below — that path is GPU pipeline / swap chain,
  not shader compilation.
- **Bridge subprocess (Windows-only)** — `bxp-gui-bridge.dll` hosts the
  bxp-cli / bxp-fmt subprocess pipeline because the default
  `Process.start` path occasionally hangs the Flutter event loop on
  stdout drain. The bridge is the ONLY path on Windows; DLL probe
  failure at startup is fatal (synthetic error surfaced through the
  normal startup gate). Linux and macOS still use `Process.start`
  directly. Cross-platform consolidation is on the v0.3.0 roadmap.
- **Engine stderr capture** —
  [windows/runner/win32_window.cpp](windows/runner/win32_window.cpp)
  redirects the Flutter engine's stderr through `CreatePipe` + a
  detached reader thread before the engine boots. `freopen_s` would
  break the engine under `/SUBSYSTEM:WINDOWS`. Captured output flows
  into the diagnostic trace when `BXP_DIAGNOSTIC=1` is set.

### Known limitation — VMware Workstation host

VMware SVGA D3D11 driver exhibits a 1-3 s lag when the swap chain
reallocates surfaces on transition to ultra-wide resolutions
(maximize on >1920×1200 viewports). Initial paint at the same target
resolution is fluid — only the size-change event triggers it.
VirtualBox SVGA and bare-metal Windows are not affected. This is
upstream Flutter / Win32 D3D11 behaviour, not patchable in the
runner. User-facing note in
[../docs/devel.md](../docs/devel.md#known-issues).
