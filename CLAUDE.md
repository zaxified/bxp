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
├── bxp-fmt/              # Developer utility binary: --config validate, --expr validate
│   ├── src/main.zig      # arg dispatcher; config verbatim round-trip + expr check
│   ├── build.zig
│   └── build.zig.zon     # depends on bxp-core (path dep)
├── bxp-core/             # Internal Zig library (shared modules)
│   ├── src/
│   │   ├── csv.zig       # RFC 4180 CSV parser + splitRecords()
│   │   ├── xlsx.zig      # .xlsx → CSV converter (ZIP+XML)
│   │   ├── expr.zig      # Expression evaluator (IF, DATE_CONVERT, TICKER, ...)
│   │   ├── config.zig    # JSON5 config loader (BrokerConfig, PrePass, ...)
│   │   ├── json.zig      # JSON array-of-objects → CSV rows
│   │   └── json5.zig     # JSON5 preprocessor (comments, unquoted keys, ...)
│   ├── build.zig         # exports each file as a named Zig module
│   └── build.zig.zon     # depends on sunrise (datetime library)
├── bxp-gui/              # Flutter desktop app (replaces bxp-ui; uses bxp-cli/bxp-fmt via subprocess)
│   ├── lib/              # Dart source (services/, store/, ui/)
│   ├── linux/            # Linux CMake platform config
│   └── pubspec.yaml
├── resources/            # Example config (bxp-cli.examples.json) and user readme
├── datasets/             # Anonymized sample data + expected outputs for regression tests
├── scripts/
│   ├── test.sh           # Full test suite (bxp-core unit tests + bxp-cli regression)
│   └── release.sh        # Cross-compile + package bxp-cli releases
├── docs/                 # Developer documentation  [planned]
├── CLAUDE.md             # This file
├── LICENCE.md            # Apache 2.0
└── README.md             # Project overview
```

## Build & test

```bash
# Full test suite (unit + regression):
bash scripts/test.sh

# Build bxp-cli:
cd bxp-cli && zig build

# Run bxp-cli:
cd bxp-cli && ./zig-out/bin/bxp-cli --help

# Unit tests (bxp-core modules):
cd bxp-core && zig build test
```

## Package dependency

```text
bxp-cli  --[path dep]--> bxp-core  --[url dep]--> sunrise
bxp-fmt  --[path dep]--> bxp-core
```

`bxp-core` is a local path dependency (`../bxp-core`) — no network fetch needed.

## Coding conventions

- All code comments and documentation in English
- Zig 0.15.2 API — use zig skill before writing new code
- User-facing error messages use `std.process.exit(1)` (no Zig stack trace)

## Detailed documentation

- [`bxp-cli/CLAUDE.md`](bxp-cli/CLAUDE.md) — full configuration reference, expression syntax,
  template guide, broker list, and test/release instructions.
- [`bxp-fmt/CLAUDE.md`](bxp-fmt/CLAUDE.md) — `--config` / `--expr` flags, exit codes, scope.
- [`bxp-core/CLAUDE.md`](bxp-core/CLAUDE.md) — module API overview, build details, test coverage.

## CLAUDE.md files

New CLAUDE.md files may be created anywhere inside `bxp/` as needed to match the project
structure and support efficient workflow.
Existing files: `bxp/CLAUDE.md` (this file), `bxp/bxp-cli/CLAUDE.md`, `bxp/bxp-core/CLAUDE.md`.

## Git & GitHub

Monorepo git is initialized at `bxp/` root.
