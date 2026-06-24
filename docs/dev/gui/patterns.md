# Patterns, How-to & Known Issues

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

### Wide-CSV render cap

The trace grid is a **debug viewer, not a spreadsheet**. The CLI accepts up to
`MAX_COLUMNS` (16384) columns, but the GUI renders at most `kMaxDisplayCols`
(200) ([store/trace_store.dart](https://github.com/zaxified/bxp/blob/master/bxp-gui/lib/store/trace_store.dart)); files
wider than `kWideColLimit` (64) data columns also skip the per-column filter
pass. Both caps exist because PlutoGrid cost scales with column count — laying
out 16k+ columns on every rebuild would stall the UI for no debugging benefit
(you read a handful of columns at a time). Drill-down still resolves every
column; only the grid render is capped.

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

## Known issues

**VMware Workstation host: maximize lag on ultra-wide resolutions.**
When running bxp-gui inside a VMware Workstation Windows guest, maximizing the
window onto a viewport larger than ~1920×1200 produces a 1-3 s freeze on the
maximize transition. Bare-metal Windows, macOS, Linux, and VirtualBox guests are
not affected.

The freeze is the VMware SVGA D3D11 driver reallocating swap-chain surfaces on
size change — initial paint at the same target resolution is fluid; only the
size-change event triggers it. This is upstream Flutter / Win32 D3D11 behaviour
and cannot be patched in the runner.

**Workaround:** none required. The lag clears itself in 1-3 s, the window does
not crash, and subsequent resizes within the same surface size are smooth.
Documented here so a "maximize is laggy on VMware" report is not mistaken for a
regression.
