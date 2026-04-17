# CLAUDE.md — bxp-ui

Electrobun-based desktop app: JSON5 config editor + NDJSON dry-run debugger for
`bxp-cli`. See [`README.md`](README.md) for an overview oriented at humans.

## Stack

- Electrobun 1.17.3-beta.11 (Bun + native WebView, no Electron)
- React 18 + TypeScript + Tailwind CSS + Vite 6
- CodeMirror 6 (chosen over Monaco for bundle size and cheap inline editors)
- zustand 5 for shared state
- `json5` for initial parsing (plain JS object powers the tree UI);
  `@croct/json5-parser` for the serialize step so comments, whitespace, and
  key order from the source file survive on round-trip

## Layout

```text
bxp-ui/
├── src/
│   ├── bun/index.ts            # Main process: window, RPC, spawns bxp-cli/bxp-fmt
│   ├── shared/types.ts         # AppRPCType schema (bun <-> webview)
│   └── mainview/
│       ├── main.tsx            # Electroview init, Electroview.defineRPC
│       ├── App.tsx             # Top-level Config | Debug | Expr tabs
│       ├── store.ts            # zustand: trace model + config draft + undo/redo
│       ├── trace/              # NDJSON parser + TraceBuilder + types
│       ├── expr/               # bxp-expr CM6 language + catalog + inline highlighter
│       └── components/         # TopBar, FileList, RowList, RowDetail,
│                               # ConfigView, ConfigTree, ConfigRaw,
│                               # ExprEditor, ExprPlayground, StatusBar
├── electrobun.config.ts
├── vite.config.ts              # root=src/mainview, outDir=../../dist
├── tailwind.config.js
├── postcss.config.js
├── package.json
├── README.md
└── CLAUDE.md                   # this file
```

## Develop

```bash
cd bxp-ui
bun install

# HMR: Vite dev server + Electrobun watcher in parallel (recommended)
bun run dev:hmr

# Or one-shot build + launch
bun run start
```

The Bun main process probes `http://localhost:5173` at startup. If reachable
the WebView loads from Vite for HMR; otherwise it loads the bundled
`views://mainview/index.html`.

**Before touching `tsc` or rebuilding, kill any running HMR / Electrobun
watcher.** Running them concurrently with a type-check has pegged memory and
frozen the host in the past.

## Binary resolution (bxp-cli, bxp-fmt)

[`src/bun/index.ts`](src/bun/index.ts)'s `findSiblingBin`:

1. `$BXP_CLI_PATH` / `$BXP_FMT_PATH` env override.
2. Packaged bundle: `Resources/app/bin/<binName>`.
3. Dev: walk up from `import.meta.dir` / `process.cwd()` looking for
   `bxp-cli/zig-out/bin/bxp-cli` (and sibling for `bxp-fmt`).

Before running the UI in dev, build the Zig sides:

```bash
(cd ../bxp-cli && zig build)
(cd ../bxp-fmt && zig build)
```

## RPC schema

Defined in [`src/shared/types.ts`](src/shared/types.ts):

- **`runDryRun`** `{configPath, templateId?}` → `{exitCode, stderr}` —
  spawns `bxp-cli --config <path> --dry-run --trace [--template <id>]`,
  streams stdout line-by-line via `traceEvent` messages.
- **`loadConfig`** `{path}` → `{rawText, validationError}` — reads file and
  runs `bxp-fmt --config <path>` for validation.
- **`saveConfig`** `{path, text}` → `{ok, error}` — writes `text` atomically
  (`<path>.bxp-tmp` then `rename`) so a crash mid-write leaves the prior
  config intact.
- **`validateExpr`** `{expr}` → `{ok, error}` — runs `bxp-fmt --expr <text>`
  for live expression lint markers.
- **Webview messages** `traceEvent` / `stderr` feed the zustand store's
  trace model.

The webview side uses `maxRequestTime: Number.POSITIVE_INFINITY` on its
`Electroview.defineRPC` so long dry-runs don't time out.

See [`../docs/bxp-ui-trace-protocol.md`](../docs/bxp-ui-trace-protocol.md) for
the NDJSON wire protocol (schema_version = 1).

## Phase status

- **Phase 2**: scaffold. (done)
- **Phase 3**: debug panel MVP — Files / Rows / RowDetail panes, NDJSON
  streaming, TraceBuilder. (done)
- **Phase 4**: collapsible JSON config tree. (done — MVP read-only tree;
  editable in Phase 6 below)
- **Phase 5**: CodeMirror 6 `bxp-expr` language with live validation. (done)
- **Phase 6**:
  - Inline expression highlighting in ConfigTree + click-to-expand. (done)
  - `var_error` visuals in RowDetail. (done)
  - Editable tree (string / number / boolean / expression leaves) with
    zustand-backed undo/redo. (done)
  - Structural edits on the tree: add child (with key + type picker),
    delete, duplicate, and reorder (↑/↓ for array entries). Each edit is
    a single history step. (done)
  - Comment/whitespace/key-order-preserving JSON5 round-trip via CST patch
    at serialize time (`src/mainview/config/roundtrip.ts`). (done)
  - Save-to-disk button in the Config toolbar. Atomic tmp + rename,
    followed by an auto-reload so bxp-fmt validation refreshes. (done)
  - Trace protocol spec doc. (done)
  - Linux ZSTD bundle shipping bxp-cli + bxp-fmt.
    [`scripts/stage-bins.sh`](scripts/stage-bins.sh) cross-compiles both
    binaries to `x86_64-linux-musl` (`ReleaseSmall`, static) and stages them
    under `build-bin/`. [`electrobun.config.ts`](electrobun.config.ts)
    `build.copy` pulls them into `Resources/app/bin/` so `findSiblingBin`
    resolves them at runtime. `bun run build:canary` produces the full
    `.tar.zst` distributable (~32 MB) in `artifacts/`; extraction to
    `/tmp` + `bxp-fmt --expr` confirmed working. (done)
  - Theme toggle: two dark palettes, `slate` (default blue) and `zinc`
    (neutral gray). [`src/mainview/index.css`](src/mainview/index.css)
    defines the RGB triples as CSS vars; [`tailwind.config.js`](tailwind.config.js)
    remaps the whole `slate-*` palette to `rgb(var(--slate-N) / <alpha-value>)`
    so no component touches `zinc-*` directly. Zustand `theme` state,
    persisted to `localStorage['bxp-ui.theme']`, toggled from TopBar. (done)

## Constraints

- Electrobun is **not** Electron. Do not use Electron APIs.
- Use `views://` URLs for bundled assets; `http://localhost:5173` only during HMR.
- bxp-ui never links `bxp-core` directly — all data passes through `bxp-cli`
  (runtime) or `bxp-fmt` (format/validate) via short-lived child processes.
