# BXP - Broker eXchange Parser

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE.md)
[![Latest release](https://img.shields.io/github/v/release/zaxified/bxp)](https://github.com/zaxified/bxp/releases)
[![CodeQL](https://github.com/zaxified/bxp/actions/workflows/github-code-scanning/codeql/badge.svg)](https://github.com/zaxified/bxp/security/code-scanning)

> Convert broker exports into [Wealthfolio](https://wealthfolio.app/) and
> [brycht.app](https://brycht.app) CSV using declarative JSON5 templates.
> Privacy-respecting, single binary, no runtime dependencies.

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

BXP turns broker statements (CSV, XLSX, JSON) into
[Wealthfolio](https://wealthfolio.app/) and [brycht.app](https://brycht.app)
CSV import formats. Adding a new broker is a JSON5 template - no code, no
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
(both old and new formats), targeting both Wealthfolio and brycht.app. The full list lives in
[`resources/console/bxp-cli.examples.json`](resources/console/bxp-cli.examples.json) -
each entry is a working template with inline comments you can copy and
adapt. A new broker takes a JSON5 entry, not a code change.

## Why use BXP

- **GUI with live debugger.** Edit a template, hit dry-run, watch every
  row's variables / rule matches / output stream past in NDJSON. Click
  any trace event to jump to the expression that produced it. Typos
  surface as red underlines on the offending token before you save.
- **Universal mini-ETL.** Wealthfolio and brycht.app are the shipping
  targets, but the engine is broker-agnostic and target-agnostic - any
  tracker reachable by writing an `output_schema` is in scope, and
  anything expressible as "tabular in, tabular out, with row-level
  rules" fits.
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

The console package ships `bxp-cli` + `bxp-cli.examples.json` (12
working templates with inline comments) + a sample `bxp-cli.json`. Use
this when you want headless batch conversion, want to script `bxp-cli`
into a pipeline, or just need to read the template catalog without
installing the GUI.

Download from the
[releases page](https://github.com/zaxified/bxp/releases/latest) — pick
`bxp-console-<version>-<platform>.{tar.gz,zip}` for your OS.

### 2. Desktop gui debugger

#### Linux

```bash
sudo apt install libfuse2t64   # libfuse2 on older distros
mkdir -p ~/.local/bin && cd ~/.local/bin
rm bxp-desktop-linux-x86_64.AppImage   # delete previous downloads
wget https://github.com/zaxified/bxp/releases/latest/download/bxp-desktop-linux-x86_64.AppImage
chmod +x bxp-desktop-linux-x86_64.AppImage
./bxp-desktop-linux-x86_64.AppImage   # first launch prompts to install menu + icons + bxp-gui.json
```

The AppImage lives in `~/.local/bin/` (typically on `PATH`). User
preferences auto-save to `~/.local/share/bxp-gui/bxp-gui.json` on first
edit. After the first launch's integration prompt, the app is reachable
from the system menu.

#### Windows

Download
[`bxp-desktop-windows-x86_64.exe`](https://github.com/zaxified/bxp/releases/latest/download/bxp-desktop-windows-x86_64.exe)
and run the NSIS installer. SmartScreen may warn — "More info" → "Run
anyway". The app installs to `C:\Program Files\bxp-gui\` with a Start
menu entry and desktop shortcut.

#### macOS (Apple Silicon)

Download
[`bxp-desktop-macos-arm64.dmg`](https://github.com/zaxified/bxp/releases/latest/download/bxp-desktop-macos-arm64.dmg),
open it, drag `bxp-gui.app` to `/Applications/`. First launch:
right-click `bxp-gui.app` → Open → Open (bypasses Gatekeeper once).
Subsequent launches go through Spotlight / Launchpad / Dock.

## Documentation

| For                                | Read                                                         |
| ---------------------------------- | ------------------------------------------------------------ |
| Using `bxp-cli` from a terminal    | [`resources/console/readme.md`](resources/console/readme.md) |
| Using `bxp-gui` (desktop)          | [`resources/desktop/readme.md`](resources/desktop/readme.md) |
| Developer / architecture / roadmap | [`docs/`](docs/README.md)                                    |
| Contributing                       | [`CONTRIBUTING.md`](CONTRIBUTING.md)                         |
| Release history                    | [`CHANGELOG.md`](CHANGELOG.md)                               |

## Licence

Apache License 2.0. See [`LICENSE.md`](LICENSE.md).
