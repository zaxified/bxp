# CLAUDE.md — bxp-mcp

Guidance for Claude Code when working with the bxp-mcp package.
For monorepo-level context see [`../CLAUDE.md`](../CLAUDE.md).

## Purpose

**bxp-mcp** — an MCP server (Model Context Protocol, JSON-RPC 2.0 over **stdio**)
that exposes bxp's stateless surface as agent-callable tools. It lets an AI
agent validate bxp-cli configs, evaluate bxp expressions, and read the bxp
language docs without the user driving the GUI.

It is one of several adapters over a single shared core
(`bxp-core/src/inspect.zig`):

- **bxp-mcp** — MCP/stdio adapter (this package). _Shipped._
- **bxp-gui-bridge** — FFI adapter for the Dart GUI (in-process). _Shipped._
- **bxp-api** — HTTP/port adapter for remote/web callers. _Future direction,
  folded into the AXP-driven transport core; not a committed bxp milestone and
  not on `docs/dev/roadmap.md`._

(A former **bxp-fmt** CLI adapter, argv → stdout, was removed once bxp-mcp and
the bridge covered every operation.)

"One core, thin adapters": none of the adapters owns the stateless logic — it
lives in `inspect`. The transport choice follows from **who** calls and **from
where**: stdio = a local agent that spawns the server (private pipe, 1:1, zero
config); FFI = the local Dart GUI; a port = remote/shared/web (that's bxp-api's
job).

## In-process, no spawn

bxp-mcp calls `bxp-core`'s `inspect` module **directly in-process** for every
stateless tool. A tool call is a function call, not a process spawn — latency is
microseconds. `bxp-mcp` path-deps `bxp-core` and imports only the `inspect`
module.

**The one exception is `bxp_simulate`** (see `sim.zig`): a full conversion is
not a stateless inspect op — it needs `bxp-cli`'s `processBroker` pipeline,
filesystem input/output, and the worker pool. That tool deliberately **spawns
the co-located `bxp-cli`** (the established bridge pattern: the heavy workhorse
runs as a child, the adapter translates). The "no spawn" rule is about
µs-latency stateless calls; a full run is inherently heavyweight, so the spawn
cost is noise. `bxp-mcp` locates `bxp-cli` **next to its own executable** — both
ship co-located in the console archive and inside the bxp-gui bundle, so the
agent always invokes it from a location where `bxp-cli` sits alongside.

## Tools (today)

| Tool | inspect call | Returns |
| ---- | ------------ | ------- |
| `bxp_validate` | `annotateRaw(config_text, "<config>", 0)` | Annotated JSON with `$err_`/`$warn_`/`$info_` diagnostics inserted before each offending key. |
| `bxp_validate_expr` | `validateExprJson(expr)` | Authoring-time verdict for one expression: runtime eval + the static FnArgDoc lint (e.g. a literal `SPLIT_PART(…, 0)`). `{"ok":true}` or `{"ok":false,"error","detail","off","len"}`. The MCP analogue of the GUI bridge's `bridge_eval_expr`. |
| `bxp_eval` | `evalExpr(expr, headers?, fields?)` | Lenient runtime value: `{"ok":true,"value":"..."}` or `{"ok":false,"error","detail","off","len"}`. |
| `bxp_eval_batch` | `evalBatch(request)` | `{"results":[{"ok",…}, …]}` aligned to input order. The call `arguments` object _is_ the request `{headers, fields, exprs, maps?, lookups?, single_prepass_name?}`. |
| `bxp_eval_trace` | `evalTrace(expr, headers?, fields?, out)` | NDJSON: one `{"fn",…,"value"}` line per function call, then `{"t":"final","value":…}` or `{"t":"error",…}`. |
| `bxp_docs` | `docsJson()` | Full language/schema JSON (`functions`, `keywords`, `operators`, `tokens`, `config_schema`). |
| `bxp_list_templates` | `listTemplates(config_text)` | `{"templates":[{id,data_dir,…}, …]}`; no semantic validation. |
| `bxp_fetch_template` | `fetchTemplate(config_text, id)` | The raw template JSON, or `{"$err_1":"…"}` when the id / config is bad. |
| `bxp_simulate` | spawns `bxp-cli` (see `sim.zig`) | Runs the chosen template end-to-end against the supplied CSV. `{ok:true, exit_code, status, input, outputs:[{file,records,csv}], output_records, summary, diagnostics, trace, workspace}`. All `records` counts (input + per-output + `output_records`) are **data rows, header excluded**, so they line up with `trace.source_rows` / `written_rows`. An output that can't be read back (e.g. exceeds the 16 MB cap) appears as `{file,error}` instead of `{file,records,csv}` — never silently dropped. `trace` is the BXTB sidecar folded in (per-row filtered/error/output counts + capped samples with input line numbers). `ok:false` only on orchestration failure (no run). CSV-input templates only. Declares an `outputSchema`. |

