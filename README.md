# BXP - Broker eXchange Parser

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE.md)
[![Latest release](https://img.shields.io/github/v/release/zaxified/bxp)](https://github.com/zaxified/bxp/releases)

> Convert broker exports into [Wealthfolio](https://wealthfolio.app/) CSV
> using declarative JSON5 templates. Privacy-respecting, single binary,
> no runtime dependencies.

## About

BXP started as an experiment in vibe-coding with Zig and grew into a
general-purpose tabular ETL micro-tool. Contributions - broker
templates, datasets, code, documentation - are welcome; see
[`CONTRIBUTING.md`](CONTRIBUTING.md).

<details open>
<summary> bxp-gui preview demo</summary>

![bxp-gui demo: load - edit - dry-run -- validate](docs/demo.gif)

</details>

## What it does

BXP turns broker statements (CSV, XLSX, JSON) into Wealthfolio's CSV
import format. Adding a new broker is a JSON5 template - no code, no
compilation. Two binaries ship together:

- **`bxp-cli`** - headless batch converter for scripts and pipelines.
- **`bxp-gui`** - desktop editor with autocomplete, syntax check, and a
  live dry-run debugger that streams per-row trace events.

Inputs CSV / XLSX / JSON; outputs CSV (RFC 4180) or JSON. The two-pass
pipeline supports cross-row joins (paired transaction legs, fee
refunds), 1:N row routing (one input row - multiple output rows), and a
small expression language with conditionals, math, string ops,
date / currency parsing, and identifier mapping.

## Supported brokers

Built-in templates ship for Anycoin, Revolut X, Trading 212, and XTB
(both old and new formats). The full list lives in
[`resources/bxp-cli.examples.json`](resources/bxp-cli.examples.json) -
each entry is a working template with inline comments you can copy and
adapt. A new broker takes a JSON5 entry, not a code change.

## Why use BXP

- **GUI with live debugger.** Edit a template, hit dry-run, watch every
  row's variables / rule matches / output stream past in NDJSON. Click
  any trace event to jump to the expression that produced it. Typos
  surface as red underlines on the offending token before you save.
- **Universal mini-ETL.** The primary target is broker - Wealthfolio,
  but the engine is broker-agnostic and target-agnostic - anything
  expressible as "tabular in, tabular out, with row-level rules" fits.
- **AI-friendly.** Templates are JSON5 with comments. Paste a 5-row
  sample of your broker's export into Claude / ChatGPT along with the
  reference readme, get back a working template.
- **Single binary, no dependencies.** No Python, no Docker, no Java
  runtime. Linux, macOS, Windows - Zig cross-compilation handles the
  rest.
- **Local-only.** Your statements never leave the machine. No cloud, no
  API keys, no telemetry.
- **Apache 2.0.** Use commercially, fork, modify.

## Quick start

### 1. Console cli with examples

Download console package for your OS [`releases`](https://github.com/zaxified/bxp/releases)

### 2. Desktop gui debugger

Download desktop package for your OS [`releases`](https://github.com/zaxified/bxp/releases) 

| OS | Format |
| --- | --- |
| Linux | `.AppImage`, `.deb`, `.tar.gz` |
| macOS | `.dmg` (Apple Silicon) |
| Windows | `setup.exe` (NSIS installer) |

## Documentation

| For | Read |
| --- | --- |
| Using `bxp-cli` from a terminal | [`resources/console/readme.md`](resources/console/readme.md) |
| Using `bxp-gui` (desktop) | [`resources/desktop/readme.md`](resources/desktop/readme.md) |
| Developer / architecture / roadmap | [`docs/`](docs/README.md) |
| Contributing | [`CONTRIBUTING.md`](CONTRIBUTING.md) |
| Release history | [`CHANGELOG.md`](CHANGELOG.md) |

## Licence

Apache License 2.0. See [`LICENSE.md`](LICENSE.md).
