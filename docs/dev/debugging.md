---
description: "Debug a conversion: the flags worth combining, expression inspection, and driving the live GUI from an agent."
---

# Debugging

## Debugging workflow

**bxp-cli run + debug flags.** They are
catalogued once, in [CLI flags](../reference/cli-flags.md) — which is also
what `bxp-cli --help` prints, so the two cannot disagree.

The combinations worth knowing:

- `--trace` forces `--quiet` and refuses to run beside `--debug`; the BXTB
  stream on stdout is what `bxp-gui`'s dry-run debugger consumes.
- `--trace-file` is independent of `--trace` — a sidecar for offline
  drill-down, so you can have a human-readable run *and* a full trace.
- `--debug=json` replaces the human output rather than adding to it, and
  conflicts with `--trace` / `--quiet` / `--debug`. It is the shape to reach
  for in CI or from an agent.
- `--dry-run` is independent of all of them: full pipeline, no files written.

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
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"bxp_eval_trace","arguments":{"expr":"[Price] * [Qty]","headers":["Price","Qty"],"fields":["12.50","100"]}}}' \
  | ./bxp-mcp/zig-out/bin/bxp-mcp
```

**bxp-gui live debug (Claude Code MCP loop):** see [`gui/setup.md`](gui/setup.md#debugging-with-print)
for the `mcp__dart__launch_app` → `hot_reload` → `get_app_logs` cycle. Quick
tip: `print()` from Dart is captured; `developer.log()` is not.

**Settings inspector (Ctrl+Shift+S in bxp-gui):** opens an internal-state
drawer showing the loaded config, parsed AST, schema docs, op log, and
validation errors. The fastest way to confirm "is the GUI seeing what I
think it's seeing?".

