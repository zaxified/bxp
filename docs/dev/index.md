---
description: "Developer documentation: build the monorepo, run the suite, debug a conversion, and find the deeper architecture and internals notes."
---

# Developer documentation

Everything needed to work *on* BXP rather than with it. Start with
[Build](build.md) — toolchain, repository layout, one command per package —
then pick the page for what you are doing.

## Working in the repo

- [Build](build.md) — toolchain setup and how to build each package.
- [Testing](testing.md) — the suite's phases, running one alone, adding a
  regression or an expression-corpus case.
- [Debugging](debugging.md) — which flags to combine, inspecting an
  expression, driving the live GUI from an agent.
- [Release](release.md) — version bump, changelog, tag, and what CI builds per
  platform.
- [Roadmap](roadmap.md) — planned work by version, and what is deliberately not
  planned.

## How it works

- [Architecture](architecture/index.md) — the bird's-eye topology, the
  conversion pipeline, the GUI, the live data structures.
- [Internals](internals/index.md) — design philosophy, the module inventory,
  implementation notes, performance.
- [GUI internals](gui/index.md) — the Flutter app's setup, architecture,
  subprocess wiring and patterns.
- [MCP server](mcp.md) — the `bxp-mcp` tool catalog and wire protocol.
- [Trace protocol](trace-protocol/index.md) — the binary BXTB stream behind
  `--trace`, and the shared inspect surface.
