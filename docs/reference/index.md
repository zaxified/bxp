---
description: "Generated reference tables: every expression function, config key, CLI flag, exit code and agent-callable tool."
---

# Reference

Look-up tables, not prose — every page here is generated from the catalogs in
the source, so what it lists is what the shipped binary actually accepts. The
[Guide](../guide/index.md) explains when to reach for each of them.

## The template language

- [Expression functions](expr-functions.md) — every built-in, grouped by
  purpose, with arguments and behaviour.
- [Date tokens](date-tokens.md) — what `DATE_CONVERT` accepts on either side.
- [Config schema](config-schema.md) — every key: type, required, default,
  allowed values.
- [Built-in templates](built-in-templates.md) — the templates shipped next to
  the binary.

## Running the tools

- [CLI flags](cli-flags.md) — every `bxp-cli` flag and its argument.
- [Exit codes](exit-codes.md) — what each process exit code means.
- [Environment variables](environment.md) — optional startup overrides; BXP
  works with none of them set.

## Agent and GUI surfaces

- [MCP tools](mcp-tools.md) — the `bxp-mcp` stdio catalog.
- [GUI agent tools](gui-agent-tools.md) — what the running app exposes over
  localhost.
- [GUI shortcuts](gui-shortcuts.md) and [GUI preferences](gui-prefs.md).
