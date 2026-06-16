# CLAUDE.md — BXP monorepo

Guidance for Claude Code when working with this repository.

## Repository layout

```text
bxp/
├── bxp-cli/              # CLI batch tool (main user-facing binary)
│   ├── src/
│   │   ├── main.zig      # CLI layer: arg parsing, config loading, dispatch
│   │   └── pipeline.zig  # Processing: processBroker(), zipPrePass() (parallel), xlsxPrePass()
│   ├── build.zig
│   └── build.zig.zon     # depends on bxp-core (path dep)
├── bxp-mcp/              # MCP server (JSON-RPC 2.0 over stdio): exposes bxp as
│   │                     # agent-callable tools. Stateless tools call bxp-core
│   │                     # inspect in-process; bxp_simulate spawns co-located bxp-cli.
│   ├── src/main.zig      # entry: arena + --help + server.run()
│   ├── src/server.zig    # MCP stdio loop + JSON-RPC writers (per-request arena)
│   ├── src/tools.zig     # tool catalog + handlers
│   ├── src/sim.zig       # bxp_simulate orchestration (stage + spawn bxp-cli + diff)
│   ├── build.zig
│   └── build.zig.zon     # depends on bxp-core (path dep)
├── bxp-core/             # Internal Zig library (shared modules)
│   ├── src/
│   │   ├── csv.zig         # RFC 4180 CSV parser + splitFields + LineIterator
│   │   ├── xlsx.zig        # .xlsx → CSV converter (streaming ZIP+XML via zipstream)
│   │   ├── zipstream.zig   # Streaming ZIP reader (central-dir walk + per-entry
│   │   │                   # inflate); shared by xlsx ingest + bxp-cli zipPrePass
│   │   ├── expr.zig        # Expression evaluator + per-builtin FnDoc catalog
│   │   ├── config.zig      # JSON5 config loader + per-struct FieldDoc tables
│   │   ├── json.zig        # JSON array-of-objects → CSV rows
│   │   ├── datefmt.zig     # In-house date core (parse/format/arith) — file-rel
│   │   │                   # @import by expr.zig, replaced the sunrise dep
│   │   ├── decimal.zig     # Fixed-point i128 @ 1e12 numeric core (named module)
│   │   ├── unicode.zig     # UTF-8 case mapping (UPPER/LOWER) over uucode tables
│   │   │                   # — file-rel @import by expr.zig; uucode is fetch dep
│   │   ├── encoding.zig    # Layer 0: single-byte code page ↔ UTF-8 transcode
│   │   │                   # (Win-1250/1252, Latin-1/2/9); in-house 256-entry
│   │   │                   # tables, no uucode. Named module: expr (per-field
│   │   │                   # decode) + config (csv_*_encoding parse)
│   │   ├── btrace.zig      # Binary BXTB trace Writer/Reader for --trace
│   │   ├── json5.zig       # JSON5 preprocessor (comments, unquoted keys, ...)
│   │   ├── docs.zig        # Aggregator: re-exports expr catalog + flattens
│   │   │                   # config FieldDoc tables; serves the docs catalog
│   │   ├── diagnostics.zig # Structured Diagnostic / Severity collector for
│   │   │                   # config deep validation
│   │   └── inspect.zig     # Shared stateless core (validate/validate-expr/eval/
│   │                       # eval-batch/eval-trace/docs/templates introspection);
│   │                       # one source for bxp-mcp + bxp-gui-bridge
│   ├── build.zig         # exports each file as a named Zig module
│   └── build.zig.zon     # one fetch dep: uucode (Unicode tables); date/decimal cores in-house
├── bxp-gui/              # Flutter desktop app (replaces bxp-ui; talks to bxp-gui-bridge via FFI, which proxies bxp-cli)
│   ├── lib/              # Dart source (services/, store/, ui/)
│   ├── linux/, macos/, windows/, web/  # platform configs
│   ├── packages/json5_ast/             # Path-dep Dart JSON5 AST library
│   │                                    # (post-Phase-5e CST replacement; not bxp-specific —
│   │                                    # candidate for extraction to a standalone repo when
│   │                                    # a second Dart consumer materialises)
│   └── pubspec.yaml
├── bxp-gui-bridge/       # Zig FFI shared library (bxp-gui-bridge.dll on Windows,
│   │                     # libbxp-gui-bridge.{so,dylib} on Linux/macOS). Built +
│   │                     # shipped on ALL platforms (release-02 + Linux CMake copy
│   │                     # it next to bxp-gui). Since v0.3.0 (2026-06-09) the GUI's
│   │                     # SINGLE backend on every platform — no validator spawn, no
│   │                     # Process.start. In-proc bridge_eval_expr(_trace) +
│   │                     # bridge_inspect (docs/config/list/fetch/eval-batch) serve
│   │                     # the stateless ops from bxp-core/inspect; bridge_run(_streaming)
│   │                     # proxies bxp-cli runs (sidesteps dart:io pipe truncation,
│   │                     # sdk#1727). Missing library = fatal startup (all platforms).
│   ├── src/main.zig      # C-ABI entrypoints: bridge_run, bridge_run_streaming,
│   │                     # bridge_free, bridge_eval_expr(_trace), bridge_inspect
│   ├── build.zig
│   └── build.zig.zon
├── resources/
│   ├── readme.src.md     # SINGLE source for both shipped readmes; GUI-ONLY/CLI-ONLY
│   │                     # block markers generate console + desktop variants via
│   │                     # scripts/gen-readme.sh (do not edit the generated copies)
│   ├── console/          # bxp-cli sample config + generated console readme.md (console archives)
│   ├── desktop/          # bxp-gui.desktop template + generated desktop readme.md (desktop archives)
│   └── icons/            # 4 SVG variants + build-icons.sh — single source for app icons.
│                         #   sand-80 = primary (rendered into bxp-gui/{linux,macos,windows}/...
│                         #   for compile-time embed); all 4 PNGs ship in archive's icons/
│                         #   for user-side shortcut icon swap.
├── datasets/             # Anonymized sample data + expected outputs for regression tests
├── examples/             # Runnable teaching + real-world demos (tiered: basic /
│                         # intermediate / advanced + real-world). Docs/demo
│                         # material, NOT a test gate — see examples/CLAUDE.md.
├── scripts/
│   ├── test.sh           # Wrapper — runs every test-NN-*.sh in numeric order.
│   │                     # Whole suite is ONE optimize mode (ReleaseSafe) to
│   │                     # minimise the codegen/safety error surface; ship is the
│   │                     # only exception (ReleaseSmall, release-01).
│   ├── test-lib.sh       # Shared section/step/summary helpers (sourced)
│   ├── test-01-console.sh    # bxp-core unit (incl. inspect) + bxp-cli build + readme src-sync + json5_ast unit
│   ├── test-02-mcp.sh        # bxp-mcp build + unit tests + JSON-RPC smoke (incl. bxp_simulate)
│   ├── test-03-bridge.sh     # bxp-gui-bridge build + unit tests
│   ├── test-04-desktop.sh    # flutter analyze + flutter test + json5_ast dart test (builds bridge .so)
│   ├── test-05-bench-guard.sh    # coarse perf gate: recycles Console's ReleaseSafe
│   │                             # bxp-cli (cache hit), RSS ceiling + wall scaling-ratio
│   │                             # (catches O(N) RSS + O(n^2) regressions; no absolute
│   │                             # wall thresholds)
│   ├── test-06-expr-corpus.sh    # cross-runner expression corpus regression gate
│   ├── test-07-datasets.sh   # bxp-cli regression vs datasets/*/*.expected
│   ├── release.sh            # Wrapper — runs release-01-console.sh + release-02-desktop.sh
│   ├── release-01-console.sh    # Cross-compile bxp-cli + bxp-mcp, package bxp-console-* archives
│   ├── release-02-desktop.sh    # Host-OS-specific Flutter desktop bundle → .AppImage / .deb
│   │                            # / .tar.gz / NSIS .exe / DMG (matrixed by GH Actions)
│   ├── release-03-checksums.sh  # Emit SHA256SUMS for every release artifact
│   ├── release-changelog.sh     # Extract per-tag section from CHANGELOG.md for release notes
│   ├── release-tag.sh           # Push a vX.Y.Z tag and trigger the release workflow
│   ├── gen-readme.sh            # Generate resources/{console,desktop}/readme.md from the
│   │                            # single source resources/readme.src.md (GUI-ONLY/CLI-ONLY
│   │                            # block markers); `--check` drift guard wired into test-01
│   └── check-formatting.sh      # prettier --write + markdownlint + mermaid; PRE-RELEASE
│                                # docs fix/lint — deliberately NOT a test-NN phase
│                                # (test.sh does not auto-run it)
├── docs/                 # Developer + user documentation
│   ├── README.md             # Index / table of contents
│   ├── architecture.md       # System architecture + module diagrams
│   ├── devel.md              # Developer setup, build, debug guide
│   ├── gui.md                # bxp-gui user-facing guide
│   ├── mcp.md                # bxp-mcp MCP server guide
│   ├── release.md            # Release operator walkthrough
│   ├── roadmap.md            # Long-term backlog mirrored to memory
│   ├── trace-protokol.md     # Subprocess protocol reference: binary BXTB --trace stream
│   └── demo.gif              # README hero asset
├── .github/workflows/
│   └── release.yml       # Multi-host release pipeline triggered by `v*` tag push
├── DEV/                  # Developer scratch space — sample data, in-flight plans, AST prototypes
├── CLAUDE.md             # This file
├── LICENSE.md            # Apache 2.0
└── README.md             # Project overview
```

