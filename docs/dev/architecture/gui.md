---
description: "The desktop app's layers: config editing, the dry-run debugger, the trace store and the updater."
---

# GUI Architecture

## bxp-gui: Layers and Components

The GUI is divided into three layers. Each layer has a single direction of
dependency: UI reads from Store, Store calls Services, Services talk to the OS
and to the bxp-cli subprocess (proxied by the bridge).

```mermaid
graph TD
    subgraph UI["lib/ui/"]
        EDP["config_view.dart + expr_panel.dart + expr_editor.dart
        config tree · expr editor · docs panel"]
        TRP["debug_panes.dart + row_detail.dart + output_panel.dart
        variables · rules · output · dry-run viewer"]
        TLB["top_bar.dart + config_view.dart toolbar
        Run · Validate · Save · Cancel"]
        STG["settings_inspector.dart
        Ctrl+Shift+S drawer"]
    end

    subgraph STORE["lib/store/"]
        TS["TraceStore (ChangeNotifier)
        config AST · diagnostics · trace frames
        docs catalog · prefs · run status"]
        TM["trace_model.dart
        Dart mirrors of BXTB frame payloads"]
    end

    subgraph SVC["lib/services/"]
        SG["SchemaGate
        insert order · type guard for Add-Child"]
        DV["DartValidator
        per-edit Dart-side checks
        driven by FnDoc.args + FieldDoc"]
        BPC["BxpProcessClient
        every backend call via bxp-gui-bridge
        in-proc inspect/eval + proxied bxp-cli runs"]
        ASTL["ast_loader.dart
        parse user config → JsonAstNode tree"]
        ASTP["ast_patch_client.dart
        apply mutations + dump back to disk"]
        OPL["op_log.dart
        undo / redo ledger of ConfigOps"]
        OP2A["op_to_ast.dart
        translate ConfigOp → AST mutation calls"]
        SDL["schema_doc_lookup.dart
        path matching with * wildcard"]
        DT["dev_trace.dart
        kDebugMode print() helper"]
        PS["PrefsService
        JSON prefs file at OS-canonical path"]
        UPD["UpdaterService
        polls api.github.com/releases/latest"]
    end

    subgraph AST["packages/json5_ast/"]
        JP["parser.dart
        JSON5 source → AstNode tree"]
        JD["dumper.dart
        AstNode tree → JSON5 source"]
        JO["operations.dart
        insert · delete · setValue · move · dup"]
    end

    UI -->|read state| TS
    UI -->|dispatch actions| TS
    TS --> SG
    TS --> DV
    TS --> AST
    TS -->|backend calls| BPC
    TS --> ASTL
    TS --> ASTP
    TS --> OPL
    TS --> OP2A
    TS --> PS
    TS --> UPD
    SG -.uses.-> SDL
    DV -.uses.-> SDL
    ASTP --> AST
    OP2A --> AST
```

Key invariants:

- **TraceStore is the single source of truth.** All UI state — config AST,
  diagnostics, trace events, docs catalog, user prefs — lives in TraceStore.
  Services are stateless; they do not cache results.
- **json5_ast is the live config representation.** The config is held in memory
  as an `AstNode` tree so edits preserve JSON5 comments and produce canonical
  JSON5 output. The validator's annotated JSON output is overlaid as diagnostics, not
  merged into the AST.
- **No fallback FnDocs.** The docs catalog is the single source for the
  language catalog. If the binary is missing at startup, the app shows a fatal
  error gate; there are no hardcoded fallback catalogs.
