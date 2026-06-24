# Build & Setup

## VS Code setup

Install these extensions for a productive experience:

| Extension           | ID                                                     | Purpose                                                                     |
| ------------------- | ------------------------------------------------------ | --------------------------------------------------------------------------- |
| **Zig Language**    | `ziglang.vscode-zig`                                   | Zig language, Syntax highlighting, ZLS integration, build tasks             |
| **Rainbow CSV**     | `mechatroner.rainbow-csv`                              | Column-aware CSV viewer - helpful when reading broker exports               |
| **JSON5**           | `blueglassblock.better-json5`                          | Syntax highlighting for `JSON5` config files                                |
| **Mermaid preview** | `bierner.markdown-mermaid`                             | Renders Mermaid diagrams in Markdown preview (useful for `architecture/`) |
| **Mermaid syntax**  | `bpruitt-goddard.mermaid-markdown-syntax-highlighting` | Syntax highlighting for Mermaid diagrams (useful for `architecture/`)     |

**ZLS (Zig Language Server)** and **Zig language** are bundled with the `ziglang.vscode-zig` extension - it provides completions, go-to-definition and inline error diagnostics out of the box.

---

## Verify Zig language version

The required Zig version is pinned in `build.zig.zon` (`minimum_zig_version`) —
install that toolchain; ZLS bundled with the Zig extension matches it.

`bxp-core` has **two external (fetch) dependencies** — `uucode` (MIT), the
Unicode case-mapping tables behind `UPPER`/`LOWER`, and `regex`
(`quangd/regex.zig`, Apache-2.0 OR MIT), the Pike-VM engine behind
`REGEX_MATCH`/`REGEX_EXTRACT` (linear-time, ReDoS-safe). Both are pinned in
`bxp-core/build.zig.zon`. The date and numeric cores stay in-house
(`bxp-core/src/datefmt.zig`, `decimal.zig`). The fetches are cached after the
first build; CI runners have network.

In VS Code terminal:

```bash
zig version   # must satisfy build.zig.zon's minimum_zig_version
```

---

## Claude Code setup

