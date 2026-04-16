# CLAUDE.md — bxp-gui

DVUI desktop editor + dry-run debugger for [bxp-cli](../bxp-cli/) JSON5 configurations.
For monorepo-level context see [`../CLAUDE.md`](../CLAUDE.md).
For the original implementation plan (Czech), see [`../DEV/4-bxp-gui-plan.md`](../DEV/4-bxp-gui-plan.md).

## Purpose

bxp-gui is an **editor + debugger** for `bxp-cli.json` configurations. It is **not** a runner —
actual broker → Wealthfolio conversions remain in bxp-cli. The GUI helps the user write and
debug templates by visualizing what would happen for each row of an input CSV: input_schema
variable values, row_rules matching, output rows, and pre_pass lookup contents.

## Stack

- **Zig 0.15.2**
- **DVUI v0.4.0** + **SDL3** backend (last version compatible with Zig 0.15.2)
- **bxp-core** as a path dependency (modules: `config`, `csv`, `expr`)
- Multiplatform: Linux ✓, Windows (cross-compile) ✓, macOS deferred (SDL3 needs `--sysroot`)

## Build & test

```bash
cd bxp-gui
zig build           # build executable (zig-out/bin/bxp-gui)
zig build run       # build + launch
zig build test      # unit tests (json5_writer + settings)

# Cross-compile:
zig build -Dtarget=x86_64-linux-gnu     # ELF
zig build -Dtarget=x86_64-windows-gnu   # PE (.exe)
# zig build -Dtarget=aarch64-macos      # FAILS without --sysroot (deferred)
```

## Source layout

```text
bxp-gui/src/
├── main.zig           App entry, dvui.App config, top menu (File / Edit / Debug / View)
├── app.zig            AppState — config in memory, edits buffers, undo stack, simulation, settings
├── layout.zig         3-pane layout; switches center between form view and debug view
├── settings.zig       Persistent settings ($XDG_CONFIG_HOME/bxp-gui/settings.json)
├── simulator.zig      Dry-run engine (read-side mirror of bxp-cli/pipeline.zig)
├── json5_writer.zig   Config writer with canonical key ordering + integration test
├── panels/
│   ├── explorer.zig       Left sidebar: template list (with ⚠ markers)
│   ├── template.zig       Center (form mode): all editable sections of a BrokerConfig
│   ├── debug.zig          Center (debug mode): dry-run controls + row-by-row trace
│   └── status.zig         Bottom status bar
└── expr_editor/
    ├── widget.zig         Expression TextEntry with colored renderer
    ├── highlighter.zig    Tokenizer-based syntax highlighter
    └── autocomplete.zig   dvui.suggestion popup for builtin function names
```

## Architecture

### In-memory model
Loaded via `bxp-core/config.zig` into existing structs (`Config`, `BrokerConfig`, `RowRule`,
`PrePass`, ...). UI mutations happen on the live structs (small fields go through
per-field gpa-owned `edits[]` buffers, then are committed back via
`cfg._alloc.dupe`/`free`). After each successful mutation, `pushUndo()` snapshots the
config.

### Memory ownership (gotchas)
- `template_names: []const u8` items **point into** `cfg.brokers` keys (owned by
  `cfg._alloc`). They MUST be rebuilt after any config swap. `clearTransientState`
  handles this — call it before replacing `config_owner`.
- `edits[]` / `validation[]` use their own gpa-owned buffers — independent of config memory.
- `Simulation.arena` is `*` boxed so `Simulation` can be `null`-stored and moved.

