# CLAUDE.md — bxp-mcp

Guidance for Claude Code when working with the bxp-mcp package.
For monorepo-level context see [`../CLAUDE.md`](../CLAUDE.md).

## Purpose

**bxp-mcp** — an MCP server (Model Context Protocol, JSON-RPC 2.0 over **stdio**)
that exposes bxp's stateless surface as agent-callable tools. It lets an AI
agent validate bxp-cli configs, evaluate bxp expressions, and read the bxp
language docs without the user driving the GUI.

It is one of three planned adapters over a single shared core
(`bxp-core/src/inspect.zig`):

- **bxp-fmt** — CLI adapter (argv → stdout). _Existing._
- **bxp-mcp** — MCP/stdio adapter (this package). _New._
- **bxp-api** — HTTP/port adapter for remote/web callers. _Planned, separate
  component._

"One core, thin adapters": none of the three owns the stateless logic — it
lives in `inspect`. The transport choice follows from **who** calls and **from
where**: stdio = a local agent that spawns the server (private pipe, 1:1, zero
config); a port = remote/shared/web (that's bxp-api's job).

## In-process, no spawn

Unlike the standalone `bxp-rpc` MVP (which shelled out to the `bxp-fmt` binary),
bxp-mcp calls `bxp-core`'s `inspect` module **directly in-process** for every
stateless tool. A tool call is a function call, not a process spawn — latency is
microseconds. `bxp-mcp` path-deps `bxp-core` and imports only the `inspect`
module.

**The one exception is `bxp_simulate`** (see `sim.zig`): a full conversion is
not a stateless inspect op — it needs `bxp-cli`'s `processBroker` pipeline,
filesystem input/output, and the worker pool. That tool deliberately **spawns
the co-located `bxp-cli`** (the established bridge/fmt pattern: the heavy
workhorse runs as a child, the adapter translates). The "no spawn" rule is about
µs-latency stateless calls; a full run is inherently heavyweight, so the spawn
cost is noise. `bxp-mcp` locates `bxp-cli` **next to its own executable** — it
ships inside the same bxp-gui bundle as `bxp-cli`/`bxp-fmt`, so the agent always
invokes it from a location where `bxp-cli` sits alongside.

## Tools (today)

| Tool | inspect call | Returns |
| ---- | ------------ | ------- |
| `bxp_validate` | `annotateRaw(config_text, "<config>", 0)` | Annotated JSON with `$err_`/`$warn_`/`$info_` diagnostics (byte-identical to `bxp-fmt --config`). |
| `bxp_eval` | `evalExpr(expr, headers?, fields?)` | `{"ok":true,"value":"..."}` or `{"ok":false,"error","detail","off","len"}`. |
| `bxp_eval_batch` | `evalBatch(request)` | `{"results":[{"ok",…}, …]}` (byte-identical to `bxp-fmt --expr-batch`). The call `arguments` object _is_ the request `{headers, fields, exprs, ticker_map?, lookups?, single_prepass_name?}`. |
| `bxp_docs` | `docsJson()` | Full language/schema JSON (`functions`, `keywords`, `operators`, `tokens`, `config_schema`). |
| `bxp_list_templates` | `listTemplates(config_text)` | `{"templates":[{id,data_dir,…}, …]}` (byte-identical to `bxp-fmt --config … --list-templates`); no semantic validation. |
| `bxp_fetch_template` | `fetchTemplate(config_text, id)` | The raw template JSON, or `{"$err_1":"…"}` when the id / config is bad (byte-identical to `bxp-fmt --config … --fetch-template <id>`). |
| `bxp_simulate` | spawns `bxp-cli` (see `sim.zig`) | Runs the chosen template end-to-end against the supplied CSV. `{ok:true, exit_code, status, input, outputs:[{file,records,csv}], output_records, summary, diagnostics, workspace}`. `ok:false` only on orchestration failure (no run). CSV-input templates only. |

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
                  workspace, spawn the co-located bxp-cli, read output, diff
  build.zig     ← path-deps ../bxp-core, imports the `inspect` module
  build.zig.zon
