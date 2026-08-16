# Internals

## Design philosophy

BXP is a **configuration-driven ETL micro-tool**. The core principle is:

> Adding a new data source = writing a JSON5 template. No code, no recompilation.

Consequences of this design:

- All broker-specific logic lives in `bxp-cli.json` (`conversion_templates` section).
- `bxp-core` is a generic engine: CSV/XLSX parser, expression evaluator, config loader.
- `bxp-cli` is a thin orchestrator: reads config, finds files, calls the engine.
- The expression language is intentionally limited - it handles per-row transformations, not general-purpose computation.

---

## Package dependency graph

```text
  bxp-cli         ── path dep ──►  bxp-core   ── fetch dep ──►  uucode   (Unicode tables)
  (binary)                         (library)                    regex    (Pike-VM engine)
                                                                zig-libs (datefmt · tz · encoding
                                                                          json5 · decimal)
  bxp-mcp         ── path dep ──►  bxp-core           (wraps inspect.zig; spawns bxp-cli
  (binary)                                             for bxp_simulate)
  bxp-gui-bridge  ── path dep ──►  bxp-core           (links inspect.zig + expr.zig directly)
  (.dll/.so/.dylib)

  bxp-gui  ── FFI ──►  bxp-gui-bridge   (single backend, all platforms:
  (Flutter)                              in-proc inspect + proxied bxp-cli runs)
```

`bxp-core` is a **local path dependency** (`../bxp-core`) and pulls three
external fetch dependencies of its own: `uucode` (Unicode case-mapping tables),
`regex` (`quangd/regex.zig`, the Pike-VM engine behind `REGEX_MATCH`/
`REGEX_EXTRACT`), and `zig_libs` (`datefmt`, `tz`, `encoding`, `json5` and
`decimal`), all pinned in `build.zig.zon`.
`bxp-gui` ships `bxp-cli`, `bxp-mcp`, and `bxp-gui-bridge.{dll,so,dylib}`
inside the Flutter bundle.

### Why the bridge exists

Two independent forces drive the bridge — they happen to combine into one
shared library, but each role solves a different problem.

1. **Windows-only: `dart:io` pipe truncation
   ([dart-lang/sdk#1727](https://github.com/dart-lang/sdk/issues/1727)).**
   `Process.start` on Windows silently cuts subprocess stdout at ~8 KB.
   The docs catalog is ~30 KB and `bxp-cli --trace` is megabytes — both
   unusable through `dart:io`. The bridge reads pipes from native Zig code
   so the drain doesn't depend on the Flutter event loop. On Windows the
   bridge is the **only** path for every subprocess; DLL probe failure at
   startup is fatal (no `Process.start` fallback to silently misbehave).
2. **All platforms: per-keystroke expression eval needs to skip spawn.**
   Validating an expression as a subprocess costs ~50 ms of startup before any
   actual evaluation. The expression editor validates on every keystroke, so the
   spawn cost dominates. `bridge_eval_expr` links `bxp-core/inspect` + `expr`
   directly into the GUI process — no spawn, no pipe drain, sub-millisecond
   evaluation. This path runs on all platforms.

### Per-call routing

Every backend call goes through the bridge — there is no `Process.start` path
and no subprocess fallback on any platform:

| GUI call                               | Bridge entry point                                 |
| -------------------------------------- | -------------------------------------------------- |
| config validation (load + save)        | `bridge_inspect {config}`                          |
| docs catalog (startup gate)            | `bridge_inspect {docs}`                            |
| list / fetch templates                 | `bridge_inspect {list_templates / fetch_template}` |
| eval-batch (drill-down re-eval)        | `bridge_inspect {eval_batch}`                      |
| live expr validation (per keystroke)   | `bridge_eval_expr`                                 |
| ExprPlayground per-call trace          | `bridge_eval_expr_trace`                           |
| `bxp-cli --trace` (dry-run / full-run) | `bridge_run_streaming`                             |
| `bxp-cli --version` (probe)            | `bridge_run`                                       |

The first six are in-process (no subprocess); the last two proxy the `bxp-cli`
spawn, draining its pipes in native Zig code. Library probe failure at startup is
fatal on every platform.

Implementation: routing decisions live in
[`bxp-gui/lib/services/bxp_process_client.dart`](https://github.com/zaxified/bxp/blob/master/bxp-gui/lib/services/bxp_process_client.dart)
(`_runOneShot`, `_runCliTraceViaBridge`, `traceExpr`). See
[`bxp-gui-bridge/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-gui-bridge/CLAUDE.md) for the C-ABI surface
of each `bridge_*` entry point.

---

## Where to dig deeper (CLAUDE.md map)

`docs/` covers orientation and cross-module flow. The deepest reference for
each module — internal API contracts, design decisions, "known non-issue"
rationales — lives in per-module `CLAUDE.md` files. They're loaded
automatically by Claude Code, but you can read them directly any time.

| Module           | File                                                                              | What's in it                                                                                                                        |
| ---------------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Monorepo         | [`CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/CLAUDE.md)                                                       | Top-level layout + package dep graph + cross-cutting conventions                                                                    |
| `bxp-cli`        | [`bxp-cli/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-cli/CLAUDE.md)                                       | Full config reference, expression syntax, broker list, exit codes, output stream routing                                            |
| `bxp-mcp`        | [`bxp-mcp/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-mcp/CLAUDE.md)                                       | MCP server: adapter model, tool catalog, annotated JSON shape (`$comm_*`/`$err_*`/…), in-proc vs spawn, wire protocol, bxp_simulate |
| `bxp-core`       | [`bxp-core/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-core/CLAUDE.md)                                     | Per-module API surface, build details, "known non-issues" rationale                                                                 |
| `bxp-gui`        | [`bxp-gui/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-gui/CLAUDE.md)                                       | Flutter app structure, services/store/ui split, MCP debug workflow                                                                  |
| `bxp-gui-bridge` | [`bxp-gui-bridge/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-gui-bridge/CLAUDE.md)                         | C-ABI surface, Debug→ReleaseSafe rewrite rationale, Win-mandatory / cross-platform roles                                            |
| `json5_ast`      | [`bxp-gui/packages/json5_ast/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-gui/packages/json5_ast/CLAUDE.md) | Standalone-library-candidate status, comment ownership, future extraction recipe                                                    |