### JSON5 writer
`json5_writer.zig` is bxp-gui's own writer (std.json doesn't preserve key order or
comments). It respects the canonical key ordering documented in
[`../bxp-cli/CLAUDE.md`](../bxp-cli/CLAUDE.md). **Comments are NOT preserved on round-trip**
(would require an AST with comment nodes — `std.json` doesn't carry them).
Integration test: `roundtrip: real bxp-cli.examples.json loads, validates, writes, reloads`
(skipped with `error.SkipZigTest` if `../resources/bxp-cli.examples.json` is missing).

### Dry-run simulator
`simulator.zig` is a **read-side mirror** of `bxp-cli/src/pipeline.zig` — same logic,
no file output:

1. Resolve `data_dir` against the loaded config-file directory.
2. Pick first matching `.csv` (per `file_pattern_in`).
3. Build `pre_pass` lookup table.
4. For each row: evaluate `input_schema` vars + `row_rules`, build output rows.
5. Record everything (raw fields, var values+errors, rule matches, output rows) into
   `RowTrace` structs.

All allocations live in a single `std.heap.ArenaAllocator` per simulation. Soft-fails into
`Simulation.error_message` for missing dirs, no input files, or empty CSV (does not throw).

### Undo/redo
In-memory snapshots (cap 50). Each snapshot is the bytes produced by `writeConfig`.
- `pushUndo()` is called after every successful mutation — i.e. at every site that does
  `revalidateTemplate(...) catch {};`. Debounced via `std.mem.eql` against the current head
  to skip no-op snapshots.
- `restore` writes bytes to `/tmp/bxp_gui_snapshot.json` then calls `config.load` (the
  existing public API), avoiding any bxp-core changes. After reload, `clearTransientState`
  rebuilds `template_names` / `edits` / `validation`, and `selected_template` /
  `loaded_path` / `view_mode` are preserved.

### Settings
`settings.zig` persists to `$XDG_CONFIG_HOME/bxp-gui/settings.json` (fallback
`$HOME/.config/bxp-gui/settings.json`). Stores `recent_files` (cap 8, dedup via
`touchRecent`) and `last_view_mode`. Has its own arena and JSON writer (separate from
`json5_writer.zig`). `AppState.init` loads it; `deinit` saves.

## Implementation status (as of 2026-04-16)

All 6 planned phases implemented. `zig build` and `zig build test` green.

**Phase 1 — Scaffold + multiplatform build:** done.
**Phase 2 — Explorer + form editors:** done. Editable sections: `data_dir`,
`file_pattern_in/out`, `xlsx_sheet`, `csv_format`.
**Phase 3 — Schema mapper + row rules:** done. Editable `input_schema`, `output_schema`,
`row_rules` (add/delete/edit `when`), `ticker_map`, `pre_pass`.
**Phase 4 — Expression editor:** done. Syntax highlighting (own tokenizer in
`expr_editor/highlighter.zig`), autocomplete via `dvui.suggestion` for 18 builtins
(triggered by trailing uppercase identifier).
**Phase 5 — Dry-run simulator:** done. See [Architecture › Dry-run simulator](#dry-run-simulator).
**Phase 6 — Polish:** mostly done.
- ✓ Recent files menu, settings persistence, undo/redo, Linux + Windows cross-compile,
  integration test against `resources/bxp-cli.examples.json`.
- Deferred:
  - **Step Into AST drill-down** (explicitly above MVP per plan; would need bxp-core
    `expr` public-API extension for AST introspection).
  - **TinyVG icons / fonts.**
  - **JSON5 comment preservation** (needs an AST that carries comments).
  - **macOS native build** (needs Apple SDK + SDL `--sysroot` plumbing).

## DVUI / API gotchas

These bit during implementation — check here before debugging again:

- **Duplicate widget IDs cause 100% CPU.** Any helper function called more than once
  from the same parent (`sectionHeader`, `schemaHeaderRow`, `kvRow`, `schemaTable` for
  input vs output) MUST take an `id_extra: usize` parameter and pass it to every widget
  inside. Without it, widgets share `@src()` → DVUI `ScrollContainer` detects fluctuating
  `virtualSize` → infinite `refresh()` cycle. This is the #1 bug source in this codebase.
- **SDL3 on X11 bypasses KDE/Plasma compositor** by default, breaking alt-tab thumbnails
  for ALL windows. Fixed via `SDL_SetHint("SDL_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR", "0")`
  in `appStart()` (before window creation). Do not remove this.
- **`Theme.Style.Name`** members: `content`, `window`, `control`, `highlight`, `err`,
  `app1..3`. **NO `accent`** — use `.highlight` for emphasis.
- **`Config.brokers`** is `std.StringArrayHashMap(BrokerConfig)`. Mutate via
  `cfg.brokers.getPtr(name)`; free old / dupe new strings via `cfg._alloc`.
- **`BrokerConfig.row_rules`** is `?[]RowRule` (optional slice).
  **`output_schema`** is `std.array_list.Managed(OutputColumn)`.
- **`dvui.label`** takes a `comptime fmt`. For dynamic strings use
  `textLayout` + `addText`.
- **`PanedWidget`** children MUST be inside `if (paned.showFirst())` /
  `if (paned.showSecond())`. `split_ratio: ?*f32` defaults 0.5/0.5 — pass an explicit
  pointer to control it.
- **`dvui.dropdown(src, entries, .{ .choice = &idx }, init_opts, opts)`** —
  `DropdownChoice` is a tagged union.
- **`dvui.suggestion(te, ...)`** requires the lower-level path:
  `widgetAlloc(TextEntryWidget)` + `te.init` + `te.draw` (NOT `dvui.textEntry`). The
  suggestion forwards events to `te` — do **not** call `te.processEvents`.
- **`std.Io.Writer.Allocating.fromArrayList(gpa, &list)`** — must
  `defer list = aw.toArrayList();` to retrieve the bytes.

## Coding conventions

- All code comments and documentation in English (per monorepo convention).
- Zig 0.15.2 API.
- Keep mutations small and atomic so `pushUndo()` snapshots remain meaningful.
- Any new mutation site MUST be paired with `revalidateTemplate(idx) catch {};` followed by
  `pushUndo()` (or a helper that does both).

## Runtime smoke test

The natural manual test is:

1. `zig build run`
2. File → Open → `bxp/DEV/bxp-cli.json`
3. Pick the **Anycoin** template in the sidebar.
4. Debug → Start Dry-Run.
5. Step through rows; verify `pre_pass` is populated and `LOOKUP()` resolves.
