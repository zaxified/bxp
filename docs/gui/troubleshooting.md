# Troubleshooting

| Symptom                       | Likely cause / fix                                                                                                                 |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Fatal error gate on launch    | The `bxp-gui-bridge` library is missing from the bundle. Reinstall the desktop package.                                            |
| `dry-run` button greyed out   | No template selected, or the config has a load-time AST parse error (red banner in the tree).                                      |
| Error chips on every field    | Schema docs failed to load. Check the Settings inspector → Docs section for a load error from the bundled docs catalog.            |
| `cancel` button stuck         | The bxp-cli child didn't respond to SIGTERM. Wait 2 seconds — the watchdog escalates to SIGKILL automatically.                     |
| Slow first load on a new file | First invocation may include filesystem checks (ctrl+e driven). Subsequent loads skip them; you can force-skip by avoiding ctrl+e. |
| Tree shows `$comm_<N>` keys   | A bug — those keys should be hidden by the renderer. Open an issue with the offending file attached.                               |
