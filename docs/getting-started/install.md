---
description: "Download, verify and run the console archive or the desktop app on Linux, macOS or Windows."
---

# Install

## BXP Desktop

Each release ships one artefact per platform, downloadable via stable
GitHub URLs that always point at the latest version.

### Linux

```bash
sudo apt install libfuse2t64   # libfuse2 on older distros
mkdir -p ~/.local/bin && cd ~/.local/bin
wget https://github.com/zaxified/bxp/releases/latest/download/bxp-desktop-linux-x86_64.AppImage
chmod +x bxp-desktop-linux-x86_64.AppImage
./bxp-desktop-linux-x86_64.AppImage   # first launch prompts to install menu + icons
```

The AppImage lives in `~/.local/bin/` (typically on `PATH`). User
preferences auto-save to `~/.local/share/bxp-gui/bxp-gui.json` on first
edit. The Linux AppImage is the only Linux distribution channel — one
update path. On first launch the AppImage offers to write
`~/.local/share/applications/bxp-gui.desktop` plus `hicolor` icons so
the app shows up in the system menu — no `sudo` needed, reversible from
the Settings drawer.

### Windows

Download
[`bxp-desktop-windows-x86_64.exe`](https://github.com/zaxified/bxp/releases/latest/download/bxp-desktop-windows-x86_64.exe)
and run the NSIS installer. SmartScreen may warn — "More info" → "Run
anyway". It installs **per-user — no administrator rights required** — to
`%LOCALAPPDATA%\Programs\bxp-gui`, with Start menu entries for the app and
its uninstaller. User preferences live at `%APPDATA%\bxp-gui\bxp-gui.json`.

### macOS (Apple Silicon, macOS 12 or newer)

Download
[`bxp-desktop-macos-arm64.dmg`](https://github.com/zaxified/bxp/releases/latest/download/bxp-desktop-macos-arm64.dmg),
open it, drag `bxp-gui.app` to `/Applications/`. First launch:
right-click `bxp-gui.app` → Open → Open (bypasses Gatekeeper once).
Subsequent launches go through Spotlight / Launchpad / Dock. User
preferences live at `~/Library/Application Support/bxp-gui/bxp-gui.json`.

## BXP Console

The console package — `bxp-cli` + `bxp-mcp`, co-located so `bxp-mcp`'s
`bxp_simulate` can spawn `bxp-cli` — ships as a per-platform archive
(`bxp-console-<version>-<platform>.{tar.gz,zip}`) on the same
[GitHub Releases](https://github.com/zaxified/bxp/releases/latest) page.

There is nothing to install. Unpack the archive and run the binary from
wherever you put it — it needs no libraries, no runtime, and no entry in
`PATH`. The two binaries must stay in the same directory. On Linux and macOS
you may need `chmod +x bxp-cli bxp-mcp` if your unpacker dropped the
executable bit.

The archive is laid out so it runs as-is:

| File | What it is |
| --- | --- |
| `bxp-cli` | The conversion engine |
| `bxp-mcp` | The MCP server for AI agents |
| `bxp-cli.json` | A working config — one template, ready to run |
| `bxp-cli.examples.json` | The template library to copy from |
| `sample.csv` | A sample input file |
| `sample.csvx` | The converted result, ready to look at before you run anything. Your first run overwrites it — that is the point |
| `sample.expected` | The reference copy of that same result. Nothing overwrites it, so it stays a trustworthy answer key |

The last two are byte-identical on a correct install, which is what makes the
check below meaningful.

### Check the install in one command

From the unpacked directory:

```bash
./bxp-cli --dry-run
```

```text
=== template: trading212_to_wealthfolio ===
processing 'sample.csv'
summary: errors:0 warnings:0 time:0.004s

=== overall summary ===
errors:0 warnings:0 time:0.006s
```

`--dry-run` runs the whole pipeline in memory and writes nothing. Drop the
flag to produce the real file, then confirm it matches the reference:

```bash
./bxp-cli
diff sample.csvx sample.expected     # no output = correct
```

Continue with [Your first conversion](first-conversion.md).
