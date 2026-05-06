# docs/

Developer documentation for the BXP monorepo.

**End-user documentation** (bundled with releases):

- [`resources/console/readme.md`](../resources/console/readme.md) — bxp-cli user guide (config syntax, expression reference, broker list)
- [`resources/desktop/readme.md`](../resources/desktop/readme.md) — bxp-gui user guide (installation, first run, update process)

---

| File | Contents |
| -- | -- |
| [devel.md](devel.md) | **Start here.** VS Code setup, clone + build, test suite, architecture narrative, how to add templates and built-in functions, release overview. |
| [architecture.md](architecture.md) | Mermaid diagrams: bird's-eye view, bxp-cli execution + pipeline + pre_pass + expression evaluator, bxp-gui layers + dry-run flow + config AST + expr playground, data structures. |
| [gui.md](gui.md) | bxp-gui Flutter app: source layout, subprocess wiring, json5_ast AST library, TraceStore state management, dev-run workflow, key patterns. |
| [release.md](release.md) | Full release operator guide: what GH Actions builds, local smoke tests, verifying a published release, troubleshooting, signing status. |
| [roadmap.md](roadmap.md) | Forward-looking milestones by version. Shipped items move to `CHANGELOG.md`. |
| [trace-protokol.md](trace-protokol.md) | Full subprocess protocol reference: `bxp-cli --trace` NDJSON event stream + all `bxp-fmt` subcommand output formats (`--expr`, `--expr-trace`, `--config`, `--docs`). |
