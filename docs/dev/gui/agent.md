# Agent Control & Auto-updater

## Agent control (gui-mcp)

`GuiMcpServer` ([lib/services/gui_mcp_server.dart](https://github.com/zaxified/bxp/blob/master/bxp-gui/lib/services/gui_mcp_server.dart))
embeds an MCP server **inside the running Flutter process** so a local agent can
drive the live GUI — open a config, edit nodes, run a dry-run, read the trace. It
is **not** `bxp-mcp`: that one is a separate Zig binary with stateless tools over
stdio (see [`mcp.md`](../mcp.md)). gui-mcp is **stateful** — every tool is a thin
wrapper over the same `TraceStore` actions the UI uses, so an agent edit repaints
the UI for free and parity with manual use is definitional.

**Transport.** localhost StreamableHTTP, default `127.0.0.1:7717`
(`kDefaultMcpHost` / `kDefaultMcpPort`); host / port resolve as pref → env
(`BXP_GUI_MCP_HOST` / `BXP_GUI_MCP_PORT`) → default and are editable live in the
settings inspector. A fixed default lets an agent reach a known endpoint with no
discovery file. Unlike the bridge, the server is **non-fatal**: a bind clash
surfaces in `lastError` and the GUI stays fully usable without it.

**Tools.** `get_state`, `open_config`, `reload`, `edit_node`, `insert_node`,
`rename_key`, `move_node`, `delete_node`, `set_template`, `dry_run`, `full_run`,
`get_trace`, `get_row_detail`, `save`, `exit`. `get_state` is the "see the
screen" call: alongside path / dirty / run status it carries `validation` —
per-severity counts plus the first findings (`{severity, path, message}`),
the same badges the config tree paints. `GET /health` is an
unauthenticated handshake (`{name, version, config_path, dirty, agent_connected,
auto_approve}`) so an agent can confirm it reached the right server before MCP
`initialize`.

**Security model.** The defaults are bounded for a local-only tool:

- **Loopback bind** (`127.0.0.1`) is the baseline — no network exposure.
- **Request-body cap** — `_kMaxRequestBodyBytes` (8 MB); a larger body gets a
  `413` instead of an unbounded read.
- **Confirm-gating** — destructive / side-effecting tools (`save`, `full_run`,
  `delete_node`, `exit`) prompt through an `AgentConfirmFn` dialog; additive
  edits are blocked outright when the config loaded with errors. `save` is
  refused before the prompt while the config carries validation errors,
  returning `{saved:false, reason, validation}` — the agent sees the same
  block the toolbar SAVE button applies to the user.
- **Origin policy** — permissive by default (an empty allowlist accepts every
  `Origin`, so webview agents that send one keep working); the loopback bind is
  the protection. A persisted `bxp-gui.mcpOriginAllowlist` tightens it when the
  user binds to a network interface.
- **Auto-approve** is **off by default**, and when on it is _visible_: a red
  `devel-auto-approve-mode` status-bar chip plus `auto_approve` in `/health` and
  `get_state`, so neither the driving agent nor a watching user can miss that the
  confirm gate is bypassed.

**Headless self-debug.** Turning on _settings inspector → Agent control →
Auto-approve_ (persisted as `bxp-gui.mcpAutoApprove`) lets an agent drive the GUI
without manual clicks — a semantic alternative to Playwright, since every tool is
a real `TraceStore` action. The persisted toggle (not the
`BXP_GUI_MCP_AUTO_APPROVE` env seed) is what survives across `launch_app` runs.
Full cycle and threat-model rationale live in
[`bxp-gui/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-gui/CLAUDE.md) ("Agent control" + "Known non-issues").

---

## Auto-updater and security

`UpdaterService` ([lib/services/updater_service.dart](https://github.com/zaxified/bxp/blob/master/bxp-gui/lib/services/updater_service.dart))
polls the GitHub releases API shortly after launch and periodically thereafter; a
newer tag surfaces an update prompt
([update_dialog.dart](https://github.com/zaxified/bxp/blob/master/bxp-gui/lib/ui/components/update_dialog.dart)). The part
that matters is what happens **before** an installer is allowed to run — two
fail-closed checks over the _same_ downloaded bytes:

1. **Authenticity** — the `SHA256SUMS.minisig` minisign signature over
   `SHA256SUMS` is verified against the public key embedded in
   `UpdaterService.minisignPublicKey`. The crypto (Ed25519 + Blake2b-512) runs
   natively through `bridge_verify_minisign`, so there is no Dart crypto
   dependency.
2. **Integrity** — only then is the installer's SHA-256 matched against the
   now-trusted `SHA256SUMS`.

A missing or invalid signature, a missing / mismatched checksum, or an
unavailable verifier **all refuse the install**. Hashing and installing use the
same fetched bytes, which closes the verify→use swap window (the Linux AppImage
path writes the already-hashed bytes straight to `$APPIMAGE.new`). Signing is
automated in CI ([release.yml](https://github.com/zaxified/bxp/blob/master/.github/workflows/release.yml)).

Per-platform install dispatch: Windows `setup.exe /S` (silent NSIS, **per-user
install — no administrator elevation**, with a rename-swap self-heal so an update
can replace the running executable); macOS `hdiutil` mount → `cp -R` → `open`;
Linux AppImage atomic in-place replace + re-`exec`; `.deb` / tarball open the
release page (in-place self-update is AppImage-only). `kDebugMode` skips the
auto-check during dev runs.
