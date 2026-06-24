# GUI internals

Flutter desktop app (`bxp-gui`) that provides a visual config editor, dry-run
debugger, and expression playground on top of the `bxp-cli` conversion
pair. Runs on Linux, macOS, and Windows.

---

## Why Flutter / Dart

bxp-gui replaced an earlier Electrobun + React + CodeMirror 6 frontend
(bxp-ui). The switch to Flutter was driven by:

- **Cross-platform single binary.** Flutter desktop compiles to a
  self-contained executable with no webview runtime dependency. The same
  Dart source builds on Linux, macOS, and Windows from one codebase.
- **Subprocess streaming fits naturally.** A subprocess stdout
  `Stream<List<int>>` maps directly onto the BXTB frame reader (and the NDJSON
  line splitter for expr-trace). The native `bxp-gui-bridge` does the actual
  spawn + pipe drain — Dart's own `Process.start` truncates large stdout on
  Windows (dart-lang/sdk#1727) — then feeds the bytes into that same Dart stream
  model, so the stream stays the protocol.
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

## Deeper reference

This guide covers structure, dev workflow, and the patterns a new contributor
needs to ship a first change. Internal-API contracts and design-decision
rationales live in:

- [`bxp-gui/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-gui/CLAUDE.md) — Flutter side: services /
  store / ui split, BxpProcessClient binary resolution, prefs path policy,
  auto-updater install paths, MCP debug workflow, conventions enforced.
- [`bxp-gui/packages/json5_ast/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-gui/packages/json5_ast/CLAUDE.md) —
  json5_ast public API, comment-ownership rules, round-trip / idempotent
  canonicalisation contract, future extraction recipe.
