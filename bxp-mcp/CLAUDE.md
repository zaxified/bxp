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
  folded into the AXP-driven transport core (see `docs/roadmap.md` → "Shared
  core libraries"); not a committed bxp milestone._

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

## Source layout

```text
bxp-mcp/
  src/
    main.zig    ← entry: arena, --help, server.run()
    server.zig  ← MCP stdio loop + JSON-RPC writers (pure std.json); per-request
                  arena reset between calls
    tools.zig   ← tool catalog + handlers → inspect calls (+ sim for bxp_simulate)
    sim.zig     ← bxp_simulate orchestration: stage config+CSV in a scratch
                  workspace, spawn the co-located bxp-cli (+ --trace-file BXTB
                  sidecar parsed via btrace.Reader), read output, diff, trace
    progress.zig ← server→client notifications/progress (opt-in via
                  params._meta.progressToken); used by bxp_simulate phases
  build.zig     ← path-deps ../bxp-core, imports the `inspect` + `btrace` modules
  build.zig.zon
```

The JSON-RPC layer is hand-written over `std.json` (parse incoming line →
`std.json.Value`; serialize ids/strings via `std.json.Stringify`). No
third-party code. (The `mcp-zig` project was studied as a protocol reference
only — see the roadmap memory; nothing was vendored.)

## MCP wire protocol

Newline-delimited JSON-RPC 2.0 over stdin/stdout — one JSON object per line.
Protocol version `2025-11-25` (also accepts + echoes `2025-06-18`; see
`negotiateVersion`). The client (agent host) spawns this process and pipes
requests; the server reads stdin, writes one response line per request to
stdout. stderr is free for logs.

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
  request that supplied `params._meta.progressToken` (see `progress.zig`).

Methods handled: `initialize`, `tools/list`, `tools/call`, `ping`,
`notifications/initialized`. JSON-RPC 2.0 is the final/only version of JSON-RPC;
MCP itself is what carries dated versions.

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
- Pure `std`, zero external dependencies (only the `bxp-core` path dep).

## Status & forward work

**Shipped.** The stateless surface is fully deduplicated onto
`bxp-core/src/inspect.zig` — config annotation, single-expression validation
(`bxp_validate_expr`) and evaluation, expr-trace, expr-batch, docs, and template
list/fetch all call shared `inspect` functions. `bxp_simulate` spawns the
co-located `bxp-cli` (CSV-input templates only) and folds a per-row BXTB sidecar
trace into a structured report with a record-count diff. Protocol depth is in:
`structuredContent` (gated by tool identity), an `outputSchema` for
`bxp_simulate`, protocol `2025-11-25` with version negotiation, and opt-in
`notifications/progress`. The server uses a per-request arena (reset with
`retain_capacity`) plus a fresh per-request `tool_buf` (an earlier persistent
buffer aliased the next request's parse after reset — fixed).

The former **bxp-fmt** CLI adapter was the original third wrapper over `inspect`;
it was removed once bxp-mcp + the GUI bridge covered every operation (the console
archive now ships `bxp-mcp` in its place; tests drive `inspect` via bxp-mcp / the
bridge).

**Forward — bxp-api sibling.** An HTTP/port adapter over the same `inspect`,
folded into the AXP-driven transport-core direction (see `docs/roadmap.md` →
"Shared core libraries"); needs concurrency (thread pool / event loop), which
stdio does not. The separate GUI-side **gui-mcp** Dart MCP server for
agent-controlled GUI ops (open-config / edit / dry-run / save / exit) is
**shipped** — see [`../bxp-gui/CLAUDE.md`](../bxp-gui/CLAUDE.md) "Agent control"
and [`../docs/mcp.md`](../docs/mcp.md) for how it differs from this stdio server.

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
- **`server.zig readLine` grows `line_buf` unboundedly** (no max-line cap), so
  a multi-GB request line OOMs the server. Same "uncapped text entry point"
  theme as `inspect.zig`; low risk on the trusted local pipe. A generous cap
  (a few× the 1 MB config limit) + an oversize JSON-RPC error would bound it —
  do this when the bxp-api sibling exposes the same reader to untrusted input.
- **`sim.zig` output capture is confined to `data_dir`.** A template whose
  output path escapes `--data` (absolute, or `..` in `file_pattern_out`) writes
  outside and is never read back → `output_records` 0 and a misleading
  input-vs-output diff. Edge / config-dependent; "everything in `data_dir`" is
  the documented design.
