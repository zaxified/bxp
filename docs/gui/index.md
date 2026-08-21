---
description: "BXP Desktop: what the app adds over the CLI, where it keeps your settings, how it updates itself, and what to do when it misbehaves."
---

# BXP Desktop

The desktop app is the same engine with a config tree editor, a dry-run
debugger and a live expression playground around it. Anything you build in it
runs identically under `bxp-cli` — the app writes the same config file.

- [Features](features.md) — the editor, the per-row trace view, the expression
  playground.
- [Preferences](preferences.md) — theme, recent files, custom places, zoom, and
  where the file lives on each OS.
- [Updates](updates.md) — how the in-app updater finds, verifies and installs a
  release, and how to turn it off.
- [Troubleshooting](troubleshooting.md) — a missing bridge library, a stale
  bundle, a refused update.

An assistant can drive the running app directly through its embedded MCP
server — see [Driving the GUI](../ai/gui-mcp.md).
