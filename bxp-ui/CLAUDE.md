# CLAUDE.md — bxp-ui

Electrobun-based desktop app: JSON5 config editor + NDJSON dry-run debugger for
`bxp-cli`. See the approved plan for scope and phase breakdown.

## Stack

- Electrobun 1.17.3-beta.11 (Bun + native WebView, no Electron)
- React 18 + TypeScript + Tailwind CSS
- Vite 6 (dev server on :5173 for HMR)
- shadcn/ui, Monaco, zustand — added in later phases

## Layout

```text
bxp-ui/
├── src/
│   ├── bun/index.ts          # Main process: window, RPC, spawns bxp-cli
│   ├── shared/types.ts       # AppRPCType schema (bun <-> webview)
│   └── mainview/
│       ├── main.tsx          # Electroview init, Electroview.defineRPC
│       ├── App.tsx           # UI: config path input + "Run Dry-Run" + NDJSON textarea
│       ├── traceBus.ts       # Cross-component store for trace lines + stderr
│       ├── index.html
│       └── index.css         # Tailwind entry
├── electrobun.config.ts
├── vite.config.ts            # root=src/mainview, outDir=../../dist
├── tailwind.config.js
├── package.json
└── CLAUDE.md                 # this file
```

## Develop

```bash
cd bxp-ui
bun install           # first-time only

# Option A: build views once, then run Electrobun
bun run start

# Option B: HMR (Vite dev server + Electrobun watcher in parallel)
bun run dev:hmr
```

The Bun main process checks `http://localhost:5173` at startup. If reachable, the
webview loads the Vite dev URL (HMR). Otherwise it loads the bundled
`views://mainview/index.html`.

## bxp-cli binary resolution

`src/bun/index.ts` resolves the bxp-cli binary via:

1. `process.env.BXP_CLI_PATH` if set.
2. Otherwise `../../bxp-cli/zig-out/bin/bxp-cli` relative to `src/bun/index.ts`.

Before running the UI, build bxp-cli:

```bash
cd ../bxp-cli && zig build
```

Packaged builds (Phase 6) will embed bxp-cli + bxp-fmt in the Electrobun
resources directory; path resolution will switch to the resources dir at
bundle time.

## RPC schema

Defined in `src/shared/types.ts`:

- **Bun request `runDryRun`**: `{ configPath, templateId? }` → `{ exitCode, stderr }`.
  Spawns `bxp-cli --config <path> --dry-run --trace [--template <id>]`, streams
  stdout line-by-line back via `traceEvent` messages; stderr is buffered and sent
  once at the end via a `stderr` message.
- **Webview messages `traceEvent` / `stderr`**: one NDJSON line / stderr blob
  pushed into `traceBus` for the React UI to render.

This matches the NDJSON trace protocol spec (schema_version = 1) emitted by
`bxp-cli --trace` — see `bxp/docs/bxp-ui-trace-protocol.md` (Phase 0, deferred).

## Phase status

- **Phase 2 (current)**: scaffold — window opens, spawns bxp-cli, dumps raw
  NDJSON into a textarea. Proves the pipe.
- **Phase 3**: debug panel MVP (template/file picker, row navigator, variable
  watch, output preview).
- **Phase 4**: collapsible JSON tree editor with comment-preserving JSON5 round-trip.
- **Phase 5**: Monaco custom language for `bxp-expr` + live validation via `bxp-fmt --expr`.
- **Phase 6**: polish, packaging (Linux ZSTD bundle).

## Constraints

- Electrobun is **not** Electron. Do not use Electron APIs.
- Use `views://` URLs for bundled assets; `http://localhost:5173` only during HMR.
- bxp-ui never links `bxp-core` directly — all data passes through `bxp-cli`
  (runtime) or `bxp-fmt` (format/validate) via short-lived child processes.
