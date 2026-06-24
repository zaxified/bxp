# Debugging

## Debugging workflow

**bxp-cli run + debug flags** — composable, all on the same binary (value-taking
flags accept `--name value` or `--name=value`):

| Flag                  | What it does                                                                                                                                                                                                 |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `--debug`             | Prints unmatched rows when `row_rules_debug_missing: true`                                                                                                                                                   |
| `--debug=json`        | Emits ONE machine-readable JSON run summary on stdout (per-template + overall counts + captured warnings/errors) instead of human output — for CI / agents. Conflicts with `--trace` / `--quiet` / `--debug` |
| `--quiet`             | Suppresses per-template summaries (exit code still reflects result)                                                                                                                                          |
| `--dry-run`           | Runs the full pipeline in memory but writes no output files (preview / validation); independent of `--trace`                                                                                                 |
| `--trace`             | Emits BXTB frame stream on stdout (consumed by `bxp-gui`'s dry-run debugger). Implies `--quiet`                                                                                                              |
| `--trace-file=<path>` | Mirrors the full BXTB trace to a file, independent of `--trace` (sidecar for offline drill-down)                                                                                                             |
| `--check-fs=N`        | Adds filesystem-existence checks (templates' `data_dir`, etc.) with N-second timeout                                                                                                                         |

**Inspecting an expression in isolation** (via the `bxp-mcp` server — one
JSON-RPC object per line on stdin):

```bash
# Validate one expression (authoring-time check; no row context)
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"bxp_validate_expr","arguments":{"expr":"IF([Qty] > 0, '\''BUY'\'', '\''SELL'\'')"}}}' \
  | ./bxp-mcp/zig-out/bin/bxp-mcp

# Trace per-call values against a fake row (bxp_eval_trace)
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"bxp_eval_trace","arguments":{"expr":"[Price] * [Qty]","headers":"[\"Price\",\"Qty\"]","fields":"[\"12.50\",\"100\"]"}}}' \
  | ./bxp-mcp/zig-out/bin/bxp-mcp
```

**bxp-gui live debug (Claude Code MCP loop):** see [`gui/setup.md`](gui/setup.md#debugging-with-print)
for the `mcp__dart__launch_app` → `hot_reload` → `get_app_logs` cycle. Quick
tip: `print()` from Dart is captured; `developer.log()` is not.

**Settings inspector (Ctrl+Shift+S in bxp-gui):** opens an internal-state
drawer showing the loaded config, parsed AST, schema docs, op log, and
validation errors. The fastest way to confirm "is the GUI seeing what I
think it's seeing?".

