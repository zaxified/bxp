# CLAUDE.md — bxp-gui

Guidance for Claude Code when working with the bxp-gui package.
For monorepo-level context see [`../CLAUDE.md`](../CLAUDE.md).

## Purpose

**bxp-gui** — Flutter desktop app (Linux/macOS/Windows) that replaces the
older Electrobun-based bxp-ui. Edits JSON5 conversion configs, validates
them on load and save, runs dry-runs and conversions through the bxp-cli engine, and
inspects per-row expression traces.

The Flutter side does not parse JSON5 itself for runtime conversions —
every backend operation goes through the in-process `bxp-gui-bridge` (stateless
ops + proxied `bxp-cli` runs). The local **Dart JSON5 AST** library (`packages/json5_ast/`)
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
│   │   ├── btrace.dart                       # Dart-side BXTB binary-trace parser (mirrors btrace.zig)
│   │   ├── bxp_process_client.dart           # Bridge-backed client — single backend all platforms (no Process.start)
│   │   ├── csv_row_fetcher.dart              # Random-access source/output row fetch by byte offset
│   │   │                                     # (drill-down reconstructs dropped per-row trace frames)
│   │   ├── dart_validator.dart               # Dart-side per-edit expression validator (DartValidator)
│   │   │                                     # (dart_validator_coverage.md tracks builtin coverage)
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
│   │   ├── trace_store.dart         # ChangeNotifier — central state (~4.1k lines, includes BXTB ingest)
│   │   └── trace_model.dart         # POJO shapes for trace events
│   └── ui/
│       ├── main_view.dart           # 3-pane layout root
│       ├── config_view.dart         # JSON5 tree editor pane
│       ├── debug_overlay.dart       # Floating debug counter overlay (BXP_DIAGNOSTIC)
│       ├── debug_panes.dart         # Trace/output bottom panes
│       ├── settings_inspector.dart  # Ctrl+Shift+S internal-state drawer
│       ├── layout_defaults.dart     # Centralised fractional split sizes
│       ├── platform_shortcuts.dart  # Command-modifier helper (Cmd on macOS, Ctrl elsewhere)
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
│   ├── test/                        # ~107 unit tests incl. round-trip
│   │                                # canonicalisation
│   ├── pubspec.yaml                 # name: json5_ast — candidate for
│   │                                # extraction to a standalone repo
│   │                                # once a second Dart consumer exists
│   └── (post-Phase-5e replacement for the deleted CST byte-patcher)
├── linux/, macos/, windows/, web/   # Per-platform Flutter shells
├── test/
│   ├── btrace_format_contract_test.dart  # BXTB wire-format contract (Dart parser vs Zig writer)
│   ├── btrace_test.dart                  # BXTB parser roundtrip
│   ├── csv_row_fetcher_test.dart         # byte-offset random-access row fetch
│   ├── desktop_integration_service_test.dart
│   ├── examples_unique_name_test.dart    # open-dialog "create examples" unique-naming
│   ├── expr_batch_test.dart              # --expr-batch request/response shape
│   ├── expr_corpus_bridge_test.dart      # corpus validation via bridge_eval_expr (vs expected outcome)
│   ├── bridge_inspect_test.dart          # bridge_inspect FFI structural validity (docs/config/list/fetch/batch)
│   ├── prefs_service_test.dart
│   └── zoom_overflow_test.dart
├── pubspec.yaml
└── README.md
```

## Architecture overview

Three layers, top-down:

1. **services/** — wraps everything that talks to the outside world: the
   `bxp-gui-bridge` FFI (and the `bxp-cli` runs it proxies), the local AST
   library, the user's filesystem. Pure Dart, no Flutter imports.
2. **store/** — `TraceStore` is the single `ChangeNotifier` driving every
   pane. Holds the loaded config (as both `JsonAstNode` and
   `Map<String, dynamic>` views), the current dry-run trace, the op log,
   schema docs, and validation errors.
3. **ui/** — Provider-based widgets that consume `TraceStore`. Edits flow
   back as `ConfigOp`s; live save runs through `op_to_ast` →
   `ast_patch_client`.

## Subprocess wiring

`BxpProcessClient` ([lib/services/bxp_process_client.dart](lib/services/bxp_process_client.dart)) is the
single entry point for binary calls. The `bxp-gui-bridge` shared library
(a Zig library, see [`../bxp-gui-bridge/`](../bxp-gui-bridge/)) is the
**single backend on every platform** — there is no `bxp-fmt` subprocess
and no `Process.start` path (both were retired in the v0.3.0 proxy flip,
2026-06-09). One library, two call shapes:

- **Stateless ops, in-process** — `getDocs` / `loadConfig` /
  `listTemplates` / `fetchTemplate` / `evalBatch` (`bridge_inspect`) and
  per-keystroke `validateExpr` / `traceExpr` (`bridge_eval_expr` /
  `_trace`) run synchronously on the main isolate (sub-ms, served from
  bxp-core/inspect). No spawn.
- **`bxp-cli` runs, proxied** — dry-run / full-run stream through
  `bridge_run_streaming`; `--version` through `bridge_run`. These run in
  an `Isolate.run` worker so the blocking pipe drain doesn't stall the UI;
  the bridge drains the pipe in native Zig code (sidestepping dart:io's
  Windows pipe truncation, dart-lang/sdk#1727).

The bridge library is **mandatory**: probe failure at startup is fatal
(the docs gate surfaces it) on every platform — a missing library means a
broken install. The startup gate checks `ensureBridgeLoaded()` + a `docs`
parse, not whether `bxp-fmt` is on disk. `bxp-cli` is still a real binary
the bridge spawns; only `bxp-fmt` left the GUI's runtime dependency set
(the bridge links bxp-core/inspect directly, so it needs neither binary).

`bxp-cli` location is resolved in this order:

1. `BXP_CLI_PATH` env var (developer override)
2. Sibling binary inside the Flutter bundle (`bundle/data/flutter_assets/`
   / Linux `bundle/lib/`)
3. Workspace-root fallback when running `flutter run` from a dev tree
   (`../bxp-cli/zig-out/bin/bxp-cli`)

The bridge library itself is resolved by `findBridgeLibrary()` in
[lib/services/bridge_client.dart](lib/services/bridge_client.dart) using
the same sibling-then-dev-tree walk (`zig-out/lib/libbxp-gui-bridge.{so,dylib}`
on POSIX, `zig-out/bin/bxp-gui-bridge.dll` on Windows). Tests inject the
dev-tree path via `setBridgeLibPathForTest`.

**Linux dev tree gotcha:** the Linux CMake config copies the bridge
library (and `bxp-cli`) into the bundle at build time. After rebuilding
the bridge, run a clean Flutter build (or maintain the symlink under
`linux/`); the production release script
(`scripts/release-02-desktop.sh`) overwrites the companions with release
builds before packaging.

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

The client maps each operation to a method. The stateless ones are
`bridge_inspect` / `bridge_eval_*` calls (the `bxp-core/inspect` function behind
each is noted for reference — that JSON shape is the contract); the
`bxp-cli` ones are `bridge_run` / `bridge_run_streaming` proxies:

- `loadConfig(path)` → `bridge_inspect {op:config}` (`inspect.annotateRaw`) →
  annotated JSON with `$comm_*`/`$err_*` siblings. The GUI passes a `check-fs`
  deadline of 2 s on every load/save for filesystem-existence diagnostics.
- `getDocs()` → `bridge_inspect {op:docs}` (`inspect.docsJson`) → cached at
  startup, drives FnDoc tooltips, the schema gate, and `_AddChildDialog`
  insert scaffolds.
- `listTemplates(path)` / `fetchTemplate(path,id)` → `bridge_inspect
  {op:list_templates|fetch_template}`.
- `evalBatch(...)` → `bridge_inspect {op:eval_batch}` (drives drill-down
  re-eval).
- `validateExpr(text)` → `bridge_eval_expr` (`inspect.validateExpr`).
- `traceExpr(text, headers, fields)` → `bridge_eval_expr_trace` (NDJSON
  stream; `inspect.evalTrace`).
- `runWithBtrace(path, template)` → `bridge_run_streaming` spawning
  `bxp-cli --trace=bin` (binary BXTB frame stream of per-row trace events).
- `getVersion('bxp-cli')` → `bridge_run` spawning `bxp-cli --version`
  (stdout, not stderr).

## AST library (packages/json5_ast)

A standalone Dart package that parses JSON5 to a comment-preserving AST,
applies mutations (insert / delete / move / set), and dumps back to text.
Used for the user's `bxp-cli.json` so saves don't reformat the file.
Replaces the older byte-patcher pipeline.

Round-trip identity is verified by `scripts/test.sh`'s "AST round-trip"
phase against `DEV/bxp-cli.json`.

## Agent control (gui-mcp)

`GuiMcpServer` ([lib/services/gui_mcp_server.dart](lib/services/gui_mcp_server.dart))
embeds an MCP server **inside the Flutter process** so a local agent can
drive the live GUI — distinct from the standalone stateless `bxp-mcp` (Zig,
stdio). Transport is localhost **StreamableHTTP**; every tool is a thin
wrapper over the `GuiMcpHost` interface, whose production adapter
(`_TraceStoreMcpHost` in [lib/main.dart](lib/main.dart)) delegates to the
**same** `TraceStore` actions the UI uses, so state changes repaint for
free and parity is definitional.

- **Endpoint** — default `127.0.0.1:7717` (`kDefaultMcpHost` /
  `kDefaultMcpPort`). Host + port are resolved at startup as prefs
  (`bxp-gui.mcpHost` / `bxp-gui.mcpPort`) → env (`BXP_GUI_MCP_HOST` /
  `BXP_GUI_MCP_PORT`) → defaults, and are editable live in the settings
  inspector (Agent control), which persists + `restart()`s the server.
  A fixed (not OS-assigned) default means an external agent reaches a known
  endpoint without a discovery file; a bind clash is surfaced in `lastError`
  (non-fatal — unlike the bridge, the GUI is fully usable without it).
- **`GET /health`** — unauthenticated probe returning `{name, version,
  config_path, config_loaded, dirty, agent_connected, auto_approve}`; the
  handshake an agent uses to confirm it reached the right server before MCP
  `initialize`.
- **Origin policy** — permissive by default (empty allowlist accepts every
  Origin, so webview-based agents that send an `Origin` keep working);
  loopback bind is the baseline protection. A persisted
  `bxp-gui.mcpOriginAllowlist` (editable in the inspector) tightens this
  when the user binds to a network interface.
- **Tools** — `get_state`, `open_config`, `reload`, `edit_node`,
  `insert_node`, `rename_key`, `move_node`, `delete_node`, `set_template`,
  `dry_run`, `full_run`, `get_trace`, `get_row_detail`, `save`, `exit`.
  Mutating-but-additive tools (`edit_node` / `insert_node` / `rename_key` /
  `move_node`) are blocked when the config loaded with errors;
  destructive/side-effecting ones (`save` / `full_run` / `delete_node` /
  `exit`) are gated by an `AgentConfirmFn` dialog (navigatorKey-backed).
  The structural verbs (`insert_node` / `rename_key` / `move_node` /
  `delete_node`) compare `TraceStore.editRevision` before/after the call and
  report `{<verb>:false, reason}` when the store **silently no-ops** a guarded
  edit (a schema-`required` key, a duplicate key, an out-of-range move) — so
  the tool never reports a false success.
  `get_row_detail` lazy-loads a row's trace detail via
  `TraceStore.ensureDetailLoaded` and is projected to JSON in the
  `_TraceStoreMcpHost` adapter. Every call appends one `AgentActivityEntry`
  and reveals its target node in the tree.
- **Auto-approve** (dev/testing) — auto-approves the `AgentConfirmFn` dialogs
  without prompting, so an agent can drive the live GUI headlessly (a semantic
  alternative to Playwright — every tool is a real `TraceStore` action, so
  parity is definitional). `GuiMcpServer.autoApprove` is the single source of
  truth for the gate ([_confirmAction](lib/services/gui_mcp_server.dart)) and is
  fed by two inputs: the `BXP_GUI_MCP_AUTO_APPROVE` env var (seeds it at
  startup — for headless CI) and the **persisted `bxp-gui.mcpAutoApprove`
  pref** (the inspector's *Agent control → Auto-approve agent actions* toggle).
  The pref is the one that matters for `launch_app`-driven debugging: `mcp-flutter`
  cannot pass env, so the persisted toggle is what survives across launches.
  Default off → an interactive user always sees the dialog. State is surfaced as
  `auto_approve` in `/health` + `get_state` and a red `devel-auto-approve-mode`
  status-bar chip, so a driving agent (and a watching user) can see the gate is
  off. The project `.mcp.json` registers the server at `127.0.0.1:7717` (the
  default port) so the tools are reachable whenever the GUI is running.

Tested over real HTTP in
[test/gui_mcp_server_test.dart](test/gui_mcp_server_test.dart) against a
`_FakeHost` (no `TraceStore` / bridge probe). Deferred follow-up:
activity-log UI polish.

## Build and run

```bash
# Dependencies
cd bxp-gui && flutter pub get