`bxp_validate` runs with `check_fs = 0` (pure structural/expression validation,
no filesystem syscalls — the agent validates config _text_, not a deployed tree).
Unlike the CLI's `--list-templates`/`--fetch-template` (which read a config _file_
by path), the MCP tools take config _text_ — consistent with `bxp_validate` and
the no-spawn, no-filesystem stance: the agent passes the config it is authoring.

### Annotated-JSON marker shape (`bxp_validate`)

`annotateRaw` returns the config as ordinary JSON with reserved `$`-prefixed
**sibling** keys inserted immediately before the offending key (appended at the
end of the parent when the offending key is absent). All prefixes share one
monotonically-increasing `<N>` counter, so every sibling key is unique.

| Key prefix  | Value                                           | Meaning                |
| ----------- | ----------------------------------------------- | ---------------------- |
| `$err_<N>`  | marker object (below)                           | Validation error.      |
| `$warn_<N>` | same shape                                      | Non-fatal warning.     |
| `$info_<N>` | same shape                                      | Informational finding. |

```jsonc
{ "message": "...", "off"?: N, "len"?: N, "line"?: N, "col"?: N, "suggest"?: "..." }
```

`message` is the only key always present. `off`/`len` are byte offsets into the
**expression** source string of the offending token; `line`/`col` are the 1-based
position in the **config file**, carried by the diagnostics the config loader's
own scanner produces (JSON5 syntax errors and duplicate keys). `suggest` is the
did-you-mean hint. A consumer that reads only `message` is unaffected by the
optional keys.

That is why a JSON5 syntax error now arrives positioned rather than as a bare
error name — the loader is re-run over the same bytes to recover the position
even when no annotated document can be built:

```jsonc
// `data_dir: [1,,]` on line 4
{ "$err_1": { "message": "unexpected character — check for missing quotes, commas, or brackets",
              "line": 4, "col": 22 } }
```

One legacy form survives: `inspect.formatRootErr` emits `$err_<N>` with a bare
**string** value for a root error, so a strict consumer must branch on the value
type. **No `$comm_<N>` key is ever emitted** — the JSON5 preprocessor strips
comments in the annotated variant exactly as in the plain one (the `json5`
module has a test asserting the key never appears).

## Source layout

```text
bxp-mcp/
  src/
    main.zig    ← entry: arena, --help, identity + INSTRUCTIONS,
                  tools.register(), mcp.Server.serveStdio()
    tools.zig   ← tool catalog + handlers → inspect calls (+ sim for bxp_simulate);
                  `register` pairs each catalog row with its handler
    sim.zig     ← bxp_simulate orchestration: stage config+CSV in a scratch
                  workspace, spawn the co-located bxp-cli (+ --trace-file BXTB
                  sidecar parsed via btrace.Reader), read output, diff, trace
  build.zig     ← path-deps ../bxp-core, imports `inspect` + `btrace` + `mcp`
  build.zig.zon
```

The JSON-RPC layer is the zig-libs **`mcp`** module (taken off bxp-core's single
zig-libs pin — see `../bxp-core/build.zig`). It owns the framing, the handshake,
`tools/list`, dispatch-by-name, `structuredContent` gating and progress; this
package owns the catalog, the nine handlers and `bxp_simulate`'s orchestration.

That module is not a third-party adoption but a **homecoming**: it *is* this
package's former `server.zig`, extracted upstream on 2026-07-04
(`mcp: … extracted from bxp-mcp`) and hardened there. Which is why the migration
was near-free — `isSingleJsonObject`, the `tools/list` serializer and every
JSON-RPC error string were already byte-identical to ours. What upstream added
on top: resources + prompts + sampling/elicitation, a 16 MiB `max_line_len` cap,
JSON-RPC §4 id validation, a JSON-escaped progress message, and 89 unit tests
where the local transport had none.

Handler shape is `fn(ctx: ?*anyopaque, call: *mcp.ToolCall) bool` — `call.arena`
is the per-request arena, `call.strArg` reads an argument, `call.write` appends
the result, `call.fail` marks a tool failure, `call.reportProgress` emits a
progress notification. `ctx` is `tools.App` (the live `io` + `environ_map`);
only `bxp_simulate` reads it, to spawn bxp-cli.

`tool_docs` deliberately stays a plain `ToolDoc` table rather than becoming
`mcp.Tool` directly: `tools/zig-doc-gen` compiles this file for the catalog
alone, and handler pointers in the table would drag `sim` → `btrace` into the
docs generator. `register` is the single place that pairs a row with a handler,
and both halves of that pairing are compile-time checked (`tagFor` rejects a
catalog name with no enum tag, `handlerFor`'s exhaustive switch rejects a tag
with no handler).

