# BXP - Architecture

> [← docs/](README.md)

- [Bird's-eye View](#birds-eye-view)
- bxp-cli
  - [Execution Flow](#execution-flow)
  - [Per-File Processing (processBroker)](#per-file-processing-processbroker)
  - [Two-Pass Pipeline Detail](#two-pass-pipeline-detail)
  - [Expression Evaluator - Call Stack](#expression-evaluator---call-stack)
- bxp-fmt
  - [Validation Pipeline](#bxp-fmt-validation-pipeline)
- bxp-gui
  - [Layers and Components](#bxp-gui-layers-and-components)
  - [Dry-run / Runner Flow](#dry-run--runner-flow)
  - [Cancellation and watchdog](#cancellation-and-watchdog)
  - [Config Loading and Parse Pipeline](#config-loading-and-parse-pipeline)
  - [Config Editing and AST](#config-editing-and-ast)
  - [Undo / Redo](#undo--redo)
  - [Expr Playground](#expr-playground)
  - [Auto-updater Flow](#auto-updater-flow)
- [Data Structures](#data-structures)

---

## Bird's-eye View

BXP is a single-binary ETL tool. All broker logic lives in a JSON5 config file -
the binary is a generic engine. The diagram below shows the high-level relationship
between components.

```mermaid
graph TD
    subgraph User["User / CI"]
        CFG["bxp-cli.json
        (JSON5 templates)"]
        DATA["Input files
        (.csv / .xlsx / .json)"]
    end

    subgraph GUI["bxp-gui (Flutter app)"]
        STORE["TraceStore
        (ChangeNotifier)"]
        TB["TraceBuilder
        folds --trace events"]
        SVCS["services/
        BxpProcessClient"]
        AST_LIB["packages/json5_ast/
        Dart JSON5 AST library"]
    end

    subgraph BRIDGE["bxp-gui-bridge — Zig FFI shared library"]
        BRUN["bridge_run<br/>bridge_run_streaming<br/>subprocess proxy"]
        BEVAL["bridge_eval_expr<br/>bridge_eval_expr_trace<br/>in-proc expr"]
    end

    subgraph CLI["bxp-cli (binary)"]
        MAIN["main.zig
        arg parsing · dispatch"]
        PIPE["pipeline.zig
        processBroker()"]
    end

    subgraph FMT["bxp-fmt (binary)"]
        FMTMAIN["main.zig
        --config / --expr / --docs
        --expr-trace / --list-templates"]
    end

    subgraph Core["bxp-core (library)"]
        CSV["csv.zig
        RFC 4180 parser"]
        XLSX["xlsx.zig
        ZIP+XML → CSV"]
        EXPR["expr.zig
        expression evaluator"]
        CFG2["config.zig
        config loader"]
        JSON["json.zig
        JSON array → rows"]
        JSON5["json5.zig
        JSON5 preprocessor"]
        DOCS["docs.zig
        --docs aggregator"]
        DIAG["diagnostics.zig
        validation collector"]
    end

    subgraph Ext["External"]
        SUNRISE["sunrise
        date/time library"]
    end

    CFG -->|read| MAIN
    DATA -->|read| PIPE
    MAIN --> CFG2
    MAIN --> PIPE
    PIPE --> CSV
    PIPE --> XLSX
    PIPE --> EXPR
    PIPE --> JSON
    CFG2 --> JSON5
    EXPR --> SUNRISE
    PIPE -->|write| OUT[".csvx output files"]

    FMTMAIN --> CFG2
    FMTMAIN --> EXPR
    FMTMAIN --> DOCS
    FMTMAIN --> DIAG
    FMTMAIN --> JSON5

    DOCS -.re-exports.-> EXPR
    DOCS -.re-exports.-> CFG2

    SVCS -->|Process.start --trace| CLI
    SVCS -->|Process.run| FMT
    SVCS -->|dart:ffi| BRIDGE
    BRUN -->|spawns| CLI
    BRUN -->|spawns| FMT
    BEVAL -.links.-> EXPR
    STORE --> SVCS
    STORE --> TB
    STORE --> AST_LIB
```

`bxp-gui-bridge` is the FFI shim the GUI loads via `dart:ffi` at startup. Two
roles in one shared library: (1) on **Windows** it wraps every `bxp-cli` /
`bxp-fmt` subprocess to sidestep dart-lang/sdk#1727 (~8 KB stdout cutoff that
kills `--docs` and `--trace`) — this path is mandatory; probe failure at
startup is fatal. (2) on **all platforms** it links `bxp-core/expr` directly
so the editor's live validation and the ExprPlayground avoid the ~50 ms
`bxp-fmt --expr` spawn cost per keystroke. The subprocess proxy paths
(`bridge_run`/`bridge_run_streaming`) also compile on Linux/macOS but stay
dormant behind a `BXP_FORCE_BRIDGE_PROXY=1` smoke gate until v0.3.0.

For the **per-call transport matrix** (which GUI calls use which transport on
each OS, plus the two-cause "why" behind the split), see
[`devel.md`'s "Why the bridge exists" + "Per-call routing"](devel.md#why-the-bridge-exists)
section. The bridge's C-ABI surface and Debug→ReleaseSafe build rationale live
in [`bxp-gui-bridge/CLAUDE.md`](../bxp-gui-bridge/CLAUDE.md).

`docs.zig` is an aggregator — it owns no schema of its own. The dotted arrows
indicate that it re-exports `expr.builtins` (the `FnDoc` catalog) and flattens
each `config.zig` struct's `fields[]` table into the `bxp-fmt --docs` JSON.
Adding a new built-in or config field updates the docs automatically.

`bxp-fmt`'s `--config` path also calls `json5.preprocessAnnotated` directly to
emit `$comm_*` / `$err_*` siblings — that's the source of the FMT → JSON5
arrow that bypasses the normal config loader.

---

## Execution Flow

Step-by-step flow when `bxp-cli` is invoked.

```mermaid
flowchart TD
    START([bxp-cli invoked]) --> ARGS[Parse CLI args
    --config --template --data
    --debug --quiet --fresh]
    ARGS --> LOADCFG[Load bxp-cli.json
    json5.preprocess → std.json]
    LOADCFG --> VALIDATE[Validate all templates
    BrokerConfig.validate]
    VALIDATE --> XLSX_Q{Any templates
    with xlsx_sheet?}
    XLSX_Q -->|yes| XLSX_PASS[xlsxPrePass
    extract sheets → .csv]
    XLSX_Q -->|no| SELECT
    XLSX_PASS --> SELECT{--template
    specified?}
    SELECT -->|yes| ONE[processBroker
    for selected template]
    SELECT -->|no| ALL[processBroker
    for every template]
    ONE --> SUMMARY
    ALL --> SUMMARY[Print overall summary]
    SUMMARY --> EXIT{warnings?}
    EXIT -->|yes| CODE2([exit 2])
    EXIT -->|no| CODE0([exit 0])

    LOADCFG -->|file missing
    or parse error| FATAL([exit 1])
    VALIDATE -->|invalid config| FATAL
    XLSX_PASS -->|fatal error| FATAL
```

---

## Per-File Processing (processBroker)

For each input file matched by `file_pattern_in`:

```mermaid
flowchart TD
    FILE([Input file]) --> FRESH{--fresh
    and output exists?}
    FRESH -->|skip| NEXT([next file])
    FRESH -->|continue| DETECT{File type?}
    DETECT -->|.csv| CSV_READ[ChunkReader +
    csv.LineIterator + csv.splitFields]
    DETECT -->|.json| JSON_READ[json.scanColNames +
    json.RecordReader streaming]
    CSV_READ --> PREPASS
    JSON_READ --> PREPASS

    PREPASS{pre_pass
    defined?}
    PREPASS -->|yes| PP[Pre-pass scan
    build lookup table
    LOOKUP key → values]
    PREPASS -->|no| MAINLOOP
    PP --> MAINLOOP

    MAINLOOP[Main loop - per row]
    MAINLOOP --> SCHEMA[Evaluate input_schema
    expr.evalString per $variable]
    SCHEMA --> RULES[Match row_rules
    first matching 'when' wins]
    RULES -->|rows: empty| SKIP[Skip row silently]
    RULES -->|rows: N entries| EMIT[Emit N output rows
    render output_schema]
    SKIP --> MAINLOOP
    EMIT --> MAINLOOP
    MAINLOOP -->|done| WRITE[Write .csvx
    RFC 4180 output]
    WRITE --> STATS[Update SectionStats
    warnings / empty_csv]
```

A single input row can produce **0, 1, or N output rows** depending on
`row_rules`:

- `rows: []` — silent skip (e.g. internal accounting events that don't
  belong in the activity log).
- `rows: [{...}]` — one-to-one (the typical buy/sell/deposit case).
- `rows: [{...}, {...}, ...]` — multi-row expansion. Used when a single
  source event represents multiple Wealthfolio activities — e.g. a Trading
  212 dividend with adjustment may emit separate `DIVIDEND` and
  `DIV_TAX` rows from one input line.

The `--debug` flag prints rows that match no rule when
`row_rules_debug_missing: true` is set on the template — useful when
authoring a new template. xlsx files take an earlier path: `xlsxPrePass`
extracts each sheet to an intermediate `.csv` before this loop runs, so
xlsx and csv inputs follow the same code from the chunked CSV reader onwards.

---

## Two-Pass Pipeline Detail

The `pre_pass` mechanism enables **cross-row lookups** - values from one row
can be referenced when processing a different row.

```mermaid
sequenceDiagram
    participant F as Input file
    participant PP as pre_pass
    participant LT as LookupTable
    participant ML as Main loop
    participant OUT as Output

    Note over F,OUT: Pass 1 - build lookup table

    loop Every row in file
        F->>PP: raw field values
        PP->>PP: evaluate 'when' condition
        alt row matches
            PP->>PP: evaluate 'key' expression
            PP->>PP: evaluate 'values' expressions
            PP->>LT: store key → {field: value, ...}
        end
    end

    Note over F,OUT: Pass 2 - transform rows

    loop Every row in file
        F->>ML: raw field values
        ML->>ML: evaluate input_schema ($variables)
        Note right of ML: LOOKUP(key_expr, 'field') reads from LookupTable
        ML->>LT: LOOKUP(key, 'field')
        LT-->>ML: stored value
        ML->>ML: match row_rules → $action
        ML->>OUT: render output_schema columns
    end
```

**Example use case (AnyCoin):** A `trade payment` row holds the currency; a `trade fill`
row holds the ticker and quantity. Both share an `Order ID`. `pre_pass` indexes payment
rows by `Order ID`; the main loop uses `LOOKUP([Order ID], 'currency')` when processing
fill rows.

### Single block vs named blocks

`pre_pass` accepts two shapes:

- **Legacy single block** — `{ when, key, values }` directly. Internally bound
  to the synthetic namespace `_default`; accessed via 2-arg
  `LOOKUP(key_expr, 'field')`.
- **Named blocks** — `{ name1: { when, key, values }, name2: { ... } }`. Each
  block is its own namespace; accessed via 3-arg
  `LOOKUP('name1', key_expr, 'field')`. Use this when one template needs
  multiple independent lookup tables.

The lookup table is keyed internally by a composite `name\x00key\x00field`
string, which is why both forms share the same `LookupTable` storage —
the legacy 2-arg form just gets `_default` synthesized as the namespace.

---

## Expression Evaluator - Call Stack

```mermaid
graph TD
    CALL["expr.eval(expr_string, ctx)"]
    CALL --> ES["evalString()
    coerces Value → string"]
    CALL --> EV["eval()
    returns Value"]
    EV --> PARSE["Parser
    recursive descent"]
    PARSE --> OR["parseOr"]
    OR --> AND["parseAnd"]
    AND --> CMP["parseCmp
    = != < > <= >="]
    CMP --> ADD["parseAdd
    + - &"]
    ADD --> MUL["parseMul
    * /"]
    MUL --> UNARY["parseUnary
    unary -"]
    UNARY --> ATOM["parseAtom"]
    ATOM --> LIT["string / number literal"]
    ATOM --> FIELD["[ColumnName] / [n]"]
    ATOM --> FUNC["function call
    IF, ABS, COALESCE,
    DATE_CONVERT, NOW, RAND,
    PRICE_VALUE, PRICE_CURRENCY,
    TICKER, LOOKUP,
    SPLIT_PART, CONTAINS, REPLACE,
    TRIM, ROUND, FLOOR, CEILING,
    FIELDS"]
    FUNC --> SUNRISE_CALL["sunrise
    (DATE_CONVERT only)"]

    FIELD -->|reads| CTX_FIELDS["Context.fields
    Context.col_index"]
    FUNC -.LOOKUP.-> CTX_LT["Context.lookup_table"]
    FUNC -.TICKER.-> CTX_TM["Context.ticker_map"]
```

Side context dependencies (dotted lines): `[ColumnName]` and `[n]` references
read `Context.fields` via `Context.col_index`; `LOOKUP(...)` reads
`Context.lookup_table` populated by the pre-pass; `TICKER(...)` reads
`Context.ticker_map` (resolved at config-load time from inline objects or the
top-level `ticker_maps` registry).

### Static analysis path (parallel to runtime eval)

`bxp-fmt`'s validation passes don't run expressions — they walk the parse
tree to find typos and dead references. Three top-level entry points in
`expr.zig`:

| Function                       | What it returns                                | Used by                                               |
| ------------------------------ | ---------------------------------------------- | ----------------------------------------------------- |
| `staticReferences(src, alloc)` | Set of every `[X]` and `$var` referenced       | `validateUnknownKeysCollect`, `validateUnusedCollect` |
| `staticCheckCalls(src, …)`     | Per-call FnArg arity + signature errors        | `bxp-fmt --config` (added in Phase G6)                |
| `staticCheckSplitPart(src, …)` | Token-scan for `SPLIT_PART(_, _, ≤0)` literals | `bxp-fmt --config`                                    |

These share the parser front-end with `eval()` — same recursive descent, no
duplicated grammar — but emit `Diagnostic` records into a `*Diagnostics` sink
instead of producing values.

---

## bxp-gui: Layers and Components

The GUI is divided into three layers. Each layer has a single direction of
dependency: UI reads from Store, Store calls Services, Services talk to the OS
and to bxp-cli / bxp-fmt subprocesses.

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
        SG["SchemaGate
        insert order · type guard for Add-Child"]
        DV["DartValidator
        per-edit Dart-side checks
        driven by FnDoc.args + FieldDoc"]
        TM["trace_model.dart
        Dart mirrors of BXTB frame payloads"]
    end

    subgraph SVC["lib/services/"]
        BPC["BxpProcessClient
        spawns bxp-cli / bxp-fmt
        parses stdout / stderr streams"]
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
    TS -->|spawn subprocess| BPC
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
  JSON5 output. bxp-fmt annotated JSON output is overlaid as diagnostics, not
  merged into the AST.
- **No fallback FnDocs.** bxp-fmt `--docs` is the single source for the
  language catalog. If the binary is missing at startup, the app shows a fatal
  error gate; there are no hardcoded fallback catalogs.
- **Two transport paths.** `BxpProcessClient` picks per call between
  `dart:io` (`Process.start` / `Process.run`) and FFI through
  `bxp-gui-bridge.{dll,so,dylib}`. The protocol on the wire is identical (same
  CLI args, same stdout payload — BXTB frames for `--trace`, NDJSON for
  `--expr-trace`, JSON for `--config` / `--docs`); only the transport differs.
  - **Out-of-process** (`Process.start`/`Process.run`) is the default on
    Linux/macOS for every subcommand.
  - **In-process expression eval** (`bridge_eval_expr` / `bridge_eval_expr_trace`)
    runs on **all platforms** for the expr editor's live validation and the
    ExprPlayground — avoids ~50 ms `bxp-fmt --expr` spawn cost per keystroke.
  - **Subprocess proxy via bridge** (`bridge_run` / `bridge_run_streaming` +
    `bridge_cancel` + `bridge_ack` for backpressure) is **mandatory on Windows**
    to sidestep a `dart:io` pipe-truncation bug (dart-lang/sdk#1727) that kills
    `--docs` (~30 KB) and `--trace` (megabytes). On Win the DLL is the only
    path; probe failure at startup is fatal. On Linux/macOS these same
    functions compile and work but stay behind a `BXP_FORCE_BRIDGE_PROXY=1`
    pre-release smoke gate. Default-flip is on the v0.3.0 roadmap
    ([`roadmap.md`](roadmap.md#flip-bridge-proxy-to-default-on-linuxmacos)).

---

## Dry-run / Runner Flow

Two toolbar buttons spawn `bxp-cli`: **dry-run** runs `--trace` only (no
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
    TS->>TS: write draft config to tmp file
    TS->>BPC: runWithBtrace (configPath, template?)
    BPC->>CLI: Process.start(--trace --config ...)
    CLI-->>BPC: BXTB magic + file_start frame
    BPC-->>TS: stdout byte chunk
    TS->>TS: BtraceReader.feed(bytes), notifyListeners() [stream started]
    TS->>TS: register FileModel, set runStatus=running
    loop per source row
        CLI-->>BPC: output_row | filtered_row | error_row | prepass_entry
        BPC-->>TS: stdout byte chunk
        TS->>TS: BtraceReader.feed → append RowModel to current FileModel
        TS-->>UI: traceLinesCounter.value++ [ValueNotifier — no rebuild]
    end
    CLI-->>BPC: file_end frame
    TS->>TS: BtraceReader.feed → finalise FileModel stats + publish runtime
    TS-->>UI: fileGen.value++ [ValueNotifier — file selector refresh]
    CLI-->>BPC: done frame (exit_code=0)
    BPC-->>TS: stream closed
    TS->>TS: set runStatus / exitCode
    TS-->>UI: notifyListeners() [final render]
```

### Cancellation and watchdog

The user can cancel a run mid-stream (the run-button label flips to `cancel`
while a stream is active); a hung subprocess is also caught by an internal
idle watchdog. Both paths share the same termination plumbing:

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> running: runDryRun() / runFullRun()
    running --> running: BXTB frame arrives
    running --> cancelling: cancelRun (user) OR 10s idle (watchdog)
    cancelling --> done: child exits
    cancelling --> killed: 2s grace expires, SIGKILL
    killed --> done: process reaped
    running --> done: done frame received
    done --> idle: notifyListeners()
```

Step detail:

- **User cancel.** `cancelRun()` sets `_cancelRequested = true` and sends
  `SIGTERM` to the bxp-cli child. The streaming loop in `_streamRun` detects
  the flag, drains remaining stdout, and exits.
- **Watchdog.** A periodic timer in `_streamRunBtrace` measures time since
  the last BXTB frame. If the gap exceeds 10 seconds, it triggers the same
  SIGTERM path. This catches a child stuck before emitting `done` (rare but
  seen during early `--check-fs=N` development).
- **SIGKILL escalation.** If the process doesn't exit within 2 seconds of
  SIGTERM, the watchdog escalates to SIGKILL. Negative exit codes from
  signal-driven termination are treated as cancellation, not a fault.
- **Final notify.** `notifyListeners()` fires once in the `finally` block so
  the toolbar transitions out of `cancelling` regardless of how the run
  ended (clean done, cancel, kill, error).

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
    participant FMT as bxp-fmt --config

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
        BPC->>FMT: Process.run(--config <path> [--check-fs=N])
        FMT-->>BPC: annotated JSON ($comm/$err/$warn/$info siblings)
        BPC-->>TS: jsonOutput
        TS->>TS: extractDiagnostics(bxpTree)\n→ path-keyed buckets
        TS->>TS: _revalidateDart() [synchronous Dart-side overlay]
        TS-->>UI: notifyListeners() [tree + inline markers]
    end
```

Key points:

- **AST is the primary loader.** Even if `bxp-fmt --config` fails or is slow,
  the user can still see the tree because `ast_loader` only depends on the
  Dart JSON5 library — no subprocess.
- **AST parse failure is the only readonly trigger.** `_loadedWithErrors` is
  flipped only when AST can't build a tree at all; bxp-fmt diagnostics are
  shown as inline `$err_*` markers and the pre-save guard blocks bad saves —
  but the user can keep editing toward the fix.
- **Diagnostics are path-keyed.** `$err_*` siblings in the annotated JSON are
  flattened into `Map<String, List<Diagnostic>>` keyed by dot-path. The tree
  renderer queries this map per-node to draw inline error chips.
- **Dart re-validation runs synchronously after the bxp-fmt response.** It
  populates a separate set of buckets driven by `FnDoc.args` + `FieldDoc`
  validators — instant feedback even for buckets bxp-fmt didn't surface yet.

---

## bxp-fmt validation pipeline

When the GUI calls `bxp-fmt --config <path>`, the binary runs a sequence of
diagnostic passes against the loaded config. Each pass appends to either the
legacy `errors[]` list or the structured `Diagnostics` bag; both are merged
into the annotated JSON output before exit.

```mermaid
flowchart TD
    INPUT([raw config bytes]) --> P1[json5.preprocessAnnotated
    $comm/$err keys for parse-level findings]
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

`bxp-cli` runs only the first three passes (load) and skips the entire
diagnostic chain — its job is to convert files, not validate. Hence the same
typo that surfaces as a `$warn_*` sibling in `bxp-fmt`'s JSON appears as a
plain stderr warning line during a real run.

---

## Config Editing and AST

Every user edit in the config tree (insert field, delete, setValue, reorder) is
expressed as a `ConfigOp` and applied to the live `AstNode` tree via
`json5_ast/operations.dart`. The dumper re-serialises the AST to JSON5 for display and
for saving. `DartValidator` runs synchronously for fast per-field feedback;
`bxp-fmt --config` is called on every Save for the authoritative full-config
validation.

```mermaid
sequenceDiagram
    participant UI as config_view.dart
    participant TS as TraceStore
    participant AST as json5_ast (Dart)
    participant DV as DartValidator
    participant FMT as bxp-fmt --config

    UI->>TS: applyOp(ConfigOp)
    TS->>AST: ops.apply(op, astRoot)
    AST-->>TS: mutated AstNode tree
    TS->>AST: dumper.dump(astRoot)
    AST-->>TS: JSON5 source string (draft)
    TS->>DV: validatePath(path, value)
    DV-->>TS: per-field errors (fast, no subprocess)
    TS-->>UI: notifyListeners() [tree re-renders with inline markers]

    Note over TS,FMT: On Save (Ctrl+S)
    TS->>TS: write draft JSON5 to disk
    TS->>FMT: loadConfig(path, checkFsSeconds?)
    FMT-->>TS: annotated JSON (with $err/$warn/$info/$comm siblings)
    TS->>TS: parse into diagnosticMap (path -> Diagnostic[])
    TS-->>UI: notifyListeners() [diagnostics overlay updated]
```

`DartValidator` is a thin Dart interpreter driven by the same `FnDoc.args` and
`FieldDoc` tables exported by `bxp-fmt --docs`. It does not reimplement
validation logic — it reads the single-source-of-truth catalog so that adding a
new built-in function automatically extends the live validator.

### Undo / redo

The op log is the canonical record of "what the user did since the last
load." Every applied `ConfigOp` is paired with its inverse so undo doesn't
require re-parsing — it just reapplies the inverse against the live AST.

```mermaid
sequenceDiagram
    participant UI as editor / Ctrl+Z / Ctrl+Y
    participant TS as TraceStore
    participant LOG as _opLog
    participant REDO as _redoStack
    participant AST as json5_ast

    Note over UI,AST: Forward edit
    UI->>TS: applyOp(op)
    TS->>AST: ops.apply(op, root)
    TS->>LOG: push (op, inverseOp)
    TS->>REDO: clear()
    TS-->>UI: notifyListeners() [canUndo=true, canRedo=false]

    Note over UI,AST: Undo (Ctrl+Z)
    UI->>TS: undo()
    TS->>LOG: pop (op, inverseOp)
    TS->>AST: ops.apply(inverseOp, root)
    TS->>REDO: push (op, inverseOp)
    TS->>TS: re-run DartValidator + diagnostic refresh
    TS-->>UI: notifyListeners() [canRedo=true]

    Note over UI,AST: Redo (Ctrl+Y)
    UI->>TS: redo()
    TS->>REDO: pop (op, inverseOp)
    TS->>AST: ops.apply(op, root)
    TS->>LOG: push (op, inverseOp)
    TS->>TS: re-run DartValidator + diagnostic refresh
    TS-->>UI: notifyListeners()
```

Edge cases handled:

- **Ctrl+Z inside a text field** falls through to native typo-undo. The
  global handler only fires when focus is somewhere structural (tree, panel,
  top bar). See `_focusInEditableText()` in `main_view.dart`.
- **Save clears the redo stack but keeps the undo log.** The user can still
  undo edits made before the save — the AST mutations are reversible
  regardless of disk persistence.
- **Reset draft (Ctrl+T)** clears both stacks and re-loads from disk —
  it's a hard reset, not an undo.

---

## Expr Playground

Expressions are validated live (per keystroke, debounced ~300 ms) via
`bxp-fmt --expr`. When the user switches to the **Variables** panel, the
playground calls `bxp-fmt --expr-trace` with the current row context and streams
per-call results into the Variables table. Token-level error spans (byte
`off`/`len` from Phase G1) are used to underline the offending token directly
in the expr editor.

```mermaid
sequenceDiagram
    participant UI as expr_editor.dart
    participant TS as TraceStore
    participant BPC as BxpProcessClient
    participant FMT as bxp-fmt

    Note over UI,FMT: Live validation (per edit, debounced)
    UI->>TS: setExprDraft(path, src)
    TS->>BPC: validateExpr(src) [--expr]
    BPC->>FMT: Process.run(--expr 'src')
    FMT-->>BPC: stderr {error, detail, off, len} or exit 0
    BPC-->>TS: ExprValidation result
    TS-->>UI: exprValidationOffset/Length → underline token in editor

    Note over UI,FMT: Playground run (Variables panel)
    UI->>TS: traceExpr(src, headers, fields)
    TS->>BPC: traceExpr() [--expr-trace + --row-headers + --row-fields]
    BPC->>FMT: Process.start(--expr-trace ...)
    loop per-call NDJSON line (stdout)
        FMT-->>BPC: {"fn":"ABS","src_start":0,"src_end":14,"value":"150"}
        BPC-->>TS: ExprCallTrace record
        TS-->>UI: exprCallTrace list [ValueNotifier]
    end
    FMT-->>BPC: {"t":"final","value":"150"} stdout or {"t":"error",...} stderr
    BPC-->>TS: final value or error
    TS-->>UI: exprFinalValue / exprTraceError
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
        UPD->>UPD: pick asset by platform regex\n(setup.exe / .dmg / .AppImage)
        UPD-->>DLG: notifyListeners() [UpdateInfo available]
        DLG->>UPD: user clicks Install
        UPD->>FS: download asset → tmp dir
        UPD->>GH: GET SHA256SUMS
        UPD->>UPD: verify SHA256 of asset
        alt hash matches
            UPD->>OS: platform-specific install
            Note right of OS: Windows: setup.exe /S → exit(0)\nmacOS: hdiutil mount → cp -R → open -n\nLinux AppImage: atomic-replace + exec()\nLinux .deb / tarball: open release page
            OS-->>UPD: success / failure
        else hash mismatch
            UPD-->>DLG: error: corrupted download
        end
    else current is latest
        UPD->>UPD: schedule next tick (6 h)
    end
```

Notes:

- **Initial poll fires 5 s after launch.** Avoids slowing app startup; a 6 h
  recurring tick handles long-running sessions.
- **macOS DMGs target ARM only.** Intel Macs get `assetUrl == null` and the
  dialog redirects to the GitHub release page — no auto-install path. The
  release workflow doesn't produce an x86_64 DMG.
- **Linux dual path.** AppImage is atomically replaced and `exec()`'d back
  in-place; `.deb` and `.tar.gz` users go to the release page since
  in-place self-update doesn't fit those formats.
- **`kDebugMode` skips the auto-check.** Dev runs don't accidentally
  download installers over the working tree.

---

## Data Structures

```mermaid
classDiagram
    class Config {
        +brokers: StringArrayHashMap~BrokerConfig~
        +ticker_maps: StringHashMap~TickerMap~
        +deinit()
    }

    class BrokerConfig {
        +data_dir: string
        +file_pattern_in: string
        +file_pattern_out: ?string
        +date_filter_from_filename: bool
        +combined_output: bool
        +ticker_map: TickerMap
        +xlsx_sheet: ?XlsxSheet
        +pre_passes: StringArrayHashMap~PrePass~
        +input_schema: StringArrayHashMap~string~
        +row_rules: []RowRule
        +output_schema: StringArrayHashMap~string~
        +validate(id, writer)
    }

    class PrePass {
        +when: string
        +key: string
        +values: StringArrayHashMap~string~
    }

    class Diagnostics {
        +items: ArrayList~Diagnostic~
        +append(diag)
        +count() usize
        +countBySeverity(sev) usize
    }

    class Diagnostic {
        +path: string
        +severity: Severity
        +code: string
        +message: string
        +suggest: ?string
    }

    class RowRule {
        +when: string
        +rows: []StringHashMap~string~
    }

    class XlsxSheet {
        +name: string
        +header_row: u32
        +output_suffix: string
    }

    class Value {
        +number: f64
        +string: []const u8
        +boolean: bool
    }

    class Context {
        +fields: [][]const u8
        +col_index: StringHashMap~usize~
        +ticker_map: StringHashMap~string~
        +lookup_table: ?*LookupTable
        +alloc: Allocator
        +decimal_sep_in: u8
        +quote_out: u8
    }

    class TickerMap {
        +entries: StringHashMap~string~
    }

    class LookupTable {
        +map: StringHashMap~string~
    }

    class SectionStats {
        +warnings: u32
        +errors: u32
        +empty_csv: u32
        +elapsed_ns: u64
        +merge(other)
    }

    class SheetSpec {
        +name: string
        +header_row: u32
        +output_suffix: string
    }

    Config "1" *-- "many" BrokerConfig
    Config "1" *-- "many" TickerMap
    BrokerConfig "1" *-- "0..*" PrePass
    BrokerConfig "1" *-- "many" RowRule
    BrokerConfig "1" *-- "0..1" XlsxSheet
    BrokerConfig --> TickerMap : ticker_map ref
    Context --> Value : eval returns
    Context --> LookupTable : Context.lookup_table
    Context --> TickerMap : Context.ticker_map
    XlsxSheet ..> SheetSpec : runtime form\nfor xlsx.zig
    Diagnostics "1" *-- "many" Diagnostic
```

`SectionStats` is bxp-cli's per-section accumulator (one per template, plus
a top-level total). Warnings tick the exit code from 0 → 2 even when the run
completes; errors push it to 1.

`LookupTable` is owned by `Context` for the duration of one file's main
loop. The composite key encoding keeps multi-namespace `pre_passes` sharing
one storage map without needing nested structures.

`TickerMap` can be inline (per-template `ticker_map: { ... }`) or a named
reference into the top-level `ticker_maps: { name: { ... } }` registry —
config loader resolves the reference at load time, so by the time `Context`
gets it, it's always a flat `StringHashMap`.
