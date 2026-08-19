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
│   │                     # Transport = zig-libs `mcp` (which IS this package's
│   │                     # former server.zig, extracted upstream and hardened).
│   ├── src/main.zig      # entry: arena + --help + register + mcp.serveStdio
│   ├── src/tools.zig     # tool catalog + handlers + register()
│   ├── src/sim.zig       # bxp_simulate orchestration (stage + spawn bxp-cli + diff)
│   ├── build.zig
│   └── build.zig.zon     # depends on bxp-core (path dep)
├── bxp-core/             # Internal Zig library (shared modules)
│   ├── src/
│   │   ├── xlsx.zig        # .xlsx → CSV converter (streaming ZIP+XML via zipstream)
│   │   ├── expr.zig        # Expression evaluator + per-builtin FnDoc catalog
│   │   ├── config.zig      # JSON5 config loader + per-struct FieldDoc tables
│   │   ├── json.zig        # JSON array-of-objects → CSV rows
│   │   ├── unicode.zig     # UTF-8 case mapping (UPPER/LOWER) over uucode tables
│   │   │                   # — file-rel @import by expr.zig; uucode is fetch dep
│   │   ├── btrace.zig      # Binary BXTB trace Writer/Reader for --trace
│   │   ├── docs.zig        # Aggregator: re-exports expr catalog + flattens
│   │   │                   # config FieldDoc tables; serves the docs catalog
│   │   ├── wasm.zig        # wasm32 export wrapper (bxp_eval_batch / bxp_docs) —
│   │   │                   # the docs expression scratchpad's engine; opt-in
│   │   │                   # `zig build wasm`, never part of `install`
│   │   └── inspect.zig     # Shared stateless core (validate/validate-expr/eval/
│   │                       # eval-batch/eval-trace/docs/templates introspection);
│   │                       # one source for bxp-mcp + bxp-gui-bridge
│   │                       # (`datefmt`, `tz`, `encoding`, `json5`, `decimal`,
│   │                       # `zipstream`, `diagnostics`, `numparse` and
│   │                       # `csvstream` are NOT here — the whole primitive
│   │                       # layer comes from zig-libs)
│   ├── build.zig         # exports each file as a named Zig module
│   └── build.zig.zon     # fetch deps: uucode, regex, zig-libs (12 modules —
│                         #             the whole primitive layer)
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
│   ├── readme.md         # SINGLE hand-maintained readme shipped verbatim in BOTH
│   │                     # console + desktop archives; desktop-only sections carry a
│   │                     # *(desktop only)* heading annotation (no more block-marker gen)
│   ├── console/          # bxp-cli sample config (bxp-cli.examples.json) — console archives
│   ├── desktop/          # bxp-gui.desktop launcher template — desktop archives
│   └── icons/            # 4 SVG variants + build-icons.sh — single source for app icons.
│                         #   sand-80 = primary (rendered into bxp-gui/{linux,macos,windows}/...
│                         #   for compile-time embed); all 4 PNGs ship in archive's icons/
│                         #   for user-side shortcut icon swap.
├── datasets/             # Anonymized sample data + expected outputs for regression tests
├── scripts/
│   ├── test.sh           # Wrapper — runs every test-NN-*.sh in numeric order.
│   │                     # Whole suite is ONE optimize mode (ReleaseSafe) to
│   │                     # minimise the codegen/safety error surface; ship is the
│   │                     # only exception (ReleaseSmall, release-01).
│   ├── test-lib.sh       # Shared section/step/summary helpers (sourced)
│   ├── test-01-console.sh    # bxp-core unit (incl. inspect) + bxp-cli build + json5_ast unit
│   ├── test-02-mcp.sh        # bxp-mcp build + unit tests + JSON-RPC smoke (incl. bxp_simulate)
│   ├── test-03-bridge.sh     # bxp-gui-bridge build + unit tests
│   ├── test-04-desktop.sh    # flutter analyze + flutter test + json5_ast dart test (builds bridge .so)
│   ├── test-05-bench-guard.sh    # coarse perf gate: recycles Console's ReleaseSafe
│   │                             # bxp-cli (cache hit), RSS ceiling + wall scaling-ratio
│   │                             # (catches O(N) RSS + O(n^2) regressions; no absolute
│   │                             # wall thresholds)
│   ├── test-06-expr-corpus.sh    # cross-runner expression corpus regression gate
│   ├── test-07-datasets.sh   # bxp-cli regression vs datasets/*/*.expected
│   ├── test-08-docs-examples.sh  # docs example pages: every clickable
│   │                             # expression must evaluate against its own
│   │                             # sample; the delimiter declaration must match
│   │                             # sample.json; no named-map REMAP/REPLACE
│   │                             # (it passes input through and looks correct)
│   ├── gen-wasm-playground.sh    # build docs/assets/wasm/bxp-eval.wasm
│   │                             # (untracked artifact; gen-docs.sh calls it)
│   ├── check-wasm-parity.sh      # wasm vs native over the expression corpus —
│   │                             # needs a JS runtime, so NOT a test-NN phase;
│   │                             # runs in the docs workflow
│   ├── release.sh            # Wrapper — runs release-01-console.sh + release-02-desktop.sh
│   ├── release-01-console.sh    # Cross-compile bxp-cli + bxp-mcp, package bxp-console-* archives
│   ├── release-02-desktop.sh    # Host-OS-specific Flutter desktop bundle → .AppImage / .deb
│   │                            # / .tar.gz / NSIS .exe / DMG (matrixed by GH Actions)
│   ├── release-03-checksums.sh  # Emit SHA256SUMS for every release artifact
│   ├── release-changelog.sh     # Release prep: bump all 6 manifests + generate the
│   │                            # CHANGELOG.md entry from commits since the last tag,
│   │                            # committed as "release: prepare <version>". Push manually
│   ├── release-tag.sh           # Cut + push the vX.Y.Z tag using the version already in
│   │                            # the manifests (bxp-cli/build.zig.zon), triggering release.yml
│   └── check-formatting.sh      # mermaid-fence syntax check; PRE-RELEASE docs
│                                # step — deliberately NOT a test-NN phase
│                                # (test.sh does not auto-run it). Markdown
│                                # formatting is hand-maintained (prettier +
│                                # markdownlint dropped — broke MkDocs syntax)
├── docs/                 # Developer + user documentation
│   │                     # assets/javascripts/playground.js + assets/wasm/ =
│   │                     # the in-browser expression scratchpad; authoring
│   │                     # conventions in docs/examples/CLAUDE.md
│   ├── index.md              # MkDocs landing page (nav lives in mkdocs.yml)
│   ├── getting-started/      # install, first conversion, built-in templates
│   ├── guide/                # User guide: templates, expressions, dates,
│   │                         # numbers/encoding, row routing, cross-row joins,
│   │                         # targets, running
│   ├── reference/            # Generated + hand-maintained reference: CLI flags,
│   │                         # config schema, expr functions, date tokens, exit
│   │                         # codes, MCP tools, GUI tools/prefs/shortcuts
│   ├── gui/                  # bxp-gui user-facing guide (features, preferences,
│   │                         # updates, troubleshooting)
│   ├── ai/                   # Agent-facing guides (authoring a broker, gui-mcp,
│   │                         # handoff)
│   ├── dev/                  # Developer docs — build, testing, debugging,
│   │   │                     # release, mcp, roadmap.md (long-term backlog
│   │   │                     # mirrored to memory)
│   │   ├── architecture/     # System architecture + module diagrams
│   │   ├── internals/        # Implementation + module notes
│   │   ├── gui/              # bxp-gui developer-side architecture/patterns
│   │   └── trace-protocol/   # Binary BXTB --trace stream reference
│   ├── examples/             # MkDocs Examples section + runnable example tree
│   │                         # (basic / intermediate / advanced / real-world);
│   │                         # hand-authored index.md pages — see
│   │                         # docs/examples/CLAUDE.md. Indexes generated by
│   │                         # scripts/gen-examples-index.py.
│   ├── includes/             # Shared MkDocs snippets (abbreviations)
│   └── assets/               # demo.gif hero, logo, favicon, css/js
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
- **bxp-desktop** — `bxp-desktop-<platform>.{AppImage,exe,dmg}` (one format
  per platform — AppImage/Linux, exe/Windows, dmg/macOS — and no version in the
  filename) — Flutter GUI + bundled bxp-cli + bxp-mcp + bxp-gui-bridge.

