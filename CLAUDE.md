# CLAUDE.md — BXP monorepo

Guidance for Claude Code when working with this repository.

## Repository layout

```text
bxp/
├── bxp-cli/              # CLI batch tool (main user-facing binary)
│   ├── src/
│   │   ├── main.zig      # CLI layer: arg parsing, config loading, dispatch
│   │   └── pipeline.zig  # Processing: processBroker(), xlsxPrePass()
│   ├── build.zig
│   └── build.zig.zon     # depends on bxp-core (path dep)
├── bxp-fmt/              # Developer utility binary used by bxp-gui and scripts/test.sh
│   ├── src/main.zig      # 6 subcommands: --config / --expr / --expr-trace / --docs /
│   │                     # --list-templates / --fetch-template
│   ├── build.zig
│   └── build.zig.zon     # depends on bxp-core (path dep)
├── bxp-core/             # Internal Zig library (shared modules)
│   ├── src/
│   │   ├── csv.zig       # RFC 4180 CSV parser + splitRecords()
│   │   ├── xlsx.zig      # .xlsx → CSV converter (ZIP+XML)
│   │   ├── expr.zig      # Expression evaluator + per-builtin FnDoc catalog
│   │   ├── config.zig    # JSON5 config loader + per-struct FieldDoc tables
│   │   ├── json.zig      # JSON array-of-objects → CSV rows
│   │   ├── json5.zig     # JSON5 preprocessor (comments, unquoted keys, ...)
│   │   └── docs.zig      # Aggregator: re-exports expr catalog + flattens
│   │                     # config FieldDoc tables; serves bxp-fmt --docs
│   ├── build.zig         # exports each file as a named Zig module
│   └── build.zig.zon     # depends on sunrise (datetime library)
├── bxp-gui/              # Flutter desktop app (replaces bxp-ui; uses bxp-cli/bxp-fmt via subprocess)
│   ├── lib/              # Dart source (services/, store/, ui/)
│   ├── linux/, macos/, windows/, web/  # platform configs
│   ├── packages/json5_ast/             # Path-dep Dart JSON5 AST library
│   │                                    # (post-Phase-5e CST replacement; not bxp-specific —
│   │                                    # candidate for extraction to a standalone repo when
│   │                                    # a second Dart consumer materialises)
│   └── pubspec.yaml
├── resources/
│   ├── console/          # bxp-cli sample config + user-facing readme bundled in console archives
│   └── desktop/          # bxp-gui.desktop template + readme bundled in desktop archives
├── datasets/             # Anonymized sample data + expected outputs for regression tests
├── scripts/
│   ├── test.sh           # Wrapper — runs test-01-console.sh + test-02-desktop.sh
│   ├── test-01-console.sh   # bxp-core unit + bxp-fmt smoke + bxp-cli regression
│   ├── test-02-desktop.sh   # flutter analyze + flutter test + json5_ast dart test
│   ├── release.sh        # Wrapper — runs release-01-console.sh + release-02-desktop.sh
│   ├── release-01-console.sh    # Cross-compile bxp-cli, package bxp-console-* archives
│   ├── release-02-desktop.sh    # Host-OS-specific Flutter desktop bundle → .AppImage / .deb
│   │                         # / .tar.gz / NSIS .exe / DMG (matrixed by GH Actions)
│   └── release-03-checksums.sh    # Emit SHA256SUMS for every release artifact
├── docs/                 # Developer documentation (architecture.md, devel.md, bxp-ui-trace-protocol.md)
├── .github/workflows/
│   └── release.yml       # Multi-host release pipeline triggered by `v*` tag push
├── DEV/                  # Developer scratch space — sample data, in-flight plans, AST prototypes
├── CLAUDE.md             # This file
├── LICENCE.md            # Apache 2.0
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

- **bxp-console** — `bxp-console-<ver>-<platform>.{tar.gz,zip}` — CLI only.
- **bxp-desktop** — `bxp-desktop-<ver>-<platform>.{tar.gz,AppImage,deb,exe,dmg}` — Flutter GUI + bundled bxp-cli + bxp-fmt.

Cut a release by pushing a `v*` tag; `.github/workflows/release.yml`
fans out to ubuntu / windows / macos runners, each producing its native
artifacts, and a final aggregator job uploads everything to a GitHub
Release alongside `SHA256SUMS`. The Phase 2 in-app updater
(`bxp-gui/lib/services/updater_service.dart`) verifies downloads against
that file. See `docs/release.md` for the operator walkthrough.

## Package dependency

```text
bxp-cli  --[path dep]--> bxp-core  --[url dep]--> sunrise
bxp-fmt  --[path dep]--> bxp-core
bxp-gui  --[subprocess]-> bxp-cli, bxp-fmt
```

`bxp-core` is a local path dependency (`../bxp-core`) — no network fetch needed.
bxp-gui ships both bxp-cli and bxp-fmt binaries inside the Flutter bundle and
invokes them via `Process.run` for conversions, validation, docs, etc.

## bxp-gui user prefs

bxp-gui persists user state (theme, recent files, custom places, zoom)
to a visible JSON file at a canonical OS path:

- Linux:   `~/.local/share/bxp-gui/bxp-gui.json`
- macOS:   `~/Library/Application Support/bxp-gui/bxp-gui.json`
- Windows: `%APPDATA%\bxp-gui\bxp-gui.json`

The file is auto-created on first write. Implementation: `bxp-gui/lib/
services/prefs_service.dart`. A one-shot migration from the legacy
`shared_preferences` plugin store runs on first launch after the v0.2
upgrade and clears the old store; the migration code is removed in v0.3.

## Coding conventions

- All code comments and documentation in English
- Zig 0.15.2 API — use zig skill before writing new code
- User-facing error messages use `std.process.exit(1)` (no Zig stack trace)

## Detailed documentation

- [`bxp-cli/CLAUDE.md`](bxp-cli/CLAUDE.md) — full configuration reference, expression syntax,
  template guide, broker list.
- [`bxp-fmt/CLAUDE.md`](bxp-fmt/CLAUDE.md) — all subcommands, `--docs` JSON shape,
  `$comm_*`/`$err_*` output format.
- [`bxp-core/CLAUDE.md`](bxp-core/CLAUDE.md) — module API overview, build details, test coverage.
- [`bxp-gui/CLAUDE.md`](bxp-gui/CLAUDE.md) — Flutter app structure, services/store/ui split,
  bxp-cli/bxp-fmt subprocess wiring.

## CLAUDE.md files

New CLAUDE.md files may be created anywhere inside `bxp/` as needed.
Existing files: `bxp/CLAUDE.md` (this file), `bxp/bxp-cli/CLAUDE.md`,
`bxp/bxp-core/CLAUDE.md`, `bxp/bxp-fmt/CLAUDE.md`, `bxp/bxp-gui/CLAUDE.md`.

## Git & GitHub

Monorepo git is initialized at `bxp/` root.