## Build & test

```bash
# Full test suite (console + desktop):
bash scripts/test.sh

# Just console-side (no Flutter dep):
bash scripts/test-01-console.sh

# Build bxp-cli:
cd bxp-cli && zig build

# Run bxp-cli:
cd bxp-cli && ./zig-out/bin/bxp-cli --help

# Unit tests (bxp-core modules):
cd bxp-core && zig build test
```

## Release

Two channels, distinct archives:

- **bxp-console** — `bxp-console-<ver>-<platform>.{tar.gz,zip}` — bxp-cli +
  bxp-mcp (co-located so bxp-mcp's `bxp_simulate` can spawn bxp-cli).
- **bxp-desktop** — `bxp-desktop-<ver>-<platform>.{tar.gz,AppImage,deb,exe,dmg}` — Flutter GUI + bundled bxp-cli + bxp-mcp + bxp-gui-bridge.

Cut a release by pushing a `v*` tag; `.github/workflows/release.yml`
fans out to ubuntu / windows / macos runners, each producing its native
artifacts, and a final aggregator job uploads everything to a GitHub
Release alongside `SHA256SUMS`. The Phase 2 in-app updater
(`bxp-gui/lib/services/updater_service.dart`) verifies downloads against
that file. See `docs/release.md` for the operator walkthrough.

## Package dependency

```text
bxp-cli         --[path dep]--> bxp-core   --[fetch dep]--> uucode (Unicode tables)
bxp-mcp         --[path dep]--> bxp-core    --[subprocess]-> bxp-cli (bxp_simulate only)
bxp-gui-bridge  --[path dep]--> bxp-core    (bridge_inspect / bridge_eval_* in-proc)
bxp-gui         --[FFI]------> bxp-gui-bridge --[subprocess]-> bxp-cli (dry-run/version)
```

The stateless inspection surface (config / expression validation, docs,
templates, eval-batch) lives once in `bxp-core/src/inspect.zig` and is wrapped
by two thin adapters: `bxp-mcp` (MCP/stdio for agents) and `bxp-gui-bridge`
(FFI for the Dart GUI). The GUI talks only to `bxp-gui-bridge` on every platform
since the v0.3.0 proxy flip — stateless ops run in-process via the bridge's
bxp-core/inspect link, and the bridge proxies `bxp-cli` runs. The former
`bxp-fmt` CLI adapter was removed once both wrappers covered every operation.

`bxp-core` is a local path dependency (`../bxp-core`) with a **single external
dependency**: `uucode` (MIT), the field-selected Unicode case-mapping /
decomposition tables behind `UPPER`/`LOWER` (and the upcoming `unaccent`),
pinned to its `main` line in `bxp-core/build.zig.zon`. The date core
(`datefmt.zig`) and numeric core (`decimal.zig`) remain fully in-house — the
former `sunrise` datetime dependency was replaced by `datefmt.zig`.
bxp-gui ships `bxp-cli` + the `bxp-gui-bridge` library inside the Flutter
bundle. It talks to the bridge over FFI (stateless validation / docs / expr
eval in-process; `bxp-cli` conversions proxied through it) — there is no
separate validator binary (the v0.3.0 proxy flip, 2026-06-09).

## bxp-gui user prefs

bxp-gui persists user state (theme, recent files, custom places, zoom)
to a visible JSON file at a canonical OS path:

- Linux: `~/.local/share/bxp-gui/bxp-gui.json`
- macOS: `~/Library/Application Support/bxp-gui/bxp-gui.json`
- Windows: `%APPDATA%\bxp-gui\bxp-gui.json`

The file is auto-created on first write. Implementation: `bxp-gui/lib/
services/prefs_service.dart`.

## Coding conventions

- All code comments and documentation in English
- Zig 0.16.0 API — use zig skill before writing new code
- User-facing error messages use `std.process.exit(1)` (no Zig stack trace)

## Detailed documentation

- [`bxp-cli/CLAUDE.md`](bxp-cli/CLAUDE.md) — full configuration reference, expression syntax,
  template guide, broker list.
- [`bxp-mcp/CLAUDE.md`](bxp-mcp/CLAUDE.md) — MCP server: tool catalog (incl. the
  `$comm_*`/`$err_*`/`$warn_*`/`$info_*` annotated-JSON shape), wire protocol,
  the shared `inspect` core, `bxp_simulate` spawn design.
- [`bxp-core/CLAUDE.md`](bxp-core/CLAUDE.md) — module API overview, build details, test coverage.
- [`bxp-gui/CLAUDE.md`](bxp-gui/CLAUDE.md) — Flutter app structure, services/store/ui split,
  bxp-cli subprocess + bxp-gui-bridge FFI wiring.
- [`bxp-gui-bridge/CLAUDE.md`](bxp-gui-bridge/CLAUDE.md) — Zig FFI shared library;
  C-ABI surface, Debug→ReleaseSafe rewrite rationale, platform role.
- [`bxp-gui/packages/json5_ast/CLAUDE.md`](bxp-gui/packages/json5_ast/CLAUDE.md) — standalone
  Dart JSON5 AST library; parser, dumper, mutation API.
- [`examples/CLAUDE.md`](examples/CLAUDE.md) — authoring conventions for the
  teaching + real-world example tree (tiers, dir layout, readme structure,
  generated index).

## CLAUDE.md files

New CLAUDE.md files may be created anywhere inside `bxp/` as needed.
Existing files: `bxp/CLAUDE.md` (this file), `bxp/bxp-cli/CLAUDE.md`,
`bxp/bxp-core/CLAUDE.md`, `bxp/bxp-mcp/CLAUDE.md`,
`bxp/bxp-gui/CLAUDE.md`, `bxp/bxp-gui-bridge/CLAUDE.md`,
`bxp/bxp-gui/packages/json5_ast/CLAUDE.md`, `bxp/examples/CLAUDE.md`.

## Git & GitHub

Monorepo git is initialized at `bxp/` root.
