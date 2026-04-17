# bxp-ui

Desktop companion app for [`bxp-cli`](../bxp-cli): JSON5 config editor + NDJSON
dry-run debugger. Built on [Electrobun](https://blackboard.sh/electrobun/)
(Bun + native WebView, ~14 MB bundle — not Electron).

For the CLI tool itself see [`bxp-cli/README.md`](../bxp-cli/README.md). \
For the wire protocol this UI consumes see
[`docs/bxp-ui-trace-protocol.md`](../docs/bxp-ui-trace-protocol.md).

## System requirements (Linux)

Electrobun's Linux renderer uses WebKitGTK. On Ubuntu 22.04+ / Debian 12:

```bash
sudo apt install libwebkit2gtk-4.1-0 libjavascriptcoregtk-4.1-0 \
    libgtk-3-0 libayatana-appindicator3-1
```

macOS and Windows work too but are untested in this project. Use WSL2 if you're
on Windows and want to try.

## Install

Requires [Bun](https://bun.sh) ≥ 1.3.

```bash
cd bxp-ui
bun install
```

bxp-ui spawns `bxp-cli` and `bxp-fmt` as child processes, so build those first:

```bash
(cd ../bxp-cli && zig build)
(cd ../bxp-fmt && zig build)
```

## Develop

```bash
# HMR: Vite dev server (:5173) + Electrobun watcher in parallel
bun run dev:hmr

# No HMR: one-shot build + launch
bun run start
```

HMR mode is usually what you want. Electrobun's Bun main process probes
`http://localhost:5173` on startup; if it answers the WebView loads from there,
otherwise it loads the bundled `views://mainview/index.html`.

Tailwind, shadcn-style components, CodeMirror 6, and zustand are all in the
webview bundle. See [`src/mainview/`](src/mainview/) for the React layer.

## Project layout

```
bxp-ui/
├── src/
│   ├── bun/index.ts              # Main process: window, RPC, spawns bxp-cli/bxp-fmt
│   ├── shared/types.ts           # AppRPCType (bun <-> webview schema)
│   └── mainview/
│       ├── App.tsx               # Top-level Config | Debug | Expr tabs
│       ├── main.tsx              # Electroview init
│       ├── store.ts              # zustand: trace model + config draft/undo
│       ├── trace/                # NDJSON parser + TraceBuilder + types
│       ├── expr/                 # bxp-expr CM6 language + catalog + highlighter
│       └── components/           # TopBar, FileList, RowList, RowDetail,
│                                 # ConfigView, ConfigTree, ExprEditor, ...
├── electrobun.config.ts
├── vite.config.ts                # root=src/mainview, outDir=../../dist
├── tailwind.config.js
├── postcss.config.js
└── package.json
```

## Runtime binary resolution

Both `bxp-cli` and `bxp-fmt` are located at startup by
[`findSiblingBin`](src/bun/index.ts) in this priority order:

1. `$BXP_CLI_PATH` / `$BXP_FMT_PATH` env override.
2. Packaged builds: `Resources/app/bin/bxp-cli` (resolved via `import.meta.dir`).
3. Dev / source tree: walk up from `import.meta.dir` and `process.cwd()`
   looking for `bxp-cli/zig-out/bin/bxp-cli` (and sibling for `bxp-fmt`).

If none match, startup logs the list of paths it tried and the UI's "Run
Dry-Run" will fail with a clear `ENOENT`.

## RPC schema

Defined in [`src/shared/types.ts`](src/shared/types.ts):

| Direction       | Name          | Params                        | Response                                |
| --------------- | ------------- | ----------------------------- | --------------------------------------- |
| webview → bun   | `runDryRun`   | `{configPath, templateId?}`   | `{exitCode, stderr}`                    |
| webview → bun   | `loadConfig`  | `{path}`                      | `{rawText, validationError}`            |
| webview → bun   | `saveConfig`  | `{path, text}`                | `{ok, error}`                           |
| webview → bun   | `validateExpr`| `{expr}`                      | `{ok, error}`                           |
| bun → webview   | `traceEvent`  | `{line}` (one NDJSON line)    | —                                       |
| bun → webview   | `stderr`      | `{chunk}`                     | —                                       |

`runDryRun` spawns `bxp-cli --config <path> --dry-run --trace [--template <id>]`
and streams stdout line-by-line back via `traceEvent`. `loadConfig` reads the
file and runs `bxp-fmt --config <path>` for structural validation.
`validateExpr` runs `bxp-fmt --expr <text>` — used for the expression editor's
live lint markers.

`BrowserView.defineRPC` on the bun side is configured with
`maxRequestTime: Number.POSITIVE_INFINITY` so long dry-runs don't time out.

## Build and package

```bash
# Dev channel bundle (no installer archive):
bun run build

# Canary channel: full distributable with ZSTD archive + tar.gz installer:
bun run build:canary
```

Both scripts run [`scripts/stage-bins.sh`](scripts/stage-bins.sh) first, which
cross-compiles `bxp-cli` and `bxp-fmt` for `x86_64-linux-musl` (`ReleaseSmall`,
statically linked) and stages them under `build-bin/`. Electrobun's
[`build.copy`](electrobun.config.ts) then pulls them into `Resources/app/bin/`
so [`findSiblingBin`](src/bun/index.ts) resolves them at runtime (~500 kB for
both binaries combined).

Override the target with the `BXP_UI_BIN_TARGET` / `BXP_UI_BIN_OPTIMIZE`
environment variables if cross-compiling for another Linux ABI.

Outputs:

- `dist/` — Vite-bundled webview assets.
- `build/<channel>-linux-x64/bxp-ui-<channel>/` — Electrobun bundle layout
  (`bin/`, `lib/`, `Resources/app/bin/bxp-cli`, `Resources/app/bin/bxp-fmt`,
  …).
- `artifacts/canary-linux-x64-bxp-ui-canary.tar.zst` — full ZSTD-compressed
  self-extracting distributable (~32 MB; extract and run
  `bxp-ui-canary/bin/launcher`).
- `artifacts/canary-linux-x64-bxp-ui-canary-Setup.tar.gz` — plain tar.gz
  equivalent for installers that don't understand Zstandard.

## See also

- [`CLAUDE.md`](CLAUDE.md) — notes for future Claude sessions working on this app.
- [`../docs/bxp-ui-trace-protocol.md`](../docs/bxp-ui-trace-protocol.md) — NDJSON event spec.
- [`../bxp-fmt/CLAUDE.md`](../bxp-fmt/CLAUDE.md) — companion validator CLI.
