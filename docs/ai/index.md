---
description: "The two MCP servers BXP ships — one for authoring a template, one for driving the running app — what each is for, and how an agent connects to either."
---

# AI workflow

BXP ships **two MCP servers**. They are not alternatives and they do not
overlap: one lets an assistant *write and test* a conversion template with no
app running, the other lets it *drive the desktop app* you are looking at.

| | `bxp-mcp` | gui-mcp |
| --- | --- | --- |
| What it is | A standalone binary in both packages | A server embedded in the running BXP Desktop |
| Transport | JSON-RPC 2.0 over **stdio** — the agent host spawns it | **StreamableHTTP** on `http://127.0.0.1:7717/mcp` |
| Lifetime | Starts when the agent starts it, exits with it | Exists only while the app is open |
| State | **Stateless.** Every call takes the config as *text*; nothing is read from or written to disk | **Stateful.** Every call acts on the config open in the editor |
| What it is for | Authoring: validate a config, evaluate an expression, read the catalog, run a conversion end-to-end | Debugging together: open a config, edit a node, dry-run it, read the per-row trace |
| Needs the GUI | No | Yes |
| Tools | [9 tools](../reference/mcp-tools.md) | [15 tools](../reference/gui-agent-tools.md) |

The two meet in the middle of one workflow. An assistant drafts a template
with `bxp-mcp` and self-tests it against the sample rows — see [Authoring a
template](authoring-a-template.md). What it could not verify alone it hands back
in plain language ([Handing off](handoff.md)). If the remaining problems need to be
worked out against the real file, the two of you continue inside the app, with
the assistant driving through gui-mcp ([Driving the GUI](gui-mcp.md)).

## Connecting to `bxp-mcp`

The binary ships beside `bxp-cli` in the console archive and inside the bundle
on desktop. It takes no operational flags — it speaks MCP on stdin/stdout and
nothing else — so registering it is one entry in the agent host's config:

```json
{ "mcpServers": { "bxp": { "command": "/abs/path/to/bxp-mcp", "args": [] } } }
```

`bxp-mcp --help` prints its tool list and `--version` the build, which is the
quickest way to confirm the path points at the right binary. On desktop, read
the resolved path off **Settings inspector → Binaries** (ctrl+shift+s) — an
AppImage mounts itself somewhere new on every launch.

Without a host, it is drivable by hand — one JSON-RPC object per line:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | ./bxp-mcp
```

Every tool takes text, never a path, so the assistant validates the config it
is holding rather than one it hopes is on disk. A tool *failure* (a missing
argument, a spawn problem) sets `isError: true`; a domain answer like
`{"ok": false, …}` — an expression that does not evaluate, a template id that
does not exist — is a valid result to read, not a failure.

## Connecting to gui-mcp

There is nothing to install: the server starts with the app. An agent
launches BXP Desktop, then polls the liveness probe until the app is ready to
handshake:

```bash
curl -s http://127.0.0.1:7717/health
```

`200` means the MCP `initialize` handshake will be accepted; the body also
reports whether a config is already open, whether it has unsaved edits, and
whether the approval gate is open. Then `initialize`, then `open_config` with
the path — and from there the tools act on what the user can see.

Host and port are editable under **Settings inspector → Agent control**, which
also shows the live listening address and a log of what the agent did.

**Every action is visible and reversible.** Edits are in memory until a
confirmed `save`; destructive tools (`save`, `full_run`, `delete_node`,
`exit`) pop a dialog the user must accept. An agent should expect two
non-failures: while a config loaded with errors, the editing tools are refused
with a `reason` and a `validation` summary, and a structural verb reports
`{<verb>: false, reason}` when the editor silently declines an edit, so a
`true` really does mean the tree changed.

For unattended runs the user can turn on *Agent control → Auto-approve agent
actions*, which skips the dialogs and lights a red chip in the status bar. It
is a development convenience — it is not a mode to leave on, and never
together with a non-loopback bind.
