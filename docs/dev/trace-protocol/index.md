# Trace protocol

Machine-readable output formats emitted by **bxp-cli** (the binary BXTB trace)
and the stateless **inspect** core (config / expression / docs / template JSON,
surfaced through bxp-mcp + the bxp-gui-bridge FFI). Consumed by bxp-gui (via the
bridge) and by `scripts/test.sh`.

Two distinct format families:

- [**BXTB**](bxtb.md) — binary frame stream written to stdout by `bxp-cli --trace`.
  Carries per-row metadata (source locators, errors, pre_pass dump, stats).
- [**Inspect JSON**](inspect.md) — JSON shapes produced by the stateless inspect
  core (`bxp-core/src/inspect.zig`): config annotation, expression validation /
  evaluation / trace, template list/fetch, docs catalog.

---

## Producer / Consumer

| Binary           | Role                                 | Source file                                                                                                        |
| ---------------- | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| `bxp-cli`        | Produces `--trace` BXTB frame stream | [`bxp-cli/src/pipeline.zig`](https://github.com/zaxified/bxp/blob/master/bxp-cli/src/pipeline.zig) — `Output.binEmit*()`                                    |
| `bxp-core`       | BXTB writer / reader                 | [`bxp-core/src/btrace.zig`](https://github.com/zaxified/bxp/blob/master/bxp-core/src/btrace.zig)                                                            |
| `bxp-core`       | All stateless inspect outputs        | [`bxp-core/src/inspect.zig`](https://github.com/zaxified/bxp/blob/master/bxp-core/src/inspect.zig)                                                          |
| `bxp-mcp`        | MCP wrappers over inspect            | [`bxp-mcp/src/tools.zig`](https://github.com/zaxified/bxp/blob/master/bxp-mcp/src/tools.zig)                                                                |
| `bxp-gui-bridge` | FFI wrappers over inspect            | [`bxp-gui-bridge/src/main.zig`](https://github.com/zaxified/bxp/blob/master/bxp-gui-bridge/src/main.zig)                                                    |
| `bxp-core`       | Per-call expr-trace NDJSON           | [`bxp-core/src/expr.zig`](https://github.com/zaxified/bxp/blob/master/bxp-core/src/expr.zig) — `emitCallTrace()`                                            |
| `bxp-core`       | Docs catalog JSON                    | [`bxp-core/src/docs.zig`](https://github.com/zaxified/bxp/blob/master/bxp-core/src/docs.zig) — `writeDocs()`                                                |
| `bxp-gui`        | Consumes the BXTB stream             | [`bxp-gui/lib/store/trace_store.dart`](https://github.com/zaxified/bxp/blob/master/bxp-gui/lib/store/trace_store.dart) — `_streamRunBtrace`                 |
| `bxp-gui`        | Consumes expr-trace NDJSON           | [`bxp-gui/lib/services/bxp_process_client.dart`](https://github.com/zaxified/bxp/blob/master/bxp-gui/lib/services/bxp_process_client.dart) — `traceExpr()`  |
| `bxp-gui`        | Consumes annotated config JSON       | [`bxp-gui/lib/services/bxp_process_client.dart`](https://github.com/zaxified/bxp/blob/master/bxp-gui/lib/services/bxp_process_client.dart) — `loadConfig()` |
| `bxp-gui`        | Consumes the docs catalog            | [`bxp-gui/lib/store/trace_store.dart`](https://github.com/zaxified/bxp/blob/master/bxp-gui/lib/store/trace_store.dart) — `_init()` startup gate             |
| `bxp-gui`        | Event model                          | [`bxp-gui/lib/store/trace_model.dart`](https://github.com/zaxified/bxp/blob/master/bxp-gui/lib/store/trace_model.dart)                                      |
