# docs/

Developer documentation for the BXP monorepo.

## New here? Read in this order

1. [`devel.md`](devel.md) — repo layout, build, test suite, design philosophy.
2. [`architecture.md`](architecture.md) — visual data-flow diagrams (skim).
3. [`gui.md`](gui.md) — only if you're touching Flutter.
4. [`mcp.md`](mcp.md) — only if you're touching the MCP server (agent tools).
5. Module-level [`CLAUDE.md`](../CLAUDE.md) files — deepest reference, one per
   module (`bxp-cli/CLAUDE.md`, `bxp-core/CLAUDE.md`, `bxp-mcp/CLAUDE.md`,
   `bxp-gui/CLAUDE.md`, `bxp-gui-bridge/CLAUDE.md`,
   `bxp-gui/packages/json5_ast/CLAUDE.md`, `examples/CLAUDE.md`). Loaded
   automatically by Claude Code, read directly when you need internal-API detail.

**End-user documentation** (bundled with releases, not for new devs):

- [`resources/console/readme.md`](../resources/console/readme.md) — bxp-cli user guide (config syntax, expression reference, broker list)
- [`resources/desktop/readme.md`](../resources/desktop/readme.md) — bxp-gui user guide (installation, first run, update process)

---

| File                                   | Contents                                                                                                                                                                          |
| -------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [devel.md](devel.md)                   | **Start here.** VS Code setup, clone + build, test suite, architecture narrative, how to add templates and built-in functions, release overview.                                  |
| [architecture.md](architecture.md)     | Mermaid diagrams: bird's-eye view, bxp-cli execution + pipeline + pre_pass + expression evaluator, bxp-gui layers + dry-run flow + config AST + expr playground, data structures. |
| [gui.md](gui.md)                       | bxp-gui Flutter app: source layout, subprocess wiring, json5_ast AST library, TraceStore state management, dev-run workflow, key patterns.                                        |
| [mcp.md](mcp.md)                       | bxp-mcp MCP server: adapter model over the shared `inspect` core, tool catalog, in-proc vs spawn, wire protocol (isError/structuredContent/progress), bxp_simulate.               |
| [release.md](release.md)               | Full release operator guide: what GH Actions builds, local smoke tests, verifying a published release, troubleshooting, signing status.                                           |
| [roadmap.md](roadmap.md)               | Forward-looking milestones by version. Shipped items move to `CHANGELOG.md`.                                                                                                      |
| [trace-protokol.md](trace-protokol.md) | Full subprocess protocol reference: `bxp-cli --trace` BXTB binary frame stream (the sole subprocess protocol since the GUI moved stateless ops in-process).                       |
