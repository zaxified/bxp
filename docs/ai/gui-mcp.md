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
  (++ctrl+shift+s++), where you can also see the live listening address and a
  log of what the agent did.
- **Connecting** — the agent launches BXP Desktop, polls `GET /health` until it
  returns `200`, then runs the MCP `initialize` handshake and calls
  `open_config` with the path it wrote.
- **Safety** — the server binds loopback only. Critical actions (`save`,
  `full_run`, `delete_node`, `exit`) pop a confirmation dialog you must accept.

You stay in control throughout: every agent edit is revealed in the tree
where it happens, and nothing is written or run without your click.

## Help with the GUI itself

If you're stuck navigating bxp-gui — finding a feature, understanding an
error message, choosing between dry-run and full-run — paste the docs into
your assistant and ask:

> *"I use BXP Desktop. Please read the BXP docs. I'm trying to `<describe
> what you want to accomplish>`. The GUI is showing `<paste any error chip
> text or describe the screen>`. Which features should I use, and what
> keyboard shortcuts apply?"*

The assistant has the keyboard shortcut table, advanced feature
descriptions, exit-code semantics, and bundled binary reference — enough
to walk you through almost any GUI workflow.

## Debugging an expression that returns wrong values

Open the expression in the playground (right-rail panel). Click
**Variables** and pick a row that produces the wrong result. Copy the
NDJSON trace lines (Settings inspector → trace section) and the
expression text into your assistant:

> *"This BXP expression `<paste expression>` should produce `<expected>`
> for input row `<paste row from variables panel>` but instead produces
> `<actual>`. The per-call trace looks like `<paste NDJSON lines>`.
> What's wrong with the expression?"*

The trace makes the AI's job almost mechanical — every nested function
call's input and output is visible.