Cut a release by pushing a `v*` tag; `.github/workflows/release.yml`
fans out to ubuntu / windows / macos runners, each producing its native
artifacts, and a final aggregator job uploads everything to a GitHub
Release alongside `SHA256SUMS`. The Phase 2 in-app updater
(`bxp-gui/lib/services/updater_service.dart`) verifies downloads against
that file. See `docs/dev/release.md` for the operator walkthrough.

## Package dependency

```text
bxp-cli         --[path dep]--> bxp-core   --[fetch dep]--> uucode (Unicode tables)
bxp-mcp         --[path dep]--> bxp-core    --[subprocess]-> bxp-cli (bxp_simulate only)
                                            (also takes zig-libs `mcp` — the JSON-RPC
                                             transport — through bxp-core's module table)
bxp-gui-bridge  --[path dep]--> bxp-core    (bridge_inspect / bridge_eval_* in-proc;
                                             also takes zig-libs `minisign` + `procrun`
                                             through bxp-core's module table — one pin)
bxp-gui         --[FFI]------> bxp-gui-bridge --[subprocess]-> bxp-cli (dry-run/version)
docs (browser)  --[wasm]-----> bxp-core/src/wasm.zig -> inspect.evalBatchIo
```

The stateless inspection surface (config / expression validation, docs,
templates, eval-batch) lives once in `bxp-core/src/inspect.zig` and is wrapped
by three thin adapters: `bxp-mcp` (MCP/stdio for agents), `bxp-gui-bridge`
(FFI for the Dart GUI) and `bxp-core/src/wasm.zig` (wasm32, for the docs site's
expression scratchpad — one expression at a time, deliberately not a browser
reimplementation of `bxp-cli`). The GUI talks only to `bxp-gui-bridge` on every platform
since the v0.3.0 proxy flip — stateless ops run in-process via the bridge's
bxp-core/inspect link, and the bridge proxies `bxp-cli` runs. The former
`bxp-fmt` CLI adapter was removed once both wrappers covered every operation.

