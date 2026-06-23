# User preferences

Settings (theme, recent files, custom places, zoom level) are stored in a
single visible JSON file:

| Platform | Path |
| --- | --- |
| Linux | `~/.local/share/bxp-gui/bxp-gui.json` |
| macOS | `~/Library/Application Support/bxp-gui/bxp-gui.json` |
| Windows | `%APPDATA%\bxp-gui\bxp-gui.json` |

The file is auto-created on first write. Delete it to reset everything to
defaults. Every persisted key is listed in [User preferences
(keys)](../reference/gui-prefs.md) — generated from the app's `Prefs` catalog.

The GUI takes no command-line flags — it reads this preferences file and
remembers the last-opened config across launches.
