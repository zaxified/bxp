# User preferences

Settings (theme, zoom level, recent files, custom places, and the
[agent-control server](../ai/gui-mcp.md) host / port / auto-approve /
Origin allowlist) are stored in a single visible JSON file:

| Platform | Path                                                 |
| -------- | ---------------------------------------------------- |
| Linux    | `~/.local/share/bxp-gui/bxp-gui.json`                |
| macOS    | `~/Library/Application Support/bxp-gui/bxp-gui.json` |
| Windows  | `%APPDATA%\bxp-gui\bxp-gui.json`                     |

The file is auto-created on first write. Delete it to reset everything to
defaults. Every persisted key is listed in [User preferences
(keys)](../reference/gui-prefs.md) — generated from the app's `Prefs` catalog.

The GUI takes no command-line flags — it reads this preferences file, and
a handful of environment variables override individual settings for a
single launch (the settings inspector shows which ones are in effect).

There is deliberately **no startup auto-load**: bxp-gui always opens with
an empty editor. The recent-files list is remembered across launches and
seeds the open dialog (ctrl+o), so the last config you used is one click
away — but nothing is opened behind your back after a restart.
