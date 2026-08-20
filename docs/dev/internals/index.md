---
description: "Design philosophy, why the FFI bridge exists, and where to dig deeper for each package."
---

# Internals

## Design philosophy

BXP is a **configuration-driven ETL micro-tool**. The core principle is:

> Adding a new data source = writing a JSON5 template. No code, no recompilation.

Consequences of this design:

- All source-specific logic lives in `bxp-cli.json` (`conversion_templates` section).
- `bxp-core` is a generic engine: CSV/XLSX parser, expression evaluator, config loader.
- `bxp-cli` is a thin orchestrator: reads config, finds files, calls the engine.
- The expression language is intentionally limited - it handles per-row transformations, not general-purpose computation.

---

## Package dependency graph

```text
  bxp-cli         ── path dep ──►  bxp-core   ── fetch dep ──►  uucode   (Unicode tables)
  (binary)                         (library)                    regex    (Pike-VM engine)
                                                                zig-libs (12 modules: datefmt · tz ·
                                                                          encoding · json5 · decimal ·
                                                                          numparse · zipstream ·
                                                                          csvstream · diagnostics ·
                                                                          minisign · procrun · mcp)
  bxp-mcp         ── path dep ──►  bxp-core           (wraps inspect.zig; spawns bxp-cli
  (binary)                                             for bxp_simulate; takes `mcp`,
                                                       the JSON-RPC transport, through
                                                       bxp-core's module table)
  bxp-gui-bridge  ── path dep ──►  bxp-core           (imports inspect.zig only — expr
  (.dll/.so/.dylib)                                    comes in transitively; takes
                                                       `minisign` + `procrun` through
                                                       bxp-core's module table)

  bxp-gui  ── FFI ──►  bxp-gui-bridge   (single backend, all platforms:
  (Flutter)                              in-proc inspect + proxied bxp-cli runs)
```

`bxp-core` is a **local path dependency** (`../bxp-core`) and pulls three
external fetch dependencies of its own: `uucode` (Unicode case-mapping tables),
`regex` (`quangd/regex.zig`, the Pike-VM engine behind `REGEX_MATCH`/
`REGEX_EXTRACT`), and `zig_libs` (12 modules — `datefmt`, `tz`, `encoding`,
`json5`, `decimal`, `numparse`, `zipstream`, `csvstream` and `diagnostics`, the
whole primitive layer, plus `minisign`, `procrun` and `mcp`, which bxp-core does
not import at all and merely re-exports so the bridge and bxp-mcp share its
single pin), all pinned in `build.zig.zon`.
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

The stateless work — config validation, the docs catalog, template list and
fetch, drill-down eval-batch, live expression validation and the playground's
per-call trace — runs **in-process** against `bxp-core`. Only the two `bxp-cli`
calls, the `--trace` run and the `--version` probe, are proxied spawns, and even
those drain their pipes in native Zig code. Library probe failure at startup is
fatal on every platform.

Which export serves which call is the generated table on
[Subprocess wiring](../gui/subprocess.md#transport-paths) — one list, held to
the library's real exports by a compile-time check, rather than a second copy
here that could disagree with it.

Implementation: routing decisions live in
[`bxp-gui/lib/services/bxp_process_client.dart`](https://github.com/zaxified/bxp/blob/master/bxp-gui/lib/services/bxp_process_client.dart)
(`_runOneShot`, `_inspect`, `_runWithBtraceViaBridge`). See
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
| `bxp-cli`        | [`bxp-cli/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-cli/CLAUDE.md)                                       | Full config reference, expression syntax, template list, exit codes, output stream routing                                            |
| `bxp-mcp`        | [`bxp-mcp/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-mcp/CLAUDE.md)                                       | MCP server: adapter model, tool catalog, annotated JSON shape (`$err_*`/`$warn_*`/`$info_*`), in-proc vs spawn, wire protocol, bxp_simulate |
| `bxp-core`       | [`bxp-core/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-core/CLAUDE.md)                                     | Per-module API surface, build details, "known non-issues" rationale                                                                 |
| `bxp-gui`        | [`bxp-gui/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-gui/CLAUDE.md)                                       | Flutter app structure, services/store/ui split, MCP debug workflow                                                                  |
| `bxp-gui-bridge` | [`bxp-gui-bridge/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-gui-bridge/CLAUDE.md)                         | C-ABI surface, Debug→ReleaseSafe rewrite rationale, Win-mandatory / cross-platform roles                                            |
| `json5_ast`      | [`bxp-gui/packages/json5_ast/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-gui/packages/json5_ast/CLAUDE.md) | Standalone-library-candidate status, comment ownership, future extraction recipe                                                    |
| `docs/examples`  | [`docs/examples/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/docs/examples/CLAUDE.md)                   | Authoring the example tree: what a sample is for, the closed heading set, the two gates, clickable expressions |
