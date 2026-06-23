# Auto-updates

The app polls `github.com/zaxified/bxp` for new releases 5 seconds after
launch and every 6 hours thereafter. When a newer version is available a
dialog offers a one-click update that downloads, verifies (minisign
signature over `SHA256SUMS`, then the asset's SHA-256 checksum —
**fail-closed: any mismatch refuses the install**), and dispatches to the
platform-native installer:

- **Windows** — silent NSIS reinstall, GUI relaunches automatically.
- **macOS** — DMG mount, copy to `/Applications/`, relaunch.
- **Linux AppImage** — atomic in-place replace + re-`exec()`.

The updater is skipped during development builds. Linux builds running
outside an AppImage (rare — only when someone runs `flutter run` locally)
and macOS Intel surface a "manual update required" message with the
release page URL.