`bxp-core` is a local path dependency (`../bxp-core`) with **three external
(fetch) dependencies**, each pinned and content-addressed in
`bxp-core/build.zig.zon`:

- `uucode` (MIT) — field-selected Unicode case-mapping / decomposition tables
  behind `UPPER` / `LOWER` / `UNACCENT`, pinned to its `main` line.
- `regex` (`quangd/regex.zig`) — the Pike-VM engine behind `REGEX_MATCH` /
  `REGEX_EXTRACT`, pinned to an exact commit.
- `zig_libs` — the module collection supplying `tz` (IANA UTC-offset lookup
  behind `TO_UTC` / `TZ_OFFSET` / `TZ_CONVERT` / `IS_DST`), `datefmt` (the
  date core behind `DATE_CONVERT` and every calendar builtin) `encoding`
  (single-byte code page ↔ UTF-8 behind `csv_*_encoding`), `json5` (the
  JSON5 → JSON preprocessor behind config loading), `decimal` (the
  fixed-point numeric core behind every computed value), `zipstream`
  (the streaming ZIP reader behind xlsx ingest and the zipped-CSV
  pre-pass), `diagnostics` (the structured validation-finding
  collector), `numparse` (the grouped-number parser behind numeric
  coercion — the first piece taken from *below* file level, extracted out of
  `expr.zig` rather than out of a file of its own), `csvstream` (the CSV
  record model AND the `ChunkReader` that used to sit privately in bxp-cli —
  upstream holds one module for both halves), `minisign` (the
  signature format behind the GUI updater's authenticity check), `procrun`
  (the reap-race-tolerant child wait behind the bridge's `bxp-cli` spawns)
  and `mcp` (the JSON-RPC 2.0 / MCP transport behind `bxp-mcp` — the one
  module that came *back*: upstream's copy is this repo's former
  `bxp-mcp/src/server.zig`, extracted there and hardened).
  bxp-core imports none of the last three — they are re-exported so
  `bxp-gui-bridge` and `bxp-mcp` share the same pin. Treated as a
  foreign upstream: read-only, pinned to the commit behind a release tag,
  never edited from this repo. The offset tables are compiled into the `tz`
  module, so there is still **no runtime dependency** — the pinned tzdata
  snapshot ships inside the binary exactly as the former in-tree copy did.
  All of them were lifted out of bxp-core and hardened upstream (`mcp` the
  other way round first — see above). The per-module inventory and rationale
  live in [`bxp-core/CLAUDE.md`](bxp-core/CLAUDE.md); finishing the extraction
  is the `v1.0.0` milestone in `docs/dev/roadmap.md`.

The `tools/tz-gen`
generator that emitted the offset tables (the only place `std.Tz` was used)
moved to `scripts/tz-gen/` in zig-libs alongside the module it feeds, so the
table and the tool that derives it now live together; nothing tz-related is
left in this repo. `datefmt`, `encoding`, `json5`, `decimal`, `zipstream` and
`diagnostics` followed `tz` upstream the same way, and `numparse` after them —
that one as a function lifted out of `expr.zig`, not a file. Three of them were not merely stale
copies: upstream had already fixed two crashes and two JSON5-spec deviations
`json5` still carried, a missing division-overflow guard that made `decimal`
abort the process, and — in `zipstream` — a central-directory overflow that
aborted on a malformed archive plus the absent CRC-32 check that let a
tampered member convert as if it were valid. Every module must be taken from **one shared `b.dependency` handle** —
they import each other (`tz` imports `datefmt`), so a second handle would
compile a second copy; doing it right is what collapsed the two date cores
the binary used to carry into one.
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
  `$err_*`/`$warn_*`/`$info_*` annotated-JSON marker shape — there is no
  `$comm_*`, comments are stripped), wire protocol, the shared `inspect` core,
  `bxp_simulate` spawn design.
- [`bxp-core/CLAUDE.md`](bxp-core/CLAUDE.md) — module API overview, build details, test coverage.
- [`bxp-gui/CLAUDE.md`](bxp-gui/CLAUDE.md) — Flutter app structure, services/store/ui split,
  bxp-cli subprocess + bxp-gui-bridge FFI wiring.
- [`bxp-gui-bridge/CLAUDE.md`](bxp-gui-bridge/CLAUDE.md) — Zig FFI shared library;
  C-ABI surface, Debug→ReleaseSafe rewrite rationale, platform role.
- [`bxp-gui/packages/json5_ast/CLAUDE.md`](bxp-gui/packages/json5_ast/CLAUDE.md) — standalone
  Dart JSON5 AST library; parser, dumper, mutation API.
- [`docs/examples/CLAUDE.md`](docs/examples/CLAUDE.md) — authoring conventions for the
  teaching + real-world example tree (tiers, dir layout, readme structure,
  generated index).

## CLAUDE.md files

New CLAUDE.md files may be created anywhere inside `bxp/` as needed.
Existing files: `bxp/CLAUDE.md` (this file), `bxp/bxp-cli/CLAUDE.md`,
`bxp/bxp-core/CLAUDE.md`, `bxp/bxp-mcp/CLAUDE.md`,
`bxp/bxp-gui/CLAUDE.md`, `bxp/bxp-gui-bridge/CLAUDE.md`,
`bxp/bxp-gui/packages/json5_ast/CLAUDE.md`, `bxp/docs/examples/CLAUDE.md`.

## Git & GitHub

Monorepo git is initialized at `bxp/` root.