BXP development in Zig works seamlessly with [Claude Code](https://claude.ai/code).
The monorepo ships seven `CLAUDE.md` files — root, `bxp-cli/`, `bxp-core/`,
`bxp-mcp/`, `bxp-gui/`, `bxp-gui-bridge/`, and `bxp-gui/packages/json5_ast/` —
Claude loads these automatically and reads project conventions.

### Skills to use

Install the `zig` API-reference skill from <https://github.com/nzrsky/zig-skills> (targets Zig 0.16.0).

| Skill        | When to use                                                     |
| ------------ | --------------------------------------------------------------- |
| `/zig`       | Before writing any new Zig code - loads Zig 0.16.0 API patterns |
| `/zig-build` | Compile the project and get structured error analysis           |
| `/zig-check` | Fast syntax/type check without full build                       |
| `/zig-test`  | Run the test suite and analyze failures                         |

---

## Repository layout

```diagram
bxp/                            # monorepo root (git root)
├── bxp-cli/                    # user-facing CLI binary
│   ├── src/
│   │   ├── main.zig            # arg parsing, config loading, dispatch
│   │   └── pipeline.zig        # processBroker(), xlsxPrePass(), Output, SectionStats
│   ├── build.zig               # imports bxp-core modules by name
│   └── build.zig.zon           # depends on bxp-core (path dep)
├── bxp-mcp/                    # MCP server (JSON-RPC over stdio) for AI agents
│   ├── src/
│   │   ├── main.zig            # entry: arena + --help + server.run()
│   │   ├── server.zig          # MCP stdio loop + JSON-RPC writers
│   │   ├── tools.zig           # tool catalog → bxp-core/inspect calls
│   │   └── sim.zig             # bxp_simulate: stage + spawn bxp-cli + diff
│   ├── build.zig
│   └── build.zig.zon           # depends on bxp-core (path dep)
├── bxp-core/                   # internal shared library (no binary)
│   ├── src/
│   │   ├── csv.zig             # RFC 4180 CSV parser
│   │   ├── xlsx.zig            # .xlsx → CSV (ZIP+XML)
│   │   ├── expr.zig            # expression evaluator + FnDoc catalog
│   │   ├── datefmt.zig         # in-house date parse/format + civil arithmetic (DATE_CONVERT core)
│   │   ├── unicode.zig         # UTF-8 case mapping (UPPER/LOWER) over uucode tables
│   │   ├── config.zig          # JSON5 config loader + FieldDoc tables
│   │   ├── json.zig            # JSON array-of-objects → row representation
│   │   ├── json5.zig           # JSON5 preprocessor (comments, unquoted keys, ...)
│   │   ├── docs.zig            # --docs aggregator: re-exports expr + config catalogs
│   │   └── diagnostics.zig     # structured validation collector (Severity, Diagnostic)
│   ├── build.zig               # exports named Zig modules
│   └── build.zig.zon           # two fetch deps: uucode (tables) + regex (Pike-VM)
├── bxp-gui/                    # Flutter desktop app (Linux / macOS / Windows)
│   ├── lib/
│   │   ├── main.dart           # Flutter entry; window + theme + provider wiring
│   │   ├── services/           # subprocess + FFI wrappers, AST loader, prefs, updater
│   │   ├── store/              # TraceStore ChangeNotifier + trace data models
│   │   └── ui/                 # widgets: tree editor, expr panel, row debugger, …
│   ├── packages/json5_ast/     # standalone Dart JSON5 AST library (path dep)
│   ├── linux/, macos/, windows/ # per-platform Flutter shells
│   └── pubspec.yaml
├── bxp-gui-bridge/             # Zig FFI shared library — single GUI backend (all platforms)
│   ├── src/main.zig            # in-proc inspect/eval + bxp-cli run proxy
│   ├── test/test_helper.zig    # bridge_run / bridge_run_streaming /
│   ├── build.zig               # bridge_eval_expr* C-ABI surface
│   └── build.zig.zon           # depends on bxp-core (path dep)
├── datasets/                   # anonymized sample data + expected outputs
│   └── <template_id>/
│       ├── sample.csv / .xlsx  # input file
│       ├── sample.json         # bxp-cli config for this dataset
│       └── sample.expected     # expected .csvx output (regression baseline)
├── docs/
│   ├── README.md               # docs index + reading order
│   ├── dev/build.md            # this file — setup + build + test entry point
│   ├── dev/testing.md          # test phases, corpus, regression fixture guide
│   ├── dev/debugging.md        # debug flags, expression inspection, live GUI debug
│   ├── dev/internals.md        # design philosophy, module contracts, extensibility
│   ├── dev/architecture/       # bird's-eye view + data-flow diagrams
│   │   ├── index.md            #   topology overview
│   │   ├── pipeline.md         #   CLI execution + expression evaluator
│   │   ├── gui.md              #   GUI layers, dry-run, config editing, updater
│   │   └── data-structures.md  #   Zig struct reference
│   ├── dev/gui/                # bxp-gui developer guide
│   ├── dev/mcp.md              # bxp-mcp MCP server guide
│   ├── dev/release.md          # release process walkthrough
│   ├── dev/roadmap.md          # forward-looking milestones
│   └── dev/trace-protocol.md  # bxp-cli --trace BXTB + inspect output formats
├── resources/
│   ├── console/                # bxp-cli sample config + readme (bundled in console archives)
│   ├── desktop/                # bxp-gui.desktop template + readme (bundled in desktop archives)
│   └── icons/                  # SVG variants + build-icons.sh (single source for app icons)
├── scripts/
│   ├── test.sh                 # wrapper: runs every test-NN-*.sh in numeric order
│   ├── test-lib.sh             # shared section/step/summary helpers (sourced)
│   ├── test-01-console.sh      # bxp-core unit (incl. inspect) + bxp-cli build + readme src-sync + json5_ast unit
│   ├── test-02-mcp.sh          # bxp-mcp build + unit tests + JSON-RPC smoke (incl. bxp_simulate)
│   ├── test-03-bridge.sh       # bxp-gui-bridge build + unit tests
│   ├── test-04-desktop.sh      # flutter analyze + flutter test + json5_ast dart test (builds bridge .so)
│   ├── test-05-bench-guard.sh  # coarse perf gate: recycles Console's ReleaseSafe bxp-cli
│   ├── test-06-expr-corpus.sh  # cross-runner expression corpus regression gate
│   ├── test-07-datasets.sh     # bxp-cli regression vs datasets/*/*.expected
│   ├── release.sh              # wrapper: release-01-console.sh + release-02-desktop.sh
│   ├── release-01-console.sh   # cross-compile bxp-cli → bxp-console-* archives
│   ├── release-02-desktop.sh   # Flutter bundle → AppImage / .deb / .exe / .dmg
│   ├── release-03-checksums.sh # emit SHA256SUMS for all release artifacts
│   ├── release-changelog.sh    # bump versions + generate CHANGELOG.md entry + commit
│   ├── release-tag.sh          # read version from manifest + tag + push
│   └── check-formatting.sh     # prettier --write + markdownlint + mermaid (pre-release; not auto-run)
└── README.md                   # project overview
```

---

## Clone and build

```bash
# Clone this repository
git clone https://github.com/zaxified/bxp.git

# Build bxp-cli (fetches dependencies on first run)
cd ./bxp/bxp-cli
zig build

# Run
./zig-out/bin/bxp-cli --help
```

Running `bxp-cli` without arguments processes every template defined in `bxp-cli.json`
in the current working directory. \
The typical dev workflow:

```bash
# From the monorepo root
./bxp-cli/zig-out/bin/bxp-cli --config ./datasets/anycoin_to_wealthfolio/sample.json --debug
```

---

## Run the test suite

```bash
# From the monorepo root — runs unit tests + all regression tests
bash scripts/test.sh
```

Seven phases covering Zig unit tests, MCP smoke, bridge, Flutter, perf guard,
expression corpus, and dataset regression. See [Testing](testing.md) for the
full phase breakdown, individual sub-suite commands, and how to add regression
tests.
