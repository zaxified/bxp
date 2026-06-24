# GUI features

These features are GUI-specific and have no terminal equivalent. They
exist to make authoring and debugging a template faster than editing
JSON5 by hand.

## Keyboard shortcuts

All shortcuts are global (work even while a side panel has focus). The full
list — generated from the app's own shortcut catalog, so it never drifts — is
in [Keyboard shortcuts](../reference/gui-shortcuts.md).

The toolbar's `dry-run` and `full-run` buttons have no shortcuts —
clicking them is the only way to start a run, and clicking again while a
run is active cancels it (the label flips to `cancel`).

## Inline schema docs

Hover any field in the tree to see its description, type, default, and
which expressions it accepts. The catalog is the bundled docs catalog
(the GUI loads it in-process from the bridge library at startup) — the
same source of truth that drives autocomplete in the expression editor.
Add a built-in function to bxp-cli, run a clean rebuild, and the GUI sees
it automatically with no client-side changes.

## Expression playground

Click any expression cell — a panel opens on the right with:

- A live editor with syntax highlighting and per-keystroke validation.
- Autocomplete (ctrl+space) for built-in functions, `$variables`, and
  `[ColumnName]` references that exist in the loaded template.
- Token-level error underlines: a typo'd `[Quanity]` (instead of
  `[Quantity]`) gets a red underline on exactly the wrong token, with a
  did-you-mean tooltip.
- A **Variables** sub-panel that evaluates the expression against the
  current row in-process (via the bundled bridge) and lists every nested
  function call's intermediate value. Excellent for debugging "why did
  this expression return empty string?" cases.

## Add Field dialog

When an object's parent schema permits new keys, a `+` chip appears.
Clicking it opens a dialog showing only the keys that are valid here
(driven by `FieldDoc` schema metadata), with default values and inserted
templates pre-filled. No need to remember which fields go where.

## Settings inspector (ctrl+shift+s)

A drawer slides in from the right with the GUI's complete internal state:

- Loaded config path, raw bytes, AST root.
- Schema docs catalog (loaded in-process from the bundled bridge at startup).
- Op log (undo / redo history).
- Path-keyed validation errors / warnings / info.
- Run state (last exit code, stderr text, trace event count).

Use it when something looks weird and you want to confirm "is the GUI
seeing what I think it's seeing?".

## Cancel and watchdog

The run can be cancelled mid-stream by clicking the `cancel` button (the
run-button label flips). A 10-second internal idle watchdog also fires
SIGTERM if the bxp-cli child stops emitting events; if SIGTERM doesn't
take effect within 2 seconds, SIGKILL escalates. You'll never end up with
a zombie subprocess blocking the UI.

## Filesystem checks (slow paths)

By default config validation skips filesystem checks (existence of
`data_dir`, of input files) so loading is snappy. Triggering ctrl+e
(Validate) re-runs validation with a `check-fs` deadline of 2 seconds to
add these checks. If a check times out, the GUI flips into a degraded mode
for the rest of the session: subsequent reloads omit the flag too. This
stops a network-mounted `data_dir` from making the editor feel sluggish.