## MCP wire protocol

Newline-delimited JSON-RPC 2.0 over stdin/stdout — one JSON object per line.
Protocol version `2025-11-25` (also accepts + echoes `2025-06-18`; see the
`mcp` module's `negotiateVersion`). The client (agent host) spawns this process
and pipes requests; the server reads stdin, writes one response line per
request to stdout. stderr is free for logs. A single line is capped at
`mcp.max_line_len` (16 MiB); an over-long line ends the session like EOF.

- **request** (has `id`) → exactly one response line with the same `id`.
- **notification** (no `id`, e.g. `notifications/initialized`) → no response.
- **response** → `result` or `error: {code, message}`. A tool result is
  `{content:[{type:text,text}], isError}`. `isError` is `true` only for a tool
  *failure* (a missing required argument, an unexpected Zig error, a spawn/IO
  problem); a domain `{"ok":false,…}` answer (an expression error, a
  not-found-but-asked template id, an orchestration report) keeps `isError:false`
  — it is a valid result the agent should read. `structuredContent` (the parsed
  object) is added when the tool's declared output is a single JSON object;
  `bxp_eval_trace` is NDJSON by identity and stays text-only even when a
  function-free expression happens to emit a single sentinel line.
- **server→client** `notifications/progress` are emitted mid-call for a
  request that supplied `params._meta.progressToken` (`call.reportProgress`;
  `bxp_simulate` reports four lifecycle phases).

Methods handled: `initialize`, `tools/list`, `tools/call`, `ping`,
`notifications/initialized`. JSON-RPC 2.0 is the final/only version of JSON-RPC;
MCP itself is what carries dated versions.

Since the `mcp` migration the server also answers the other two MCP primitives
— `resources/list`, `resources/read`, `resources/templates/list`,
`prompts/list`, `prompts/get` — with empty catalogs (and `-32002` /
`-32602` for a read/get against them). bxp registers none of either today; the
methods are served, they just have nothing in them. Since the `2026-08-19` pin
they are no longer *advertised*: upstream gates each capability key on its own
catalog being non-empty, so `initialize` answers
`"capabilities":{"tools":{"listChanged":false}}` — one key, not three. The
methods still respond; a spec-conformant client simply is not told to call them
(`ServerCapabilities` marks all three optional, "Present if the server offers
any …"). `tools` stays unconditional.

Two smaller wire-visible changes came with the same migration (all three are
pinned by the 100-series in `scripts/test-02-mcp.sh`):

- **A non-scalar `id` is refused, not served.** `{"id":{"a":1},"method":"ping"}`
  now comes back as `-32600 Invalid request id` with `id:null`; the local
  transport used to answer the call. JSON-RPC 2.0 requires the id to be echoed
  verbatim, and an object id is a shape the module declines to carry rather than
  silently reduce.
- **A response-shaped line is dropped in silence.** A line carrying `id` +
  `result` but no `method` (i.e. something the *client* should have received) now
  produces no output at all; the local transport answered `-32600 Missing
  method`. Answering a response with an error is itself a protocol violation, so
  the module treats such a line the way it treats a notification.

## Build and run

```bash
cd bxp-mcp
zig build
zig build test          # unit tests (sim.zig pure helpers)
./zig-out/bin/bxp-mcp --help

# Drive it manually (one JSON-RPC object per line on stdin):
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"bxp_eval","arguments":{"expr":"UPPER(\x27hi\x27)"}}}' \
  | ./zig-out/bin/bxp-mcp
```

Register with an MCP client (e.g. Claude Code, `~/.claude.json`):

```json
{ "mcpServers": { "bxp": { "command": "/abs/path/to/bxp-mcp", "args": [] } } }
```

## Coding conventions

- All code comments and documentation in English.
- Zig 0.16.0 API — use the zig skill before writing new code.
- One dependency beyond the `bxp-core` path dep: the zig-libs `mcp` module,
  taken through bxp-core's re-export so this package shares that single pin
  rather than carrying a `zig_libs` entry of its own. `mcp` is itself pure
  `std` with no deps, so the transitive surface stays at zero.

## Status & forward work

**Shipped.** The stateless surface is fully deduplicated onto
`bxp-core/src/inspect.zig` — config annotation, single-expression validation
(`bxp_validate_expr`) and evaluation, expr-trace, expr-batch, docs, and template
list/fetch all call shared `inspect` functions. `bxp_simulate` spawns the
co-located `bxp-cli` (CSV-input templates only) and folds a per-row BXTB sidecar
trace into a structured report with a record-count diff. Protocol depth is in:
`structuredContent` (gated by tool identity), an `outputSchema` for
`bxp_simulate`, protocol `2025-11-25` with version negotiation, and opt-in
`notifications/progress`. Each message is handled on a per-message arena freed
after the response is written.

**Transport migrated to the zig-libs `mcp` module** (2026-08-16), retiring the
local `server.zig` + `progress.zig` (427 lines). Gated by a differential probe:
79 JSON-RPC lines — malformed input, batch arrays, notifications without `id`,
non-scalar and null ids, unknown methods/tools, every argument-validation path,
all nine tools, and `bxp_simulate` with a string / integer / malformed
progressToken — replayed against the pre- and post-migration binaries. Result:
**42/42 responses and all 8 progress notifications byte-identical**, except the
three wire-visible changes recorded in the wire-protocol section above:
`initialize` advertising the `resources` + `prompts` capabilities the module
serves (reverted upstream at the `2026-08-19` pin — the keys are gated on a
non-empty catalog now, so bxp is back to advertising `tools` alone), a
non-scalar `id` refused with `-32600 Invalid request id` where it used to be
served, and a response-shaped line dropped in silence where it used to draw
`-32600 Missing method`.

The standing gate is `scripts/test-02-mcp.sh`, extended in the same change with
the wiring seams the probe had surfaced (the 100-series requests): every
JSON-RPC error path this binary routes, an unknown tool answered by *our*
catalog as `-32602`, a missing / non-string argument reaching the handler's own
failure instead of being coerced, the empty resources + prompts catalogs that
are our registration state — asserted from the handshake side too since the
`2026-08-19` pin, where `initialize.capabilities` must carry `tools` and
nothing else — and, the one that matters on a long-lived stdio
session, a real tool call still answering after a run of malformed lines. It
deliberately does **not** re-test the framing for its own sake: that is the
module's, and it has 89 tests upstream.

The former **bxp-fmt** CLI adapter was the original third wrapper over `inspect`;
it was removed once bxp-mcp + the GUI bridge covered every operation (the console
archive now ships `bxp-mcp` in its place; tests drive `inspect` via bxp-mcp / the
bridge).

**Forward — bxp-api sibling.** An HTTP/port adapter over the same `inspect`,
not a committed milestone. It would mount the *same* `mcp.Server` this package
already builds through the zig-libs `mcp-http` middleware, so the transport
work is done; what it still needs is concurrency (thread pool / event loop),
which stdio does not. The separate GUI-side **gui-mcp** Dart MCP server for
agent-controlled GUI ops (open-config / edit / dry-run / save / exit) is
**shipped** — see [`../bxp-gui/CLAUDE.md`](../bxp-gui/CLAUDE.md) "Agent control"
and [`../docs/dev/mcp.md`](../docs/dev/mcp.md) for how it differs from this stdio server.

## Known non-issues (audit-acknowledged)

Residual 🔵 notes from the 2026-06-14 audit (all 🟠/🟡 fixed). They share one
**threat model**: the stdio server is **single-process + single-threaded** and
stdin is a **trusted 1:1 local pipe** from the spawning agent host. The caps
and races below are bounded by that model and only re-open under a future
**threaded `bxp-api` sibling** or a network transport over the same `sim.zig` —
revisit them there.

- **`sim.zig` wipes the reused workspace on every call** (`deleteTree` +
  `makePath`). Two concurrent `bxp_simulate` calls sharing a `workspace` id
  (default = template id) would race wipe-vs-read; single-threaded stdio makes
  that unreachable today. Path is confined to `tmp_base/bxp-mcp-sim/<uid>`.
- **`sim.zig tmpDir` trusts `TMPDIR`/`TMP`/`TEMP`.** Standard, and the env is
  the user's own; the subsequent `deleteTree` only ever targets the sanitized
  `bxp-mcp-sim/<uid>` subtree, so a redirected temp base cannot widen the
  delete blast radius.
- ~~**`server.zig readLine` grows `line_buf` unboundedly**~~ — **resolved
  2026-08-16** by the `mcp` migration: the module's `readLine` caps a line at
  `mcp.max_line_len` (16 MiB), so a peer that never sends a `\n` can no longer
  drive unbounded growth. The cap ends the session like EOF rather than
  answering an oversize JSON-RPC error, which is the weaker half of the fix —
  and it is a real ceiling on `bxp_simulate`, whose `csv` argument rides inline
  in the request line. A >16 MiB sample CSV now drops the session instead of
  converting. Revisit the shape (explicit `-32600`) if that ceiling is ever hit
  in practice, or when the bxp-api sibling exposes the same reader to untrusted
  input.
- **`sim.zig` output capture is confined to `data_dir`.** A template whose
  output path escapes `--data` (absolute, or `..` in `file_pattern_out`) writes
  outside and is never read back → `output_records` 0 and a misleading
  input-vs-output diff. Edge / config-dependent; "everything in `data_dir`" is
  the documented design.
