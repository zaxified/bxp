---
description: "How the in-app updater finds, verifies and installs a new release, and how to turn it off."
---

# Auto-updates

The app polls `github.com/zaxified/bxp` for new releases 5 seconds after
launch and every 6 hours thereafter. When a newer version is available a
dialog offers a one-click update that downloads, verifies (minisign
signature over `SHA256SUMS`, then the asset's SHA-256 checksum —
**fail-closed: any mismatch refuses the install**), and dispatches to the
platform-native installer:

- **Windows** — silent NSIS reinstall, GUI relaunches automatically.
- **macOS** — DMG mount, copy into your **`~/Applications/`** folder
  (per-user, not the system-wide `/Applications/`), unmount, relaunch.
- **Linux AppImage** — atomic in-place replace + re-`exec()`.

The updater is skipped during development builds. Two hosts have no installer
to fetch and surface a "manual update required" message with the release page
URL instead: a Linux build not running from an AppImage — the only supported
Linux channel — and an Intel Mac, because the release workflow only produces
arm64 DMGs and installing one there would replace a working app with a build
that cannot launch.