# Linux desktop dev run
flutter run -d linux

# Tests
flutter test
```

The dev run picks up the sibling `bxp-cli` binary + the `bxp-gui-bridge`
library; build them first if you haven't.

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

### Self-debug cycle (gui-mcp, headless)

To verify a GUI change end-to-end without manual clicking, drive the live app
through the embedded gui-mcp (the `.mcp.json` server at `127.0.0.1:7717`) —
every tool is a real `TraceStore` action, so this is the semantic Playwright
replacement. The gui-mcp endpoint is **ephemeral**: it only exists while the
GUI runs, so launch first.

1. **One-time** — turn on *Settings inspector (Ctrl+Shift+S) → Agent control →
   Auto-approve agent actions*. Persisted in `bxp-gui.json`
   (`bxp-gui.mcpAutoApprove`), so it survives across launches — `launch_app`
   can't set the env var, so this persisted toggle is what enables headless
   driving. A red `devel-auto-approve-mode` chip confirms it is on.
2. `mcp__dart__launch_app(root: <abs path>, device: linux)` — env not needed.
3. Poll `GET http://127.0.0.1:7717/health` until it returns
   `{"auto_approve": true, ...}` (server up + gate off).
4. Drive via the gui-mcp tools (`open_config` → `edit_node` / `dry_run` /
   `get_trace` / `get_row_detail` …) — destructive tools (`save` / `full_run` /
   `delete_node` / `exit`) no longer prompt.