- **One backend, two call shapes.** `BxpProcessClient` routes **every** backend
  call through
  `bxp-gui-bridge.{dll,so,dylib}` on all platforms — there is no `Process.start`
  path. The bridge offers two call shapes:
  - **In-process inspect / eval** (`bridge_eval_expr` / `bridge_eval_expr_trace`
    for the expr editor's live validation + ExprPlayground; `bridge_inspect` for
    docs / config / template / eval-batch ops) links `bxp-core/inspect` directly
    and runs synchronously on the main isolate — no spawn, avoiding the ~50 ms
    per-keystroke subprocess cost.
  - **Subprocess proxy** (`bridge_run` / `bridge_run_streaming` +
    `bridge_cancel` + `bridge_ack` for backpressure) wraps the `bxp-cli` runs
    (dry-run / full-run `--trace=bin`, `--version`), draining pipes in native
    Zig code to sidestep a `dart:io` pipe-truncation bug (dart-lang/sdk#1727)
    that kills `--trace` (megabytes) on Windows. Library probe failure at
    startup is **fatal** on every platform — there is no subprocess fallback.

---

## Dry-run / Runner Flow

Two toolbar buttons run `bxp-cli` through the bridge: **dry-run** runs `--trace` only (no
`.csvx` files written, just the BXTB frame stream for the debugger);
**full-run** writes real output. Neither has a keyboard shortcut — both
share the same plumbing, only the `dry: bool` argument to `_streamRunBtrace`
differs. Frames stream back as binary BXTB; the in-store reader folds each
frame into `TraceStore`. To avoid a rebuild storm (PlutoGrid reallocates
quadratically on every `notifyListeners`), incremental row updates go through
`ValueNotifier<int>` counters; the full `notifyListeners()` fires only twice:
at stream start and after the `done` frame.

```mermaid
sequenceDiagram
    participant UI as debug_panes.dart
    participant TS as TraceStore
    participant BPC as BxpProcessClient
    participant CLI as bxp-cli --trace

    UI->>TS: runDryRun() / runFullRun()
    TS->>TS: reset run state + pick tmp .bxtb path (runs the on-disk config)
    TS->>BPC: runWithBtrace (configPath, template?)
    BPC->>CLI: bridge_run_streaming(--config ... --trace=bin --trace-file=tmp.bxtb)
    CLI-->>BPC: BXTB magic + file_start frame
    BPC-->>TS: stdout byte chunk
    TS->>TS: BtraceReader.appendBytes + nextFrame, notifyListeners() [stream started]
    TS->>TS: register FileModel, set runStatus=running
    loop per source row
        CLI-->>BPC: output_row | filtered_row | error_row | prepass_entry
        BPC-->>TS: stdout byte chunk
        TS->>TS: nextFrame → append RowModel to current FileModel
        TS-->>UI: traceLinesCounter.value++ [ValueNotifier — no rebuild]
    end
    CLI-->>BPC: file_end frame
    TS->>TS: nextFrame → finalise FileModel stats + publish runtime
    TS-->>UI: fileGen.value++ [ValueNotifier — file selector refresh]
    CLI-->>BPC: done frame (exit_code=0)
    BPC-->>TS: stream closed
    TS->>TS: set runStatus / exitCode
    TS-->>UI: notifyListeners() [final render]
```

### Cancellation

The user can cancel a run mid-stream (the run-button label flips to `cancel`
while a stream is active). Cancellation is **user-driven only** — there is no
idle watchdog and no SIGKILL escalation; a child that never exits keeps the
run in `cancelling` until it does.

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> running: runDryRun() / runFullRun()
    running --> running: BXTB frame arrives
    running --> cancelling: cancelRun() (user)
    cancelling --> done: child exits, stream resolves
    running --> done: done frame received
    done --> idle: notifyListeners()
```

Step detail:

- **User cancel.** `cancelRun()` sets `_cancelRequested = true` and calls
  `BxpProcessClient.cancelBtrace(handle)` → `bridge_cancel`, which signals the
  `bxp-cli` child (SIGTERM on POSIX, `TerminateProcess` on Windows) and wakes
  any reader parked on the backpressure semaphore. The bridge's reader threads
  drain what is already buffered, the wait thread reaps the exit, and
  `_streamRunBtrace` collapses to its post-loop cleanup with whatever landed —
  partial output stays visible.
- **Cancel before the handle exists.** A click between `status = running` and
  the bridge handle arriving finds `_runBridgeHandle == null`; the flag is set
  anyway so the `onBridgeSpawn` callback cancels the moment the handle shows
  up, instead of silently no-opping.
- **Signal exit codes.** Negative exit codes from signal-driven termination are
  treated as cancellation, not a fault.
- **Final notify.** `notifyListeners()` fires once in the `finally` block so
  the toolbar transitions out of `cancelling` regardless of how the run
  ended (clean done, cancel, error).

!!! note "Grandchildren are not reached"

    `bridge_cancel` signals the direct child only. Not live today — `bxp-cli`
    forks nothing (its parallelism is threads) — but see the roadmap entry
    before that changes.

---

## Config loading and parse pipeline

Symmetric counterpart to **Config Editing and AST** below. Triggered by
opening a file (`Ctrl+O`), pressing `Ctrl+R` (reload), or being called as
post-save reload from `saveConfig`. Two parallel parses run on the same
bytes:

```mermaid
sequenceDiagram
    participant UI as open_dialog.dart / Ctrl+O / Ctrl+R
    participant TS as TraceStore
    participant ASTL as ast_loader (Dart JSON5 AST)
    participant BPC as BxpProcessClient
    participant FMT as bridge (config)

    UI->>TS: setConfigPath(path) + loadConfig()
    TS->>TS: clear stale state\n(diagnostics, run-state, expr cache)
    TS->>TS: notifyListeners() [isLoadingConfig=true]
    TS->>ASTL: AstLoader.loadFromFile(path)
    ASTL-->>TS: { rawText, root, diagnostics }
    alt astResult.root == null (parse fail)
        TS->>TS: configError + _loadedWithErrors=true
        TS-->>UI: notifyListeners() [readonly toolbar]
    else AST parsed OK
        TS->>TS: _astRoot = root
        TS->>BPC: loadConfig(path, checkFsSeconds?)
        BPC->>FMT: bridge_inspect {op:config, check_fs:N}
        FMT-->>BPC: annotated JSON ($err/$warn/$info siblings)
        BPC-->>TS: jsonOutput
        TS->>TS: extractDiagnostics(bxpTree)\n→ path-keyed buckets
        TS->>TS: _revalidateDart() [synchronous Dart-side overlay]
        TS-->>UI: notifyListeners() [tree + inline markers]
    end
```

Key points:

- **AST is the primary loader.** Even if config validation fails or is slow,
  the user can still see the tree because `ast_loader` only depends on the
  Dart JSON5 library — no subprocess.
- **AST parse failure is the only readonly trigger.** `_loadedWithErrors` is
  flipped only when AST can't build a tree at all; validator diagnostics are
  shown as inline `$err_*` markers and the pre-save guard blocks bad saves —
  but the user can keep editing toward the fix.
- **Diagnostics are path-keyed.** `$err_*` siblings in the annotated JSON are
  flattened into `Map<String, List<Diagnostic>>` keyed by dot-path. The tree
  renderer queries this map per-node to draw inline error chips.
- **Dart re-validation runs synchronously after the validator response.** It
  populates a separate set of buckets driven by `FnDoc.args` + `FieldDoc`
  validators — instant feedback even for buckets the validator didn't surface yet.

---

## Config validation pipeline

When the GUI validates a config (`bridge_inspect {config}` → `inspect.annotateRaw`), it runs a sequence of
diagnostic passes against the loaded config. Each pass appends to either the
legacy `errors[]` list or the structured `Diagnostics` bag; both are merged
into the annotated JSON output before exit.

```mermaid
flowchart TD
    INPUT([raw config bytes]) --> P1[json5.preprocessAnnotated
    $err keys for parse-level findings
    comments stripped, never carried]
    P1 --> P2[std.json.parseFromSliceLeaky
    structural JSON parse]
    P2 --> P3[config.loadFromBytes
    → Config + BrokerConfig structs]

    P3 --> V1[BrokerConfig.validateCollect
    schema constraints per template]
    V1 --> V2[validateExprsCollect
    expression statics: refs, calls, SPLIT_PART]
    V2 --> V3[validateUnusedCollect
    dead pre_passes, unused $variables]
    V3 --> V4[validateCrossTemplate
    file_pattern_in collisions across templates]
    V4 --> V5[validateUnknownKeysCollect
    typo'd keys + did-you-mean]
    V5 --> V6{--check-fs=N
    flag set?}
    V6 -->|N>0| V7[validateFilesystemWithTimeout
    data_dir + input file existence
    worker thread + N-second deadline]
    V6 -->|N=0| MERGE
    V7 --> MERGE["Merge errors[] + Diagnostics<br/>into annotated JSON tree"]
    MERGE --> EXIT{any error?}
    EXIT -->|yes| OUT1([annotated JSON
    exit 1])
    EXIT -->|no| OUT0([annotated JSON
    exit 0])
```

Severity routing in the merged JSON: `.error` → `$err_<N>`, `.warning` →
`$warn_<N>`, `.info` → `$info_<N>`. All three carry an optional `off` / `len`
byte span and `suggest` did-you-mean string. Each finding is inserted as a
sibling immediately before the offending key in its parent object (or
appended to the parent when the offending field doesn't exist).

`bxp-cli` runs the load passes plus the fail-fast `BrokerConfig.validate`
(the same schema constraints as V1, stopping at the first) and skips the rest
of the diagnostic chain — its job is to convert files, not validate. Hence the same
typo that surfaces as a `$warn_*` sibling in the annotated JSON appears as a
plain stderr warning line during a real run.

---

## bxp-mcp: MCP adapter over the shared core

`bxp-mcp` is a second adapter over the same stateless `inspect` core the GUI
bridge links — but speaking MCP (JSON-RPC 2.0 over stdio) to an AI agent
instead of FFI to a Dart process. An agent host spawns it as a child and pipes
one JSON object per line; every stateless tool is a direct in-process `inspect`
call (microseconds, no subprocess). The lone exception is `bxp_simulate`, which
needs the full conversion pipeline and therefore spawns the **co-located
`bxp-cli`** — the same "heavy workhorse runs as a child, the adapter translates"
pattern the GUI uses.

```mermaid
flowchart TD
    AGENT([AI agent / MCP host]) -->|JSON-RPC line| LOOP["mcp.Server.serveStdio
    stdin loop + per-message arena"]
    LOOP --> DISP[dispatch by name
    → tools.zig handler]

    DISP -->|stateless| CORE[("inspect.zig<br/>validate / eval / eval-batch /<br/>eval-trace / docs / templates")]
    DISP -->|bxp_simulate| SIM[sim.zig
    stage config+CSV in scratch ws]
    SIM -->|spawn| CLI[[bxp-cli
    --config/--template/--data
    + --trace-file BXTB sidecar]]
    CLI --> READ[read outputs + parse BXTB
    fold per-row trace into report]

    CORE --> RES["mcp tool result<br/>text + structuredContent? + isError"]
    READ --> RES
    RES -->|JSON-RPC line| AGENT
    SIM -. notifications/progress .-> AGENT
```

Key boundaries a developer should keep straight:

- **`isError` vs domain `ok:false`.** `isError:true` is reserved for a transport
  failure (missing required argument, unexpected error, spawn/IO). An expression
  error, a not-found template id, or a `bxp_simulate` orchestration report comes
  back as a normal result with `isError:false` — it is a valid answer to read.
- **`structuredContent` is gated by tool identity**, not by sniffing the output
  shape: a single-object tool exposes the parsed object; `bxp_eval_trace` is
  NDJSON and stays text-only even when a trivial expression yields one line.
- **Memory is two-tier**: a base arena in `main.zig` for startup (argv + the
  registered tool table), and a **per-message arena the `mcp` module creates and
  destroys** around each response — destroyed, not reset with
  `retain_capacity`, so no pointer can survive into the next request's parse.
  A handler reaches it as `call.arena`: allocate freely, never store past the
  call.

Full detail — tool catalog, wire protocol, the `bxp_simulate` workspace + BXTB
fold, build/test — lives in [`mcp.md`](../mcp.md) and
[`bxp-mcp/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-mcp/CLAUDE.md).

### Two agent-control surfaces

The bird's-eye view shows **two** ways an agent reaches BXP, and they are not the
same server:

- **`bxp-mcp`** (the `MCPSRV` node) — a standalone Zig binary, **stateless** tools
  over **stdio**, wrapping the `inspect` core. An agent uses it to author and
  verify a config with no GUI running.
- **gui-mcp** (`GuiMcpServer`, the `GUIMCP` node) — an MCP server embedded
  **inside the running Flutter app**, **stateful** tools over **localhost HTTP**,
  wrapping the live `TraceStore`. An agent uses it to drive the live GUI (open /
  edit / dry-run / read trace); every tool is the same action the UI dispatches,
  so parity is definitional.

Different binary, transport, and state model; they share only the MCP protocol.
See [`mcp.md`](../mcp.md) (bxp-mcp) and [`gui/agent.md`](../gui/agent.md#agent-control-gui-mcp)
(gui-mcp).

---

## Config Editing and AST

Every user edit in the config tree (insert field, delete, setValue, reorder) is
expressed as a `ConfigOp`, applied to the live `AstNode` tree in place via
`json5_ast/operations.dart` (`applyConfigOp`), and recorded in the op log. On
Save, `AstPatchClient` replays that op log against the original raw bytes and
dumps the result through the deterministic emitter. `DartValidator` runs
synchronously for fast per-field feedback; the bridge's config validation runs
on every Save (against the temp file, before the real file is touched) for the
authoritative full-config validation.

```mermaid
sequenceDiagram
    participant UI as config_view.dart
    participant TS as TraceStore
    participant AST as json5_ast (Dart)
    participant DV as DartValidator
    participant FMT as bridge (config)

    UI->>TS: edit action (ConfigOp)
    TS->>AST: applyConfigOp(astRoot, op)
    AST-->>TS: AstNode tree mutated in place
    TS->>TS: _opLog.record(op) + _pushHistory() [AST snapshot]
    TS->>DV: _revalidateDart()
    DV-->>TS: path-keyed errors (fast, no subprocess)
    TS-->>UI: notifyListeners() [tree re-renders with inline markers]

    Note over TS,FMT: On Save (Ctrl+S)
    TS->>AST: AstPatchClient.apply(rawBytes, ops)
    AST-->>TS: JSON5 bytes
    TS->>TS: write path.bxp-tmp
    TS->>FMT: loadConfig(tmpPath, checkFsSeconds?)
    FMT-->>TS: annotated JSON (with $err/$warn/$info siblings)
    alt any $err_* marker
        TS->>TS: delete tmp, keep original, show configSaveError
    else clean
        TS->>TS: back up original, rename tmp over it,<br/>reset history to one baseline, clear op log
        TS->>FMT: loadConfig() [refresh diagnostics]
    end
    TS-->>UI: notifyListeners() [diagnostics overlay updated]
```

`DartValidator` is a thin Dart interpreter driven by the same `FnDoc.args` and
`FieldDoc` tables exported by the docs catalog. It does not reimplement
validation logic — it reads the single-source-of-truth catalog so that adding a
new built-in function automatically extends the live validator.

### Undo / redo

History is a list of **AST snapshots** (`_astHistory` + `_historyIndex`), not a
stack of inverse ops: every applied mutation pushes a clone of the live tree,
and undo / redo just move the index and restore that clone. Index 0 is always
the last loaded/saved baseline, so `isDirty` is simply `_historyIndex > 0`. The
op log is kept in step (`_opLog.truncate(_historyIndex)` before each new op),
because it — not the snapshots — is what Save replays onto the raw bytes.

```mermaid
sequenceDiagram
    participant UI as editor / Ctrl+Z / Ctrl+Y
    participant TS as TraceStore
    participant H as _astHistory

    Note over UI,H: Forward edit
    UI->>TS: edit action (ConfigOp)
    TS->>TS: applyConfigOp + _opLog.truncate/record
    TS->>H: drop entries after _historyIndex, push clone
    TS-->>UI: notifyListeners() [canUndo=true, canRedo=false]

    Note over UI,H: Undo (Ctrl+Z)
    UI->>TS: undo()
    TS->>H: _historyIndex-- , restore clone
    TS->>TS: invalidate path-keyed state (re-runs DartValidator)
    TS-->>UI: notifyListeners() [canRedo=true]

    Note over UI,H: Redo (Ctrl+Y)
    UI->>TS: redo()
    TS->>H: _historyIndex++ , restore clone
    TS->>TS: invalidate path-keyed state (re-runs DartValidator)
    TS-->>UI: notifyListeners()
```

Edge cases handled:

- **Ctrl+Z inside a text field** falls through to native typo-undo. The
  global handler only fires when focus is somewhere structural (tree, panel,
  top bar). See `_focusInEditableText()` in `main_view.dart`.
- **Save and load reset the history.** A successful save compresses the
  history to a single baseline entry and clears the op log, so edits made
  before the save can no longer be undone.
- **Reset draft (Ctrl+T)** restores the last loaded/saved baseline from memory
  (`resetDraft`, no bridge round-trip) and resets the history — it's a hard
  reset, not an undo.

---

## Expr Playground

Expressions are validated live (per edit, debounced 500 ms): the Dart-side
`DartValidator` checks first, then the bridge expr validator. Token-level error
spans (byte `off`/`len`) are used to underline the offending token directly in
the expr editor. When an expression containing function calls is rendered
against a selected row, the store lazily asks the bridge's expr-trace for that
(row, expression) pair and caches the per-call values, which the function-token
tooltips then show.

```mermaid
sequenceDiagram
    participant UI as expr_editor.dart / expr_highlight.dart
    participant TS as TraceStore
    participant BPC as BxpProcessClient
    participant FMT as bridge (inspect)

    Note over UI,FMT: Live validation (per edit, debounced)
    UI->>TS: updateSelectedExprText(src)
    TS->>TS: DartValidator.validateExpr (sync)
    TS->>BPC: validateExpr(src)
    BPC->>FMT: bridge_eval_expr(src)
    FMT-->>BPC: 0 (valid) or {error, detail, off, len}
    BPC-->>TS: validation result
    TS-->>UI: exprValidationOffset/Length → underline token in editor

    Note over UI,FMT: Per-call trace (selected row, lazily)
    UI->>TS: requestExprCallTrace(rowId, src)
    TS->>BPC: traceExpr(expr, headers, fields)
    BPC->>FMT: bridge_eval_expr_trace(src, headers, fields)
    FMT-->>BPC: NDJSON: one {"fn","src_start","src_end","value"} line per call<br/>+ {"t":"final",...} or {"t":"error",...}
    BPC-->>TS: List of ExprCallTrace
    TS->>TS: cache by (row, expr)
    TS-->>UI: notifyListeners() → tooltips show per-call values
```

---

## Auto-updater flow

`UpdaterService` runs in the background from app launch onwards. It polls
GitHub Releases, surfaces newer versions through a `ChangeNotifier`, and on
user accept downloads → verifies → installs the matching native artifact.

```mermaid
sequenceDiagram
    participant Timer as 5 s + 6 h tick
    participant UPD as UpdaterService
    participant GH as api.github.com
    participant DLG as update_dialog
    participant FS as system temp dir
    participant OS as platform installer

    Timer->>UPD: check()
    UPD->>GH: GET /repos/zaxified/bxp/releases/latest
    GH-->>UPD: { tag_name, assets[] }
    UPD->>UPD: compare against current version
    alt newer release found
        UPD->>UPD: pick asset by platform regex\n(.exe / .dmg / .AppImage)
        UPD-->>DLG: notifyListeners() [UpdateInfo available]
        DLG->>UPD: user clicks Install
        UPD->>FS: download asset → tmp dir
        UPD->>GH: GET SHA256SUMS + SHA256SUMS.minisig
        UPD->>UPD: verify minisign signature over SHA256SUMS\n(bridge_verify_minisign, fail-closed)
        alt signature authentic
            UPD->>UPD: verify asset SHA-256 against the now-trusted SHA256SUMS
            alt hash matches
                UPD->>OS: platform-specific install
                Note right of OS: Windows: setup.exe /S → exit(0)\nmacOS: hdiutil mount → cp -R → open -n\nLinux AppImage: atomic-replace + exec()
                OS-->>UPD: success / failure
            else hash mismatch
                UPD-->>DLG: error: checksum mismatch — refuse install
            end
        else signature missing / invalid / verifier unavailable
            UPD-->>DLG: error: bad release signature — refuse install
        end
    else current is latest
        UPD->>UPD: schedule next tick (6 h)
    end
```

Notes:

- **Two-step fail-closed verification before any install.** First **authenticity**
  — the `SHA256SUMS.minisig` minisign signature over `SHA256SUMS` is checked
  against the public key embedded in `UpdaterService.minisignPublicKey` (native
  Ed25519 + Blake2b-512 via `bridge_verify_minisign`, no Dart crypto dep); then
  **integrity** — the asset's SHA-256 is matched against the now-trusted
  `SHA256SUMS`. Both compares see the same fetched bytes (no verify→use swap
  window). A missing/invalid signature, a missing/mismatched checksum, or an
  unavailable verifier all refuse the install. Signing is automated in CI
  (`release.yml`).
- **Initial poll fires 5 s after launch.** Avoids slowing app startup; a 6 h
  recurring tick handles long-running sessions.
- **macOS DMGs target ARM only.** The macOS branch gates on the host
  architecture — parsed from `Platform.version`'s ABI tag, since `dart:io`
  exposes none — so anything that is not `arm64` gets `assetUrl == null` and
  the dialog redirects to the GitHub release page. Matching the asset *name*
  alone was not enough: it matches on any macOS host, so an Intel Mac used to
  install a build it could not launch. The release workflow doesn't produce an
  x86_64 DMG.
- **Linux is AppImage-only.** AppImage is atomically replaced and `exec()`'d
  back in-place; a build running outside an AppImage gets no asset match and a
  "manual update required" message (the `.deb` / tarball channels were retired
  in v0.3.0).
- **`kDebugMode` skips the auto-check.** Dev runs don't accidentally
  download installers over the working tree.

---