```

The JSON-RPC layer is hand-written over `std.json` (parse incoming line →
`std.json.Value`; serialize ids/strings via `std.json.Stringify`). No
third-party code. (The `mcp-zig` project was studied as a protocol reference
only — see the roadmap memory; nothing was vendored.)

## MCP wire protocol

Newline-delimited JSON-RPC 2.0 over stdin/stdout — one JSON object per line.
Protocol version `2025-06-18`. The client (agent host) spawns this process and
pipes requests; the server reads stdin, writes one response line per request to
stdout. stderr is free for logs.

- **request** (has `id`) → exactly one response line with the same `id`.
- **notification** (no `id`, e.g. `notifications/initialized`) → no response.
- **response** → `result` or `error: {code, message}`.

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
- Zig 0.15.2 API — use the zig skill before writing new code.
- Pure `std`, zero external dependencies (only the `bxp-core` path dep).

## TODO / remaining details (ordered)

1. **fmt dedup — ✅ DONE (2026-06-08).** `inspect` is now the single source of
   truth. `bxp-fmt`'s `runConfig` calls `inspect.annotateConfigFromFile`; the
   config-annotate pipeline (`annotateRaw`, `annotateConfigFromFile`,
   `AnnotateResult`, `formatRootErr`, `valueToJsonString`, `injectSemanticErrors`,
   `insertErrBefore`, `insertNumberedBefore`, `injectDiagnostics`, `getPtrAtPath`,
   `fieldValueStr`, `escapeForDisplay`) was deleted from `bxp-fmt/src/main.zig`
   (`readFileCapped` + `CONFIG_MAX_FILE_SIZE` kept for `loadConfigValue`). fmt's
   ~10 inline `annotateRaw` tests resolve via `const annotateRaw =
   inspect.annotateRaw;`; the `inspect` module is wired into both the exe and
   `main_tests` in `bxp-fmt/build.zig`. Verified: `test-01-console.sh` green and
   `bxp-mcp bxp_validate` byte-identical to `bxp-fmt --config` on two datasets.

2. **Share the expr-trace core.** `bxp-fmt --expr-trace` streams per-call
   NDJSON to stdout (GUI playground contract) and sends its error sentinel to
   stderr; `inspect.evalExpr` returns a single `{ok,value}`/`{ok:false,…}`
   result instead. They share `expr.evalString` but not the output shaping.
   Factor a common eval core if/when a second NDJSON-streaming consumer appears.

3. **More tools — ✅ DONE (2026-06-08).** `bxp_eval_batch`, `bxp_list_templates`,
   and `bxp_fetch_template` shipped. The `--expr-batch` core moved into
   `inspect.evalBatch` (bxp-fmt's `runExprBatchBytes` is now a thin
   parse-stdin→delegate wrapper); the template-walk + fetch logic moved into
   `inspect.listTemplatesValue`/`fetchTemplateValue` (bxp-fmt keeps the file
   load + stdout, calls the `…Value` cores), with text-input wrappers
   `inspect.listTemplates`/`fetchTemplate` for the MCP tools. All three verified
   **byte-identical** to their `bxp-fmt` equivalents on a dataset config.

4. **`bxp_simulate` — ✅ DONE (2026-06-08).** Chose the **spawn** path (not
   factoring `processBroker` into core): `sim.zig` stages the agent's config
   (verbatim) + input CSV into a stable, reused scratch workspace
   (`<tmp>/bxp-mcp-sim/<uid>/`, wiped fresh per run, left for inspection), spawns
   the co-located `bxp-cli` with the **existing** `--config`/`--template`/`--data`
   flags (no new CLI surface; `--data` points the template at the scratch dir so
   the config's own `data_dir` is untouched), reads every produced output file
   back, and returns a structured report with bxp-mcp's own record-count **diff**
   + status. CSV-input templates only (xlsx/JSON input rejected with a clear
   message). Verified: output **byte-identical** to the trading212 dataset's
   `.expected`. Per-row drop-reason (which input row produced nothing) is a
   future extension — it needs the BXTB `--trace` translation we deliberately
   deferred; the `--debug` text dump is too fragile to parse.

5. **Protocol depth.** Server→client notifications (progress for long runs),
   `structuredContent` in tool results, bump MCP to `2025-11-25`. Add when a
   tool needs streaming progress.

6. **Per-request arena — ✅ DONE (2026-06-08).** `Session` now holds a separate
   `req_arena` reset with `retain_capacity` after every request; the base
   process arena keeps only startup (argv) + the persistent reused buffers
   (`line_buf`/`out_buf`/`tool_buf`, which retain capacity across requests). All
   transient per-request work — the incoming JSON parse, `tools.dispatch`, and
   the id/string serialization temps in `appendId`/`appendJsonString` — routes
   through `req_arena`, so memory reaches a steady state sized to the largest
   single request instead of growing one request's allocations per call.

7. **GUI + bridge migration.** Today bxp-gui/bridge spawn `bxp-fmt` per call.
   They can talk to a long-lived `bxp-mcp` instead (no per-call spawn). Separate
   workstream; bxp-fmt stays for the console readme / tests regardless.

8. **bxp-api sibling.** The HTTP/port adapter over the same `inspect`. New
   component when the web/remote case is real; needs concurrency (thread pool /
   event loop), which stdio does not.
