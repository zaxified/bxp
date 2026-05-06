# BXP Desktop

Graphical editor and dry-run debugger for BXP broker conversion configs.
Bundles three binaries:

- `bxp-gui` — the Flutter desktop application (this app).
- `bxp-fmt` — companion validator / docs catalog used by the GUI.
- `bxp-cli` — the conversion engine; also runnable from the terminal.

## Installation

| Platform | Format | Install |
| -- | -- | -- |
| Linux | `.AppImage` | Mark executable, double-click |
| Linux | `.deb` | `sudo apt install ./bxp-desktop-*.deb` |
| Linux | `.tar.gz` | Extract, run `./bxp-gui` |
| Windows | `setup.exe` | Run installer, follow prompts |
| macOS | `.dmg` | Open, drag `bxp-gui.app` to Applications |

On macOS the first launch must be **right-click → Open** so Gatekeeper
allows the unsigned app. Subsequent launches start normally.

## User preferences

Settings (theme, recent files, custom places) are stored in a single
visible JSON file:

| Platform | Path |
| -- | -- |
| Linux | `~/.local/share/bxp-gui/bxp-gui.json` |
| macOS | `~/Library/Application Support/bxp-gui/bxp-gui.json` |
| Windows | `%APPDATA%\bxp-gui\bxp-gui.json` |

Delete the file to reset to defaults.

## Auto-updates

The app checks `github.com/zaxified/bxp` for new releases on launch and
every 6 hours; if a newer version is available it offers a one-click
update that downloads + installs the matching native installer.

## Documentation

For configuration reference and CLI usage see the bxp-console package's
`readme.md` (also available at the project's GitHub repository).

Apache-2.0 licensed. See `LICENCE.md` in the source tree.
