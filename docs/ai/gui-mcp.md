---
description: "Drive the running desktop app from an agent over its embedded MCP server — open a config, edit it, dry-run it, read the trace."
---

# Driving the GUI with an agent (gui-mcp)

BXP Desktop runs a small **MCP control server** so a local AI agent can
read and edit the live config in the running app — the same actions you
take by hand, but driven step by step while you watch and approve. This
is the half of the workflow where, after an agent has drafted a config
(see [Authoring a broker](authoring-a-broker.md)), the two of you
fine-tune the tricky expressions together inside the GUI.

The full list of agent-callable tools is in [GUI agent
tools](../reference/gui-agent-tools.md).

- **Endpoint** — `http://127.0.0.1:7717/mcp` (StreamableHTTP). The host and
  port are editable under **Settings inspector → Agent control**
  (ctrl+shift+s), where you can also see the live listening address and a
  log of what the agent did.
- **Connecting** — the agent launches BXP Desktop, polls `GET /health` until it
  returns `200`, then runs the MCP `initialize` handshake and calls
  `open_config` with the path it wrote. `GET /health` (and `GET /`) is the
  bare liveness probe the embedded server answers as soon as its loopback
  socket binds — it returns `200` only once the app is ready to accept the
  MCP handshake, so the agent uses it to wait out startup instead of racing
  the first `initialize`.
- **Safety** — the server binds loopback (`127.0.0.1`) **by default**, and
  destructive actions (`save`, `full_run`, `delete_node`, `exit`) pop a
  confirmation dialog you must accept. Two settings loosen that, both under
  **Agent control**:
    - **Auto-approve agent actions** — off by default; turning it on skips
      every confirmation dialog so an agent can drive the app unattended. A
      red status-bar chip shows when it is on. It is a development
      convenience, not a mode to leave enabled.
    - **Origin allowlist** — **empty by default, which accepts every
      `Origin`**. This is deliberate: webview-based agents send the page's
      `Origin` and would otherwise be locked out. The loopback bind is what
      keeps the surface local. If you rebind to a network interface, set an
      allowlist — and leave auto-approve off, since permissive origins plus
      auto-approve means unauthenticated control of the app.
- **Refusals** — the editing tools (`edit_node`, `insert_node`,
  `rename_key`, `move_node`, `delete_node`) are refused outright while the
  config was loaded with errors, and `save` refuses *before* prompting when
  validation errors are attached. The structural tools also report
  `{<verb>: false, reason}` rather than a false success when the editor
  silently declines an edit — so an agent can tell "done" from "ignored".

With the defaults in place you stay in control throughout: every agent edit
is revealed in the tree where it happens, and nothing is written or run
without your click.

## Help with the GUI itself

If you're stuck navigating bxp-gui — finding a feature, understanding an
error message, choosing between dry-run and full-run — paste the docs into
your assistant and ask:

> _"I use BXP Desktop. Please read the BXP docs. I'm trying to `<describe
what you want to accomplish>`. The GUI is showing `<paste any error chip
text or describe the screen>`. Which features should I use, and what
> keyboard shortcuts apply?"_

The assistant has the keyboard shortcut table, advanced feature
descriptions, exit-code semantics, and bundled binary reference — enough
to walk you through almost any GUI workflow.

## Debugging an expression that returns wrong values

Run a dry-run, then pick the row that produces the wrong result. **ROW
SELECTED** lists that row's source fields; **ROW TRANSFORM** next to it
holds the **VARIABLES** table, and each nested function call in the
expression carries its intermediate value, evaluated against that row
in-process. Paste those into your assistant:

> _"This BXP expression `<paste expression>` should produce `<expected>`
> for input row `<paste the row's input fields>` but instead produces
> `<actual>`. The intermediate values are `<paste the per-call values>`.
> What's wrong with the expression?"_

Seeing the intermediates makes the AI's job almost mechanical — it can
point at the exact nested call where the value goes wrong instead of
guessing at the whole expression.

An agent with a terminal can get the same thing machine-readable without
the GUI: `bxp_eval_trace` (bxp-mcp) returns one JSON object per function
call plus a terminal `{"t":"final","value":…}` line. Its `headers` /
`fields` are arrays of strings, same as every other eval tool — see [Authoring a
broker](authoring-a-broker.md#self-testing-the-generated-template).
