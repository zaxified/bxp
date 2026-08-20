---
description: "What the desktop app adds over the CLI: the config tree editor, dry-run debugger and expression playground."
---

# GUI features

These features are GUI-specific and have no terminal equivalent. They
exist to make authoring and debugging a template faster than editing
JSON5 by hand.

## Keyboard shortcuts

All shortcuts are global (work even while a side panel has focus). The full
list — generated from the app's own shortcut catalog, so it never drifts — is
in [Keyboard shortcuts](../reference/gui-shortcuts.md).

The toolbar's `dry-run` and `full-run` buttons have no shortcuts —
clicking them is the only way to start a run. The button that started the
run doubles as the stop control (its label flips to `cancel`); the other
mode's button is disabled meanwhile, so you cannot cancel by accident
while reaching for it.

## Inline schema docs

Hover any field in the tree to see its description, type, default, and
which expressions it accepts. The catalog is the bundled docs catalog
(the GUI loads it in-process from the bridge library at startup) — the
same source of truth that drives autocomplete in the expression editor.
Add a built-in function to the engine, run a clean rebuild of the bridge,
and the GUI sees it automatically with no client-side changes.

## Expression playground

Click any expression cell — a panel opens on the right with:

- A live editor with syntax highlighting and per-keystroke validation.
- Autocomplete (ctrl+space) for built-in functions, `$variables`, and
  `[ColumnName]` references that exist in the loaded template.
- Token-level error underlines: a typo'd `[Quanity]` (instead of
  `[Quantity]`) gets a red underline on exactly the wrong token, with a
  did-you-mean tooltip.
- Per-call intermediate values: once a run has populated the row list,
  selecting a row evaluates every nested function call in the expression
  against that row in-process (via the bundled bridge) and shows what each
  one returned. Excellent for debugging "why did this expression return
  empty string?" cases. The same row fills **ROW SELECTED** (its source
  fields) and **ROW TRANSFORM** (**VARIABLES**, **RULES**, **RULE
  RESULTS**) below.

## Add Field dialog

When an object's parent schema permits new keys, a `+` chip appears.
Clicking it opens a dialog showing only the keys that are valid here
(driven by `FieldDoc` schema metadata), with default values and inserted
templates pre-filled. No need to remember which fields go where.

## Settings inspector (ctrl+shift+s)

A drawer slides in from the right with the GUI's internal state, grouped
into sections:

- **Versions** / **Binaries** — bxp-gui, bxp-cli and bxp-mcp versions, and
  the resolved paths they were found at (including a `BXP_CLI_PATH`
  override when one is set).
- **Bridge** — the loaded `bxp-gui-bridge` version, its library path, and
  the last diagnostic it reported.
- **Config** — loaded path, dirty / saving flags, whether the file has
  errors now or loaded with them, the `fsCheckSlow` latch, and any load
  error.
- **Templates** — the template ids declared in the loaded config.
- **Run state** — last exit code, stderr size, trace-line count.
- **Theme**, **Keyboard shortcuts**, **Preferences** — the latter two
  rendered straight from the app's own catalogs, so they cannot drift.
- **Agent control** — the gui-mcp server toggle, its live listening
  address, the endpoint / Origin-allowlist editor, the auto-approve
  toggle, and a log of what a connected agent did. See [Driving the GUI
  with an agent](../ai/gui-mcp.md).
- **Diagnostic mode** and the rendering / input debug switches.

Use it when something looks weird and you want to confirm "is the GUI
seeing what I think it's seeing?".

## Cancelling a run

The run can be cancelled mid-stream by clicking the `cancel` button (the
run-button label flips from `dry-run` / `full-run` to `cancel`, then to
`cancelling…` once the click registers). Cancel signals the `bxp-cli`
child **once** through the bridge (SIGTERM on POSIX, `TerminateProcess`
on Windows) and lets the streaming run resolve naturally with whatever
landed before the signal — partial output stays on screen. There is no
escalation to SIGKILL and no idle watchdog: a child that ignores the
signal is waited on, not force-killed.

## Filesystem checks

Config validation includes filesystem-existence checks (`data_dir`, input
files) on every load and save, with a `check-fs` deadline of 2 seconds.
ctrl+e (Validate) re-runs the same pass on demand — against your unsaved
draft rather than the file on disk.

If a check ever times out, the GUI degrades for the rest of the session:
subsequent load/save validations drop the filesystem pass entirely, so a
network-mounted `data_dir` only pays the deadline once. The Settings
inspector's Config section shows the latch as `fsCheckSlow`; it resets on
app restart, and there is no UI toggle for it.