5. Close with the gui-mcp `exit` tool.

Default is off, so an interactive user is never silently bypassed; flipping the
toggle is an explicit, visible (red chip) developer action.

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
- Global keyboard shortcuts (Save/Undo/Redo/Open/Zoom) use
  `HardwareKeyboard.instance.addHandler` in `initState`, not
  `CallbackShortcuts` — the latter only fires when focus bubbles up.
  The command modifier is resolved per-host via `isCommandModifierPressed()`
  in [lib/ui/platform_shortcuts.dart](lib/ui/platform_shortcuts.dart) — `Cmd`
  (Meta) on macOS, `Ctrl` elsewhere — so bindings follow host convention and
  don't collide with macOS `Ctrl+Up`/`Ctrl+Down` Mission Control.

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
- **Bridge subprocess (now all platforms)** — `bxp-gui-bridge` hosts the
  `bxp-cli` subprocess pipeline because the default `Process.start` path
  hangs the Flutter event loop on stdout drain (and truncates large stdout
  on Windows, dart-lang/sdk#1727). Windows was the original mandatory case;
  the v0.3.0 flip (2026-06-09) made the bridge the single backend on every
  platform — the `Process.start` path was deleted. Library probe failure at
  startup is fatal on all hosts (synthetic error through the startup gate).
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
