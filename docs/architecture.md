# BXP - Architecture

> [← docs/](README.md)

- [Bird's-eye View](#birds-eye-view)
- bxp-cli
  - [Execution Flow](#execution-flow)
  - [Per-File Processing (processBroker)](#per-file-processing-processbroker)
  - [Two-Pass Pipeline Detail](#two-pass-pipeline-detail)
  - [Expression Evaluator - Call Stack](#expression-evaluator---call-stack)
- bxp-gui
  - [Layers and Components](#bxp-gui-layers-and-components)
  - [Dry-run / Runner Flow](#dry-run--runner-flow)
  - [Config Editing and AST](#config-editing-and-ast)
  - [Expr Playground](#expr-playground)
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

    SVCS -->|subprocess --trace| CLI
    SVCS -->|subprocess --config / --docs / --expr / --expr-trace| FMT
    STORE --> SVCS
    STORE --> TB
    STORE --> AST_LIB
```

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
    DETECT -->|.csv| CSV_READ[csv.splitRecords
    csv.splitFields]
    DETECT -->|.json| JSON_READ[json.readJsonRecords]
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
```

---

## bxp-gui: Layers and Components

The GUI is divided into three layers. Each layer has a single direction of
dependency: UI reads from Store, Store calls Services, Services talk to the OS
and to bxp-cli / bxp-fmt subprocesses.

```mermaid
graph TD
    subgraph UI["lib/ui/"]
        EDP["editor_panel.dart
        config tree · expr editor · docs panel"]
        TRP["trace_panel.dart
        variables · rules · output · dry-run viewer"]
        TLB["toolbar.dart
        Run · Validate · Save · Cancel"]
        STG["settings_inspector.dart
        Ctrl+Shift+S drawer"]
    end

    subgraph STORE["lib/store/"]
        TS["TraceStore (ChangeNotifier)
        config AST · diagnostics · trace events
        docs catalog · prefs · run status"]
        TB["TraceBuilder
        folds --trace NDJSON into TraceStore"]
        SG["SchemaGate
        insert order · type guard for Add-Child"]
        DV["DartValidator
        per-edit Dart-side checks
        driven by FnDoc.args + FieldDoc"]
        TM["trace_model.dart
        Dart mirrors of NDJSON event types"]
    end

    subgraph SVC["lib/services/"]
        BPC["BxpProcessClient
        spawns bxp-cli / bxp-fmt
        parses stdout / stderr streams"]
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
        JO["ops.dart
        insert · delete · setValue · move · dup"]
    end

    UI -->|read state| TS
    UI -->|dispatch actions| TS
    TS --> TB
    TS --> SG
    TS --> DV
    TS --> AST
    TS -->|spawn subprocess| BPC
    TS --> PS
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

---

## Dry-run / Runner Flow

Clicking **Run** (or pressing Ctrl+R) triggers a full broker conversion with
`bxp-cli --trace`. Events stream back as NDJSON lines; `TraceBuilder` folds
each event into `TraceStore`. To avoid a rebuild storm (PlutoGrid reallocates
quadratically on every `notifyListeners`), incremental row updates go through
`ValueNotifier<int>` counters; the full `notifyListeners()` fires only twice:
at stream start and after the `done` event.

```mermaid
sequenceDiagram
    participant UI as trace_panel.dart
    participant TS as TraceStore
    participant TB as TraceBuilder
    participant BPC as BxpProcessClient
    participant CLI as bxp-cli --trace

    UI->>TS: runBroker() [Run / Ctrl+R]
    TS->>TS: write draft config to tmp file
    TS->>BPC: streamRun(configPath, template?)
    BPC->>CLI: Process.start(--trace --config ...)
    CLI-->>BPC: {"t":"start",...}
    BPC-->>TS: raw JSON line
    TS->>TS: notifyListeners() [stream started]
    TS->>TB: addLine(json)
    TB->>TS: templates list, set runStatus=running
    loop per-row events
        CLI-->>BPC: row_start / var_eval / rule_match / row_output / row_end
        BPC-->>TS: raw JSON line
        TS->>TB: addLine(json)
        TB->>TS: append RowTrace to current FileTrace
        TS-->>UI: traceLinesCounter.value++ [ValueNotifier — no rebuild]
    end
    CLI-->>BPC: {"t":"file_end",...}
    TS->>TB: addLine(json)
    TB->>TS: finalize FileTrace stats
    TS-->>UI: fileGen.value++ [ValueNotifier — file selector refresh]
    CLI-->>BPC: {"t":"done","exit_code":0}
    BPC-->>TS: stream closed
    TS->>TS: set runStatus / exitCode
    TS-->>UI: notifyListeners() [final render]
```

A 10-second streaming idle watchdog fires `SIGTERM` → `SIGKILL` if no events
arrive for 10 seconds, preventing a hung subprocess from blocking the UI.

---

## Config Editing and AST

Every user edit in the config tree (insert field, delete, setValue, reorder) is
expressed as a `ConfigOp` and applied to the live `AstNode` tree via
`json5_ast/ops.dart`. The dumper re-serialises the AST to JSON5 for display and
for saving. `DartValidator` runs synchronously for fast per-field feedback;
`bxp-fmt --config` is called on every Save for the authoritative full-config
validation.

```mermaid
sequenceDiagram
    participant UI as editor_panel.dart
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

Undo / redo is implemented as an op log (`_opLog` / `_redoStack`) on top of the
AST. Each `ConfigOp` is invertible; undo re-applies the inverse op and
re-validates the same way as a forward edit.

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

    Config "1" *-- "many" BrokerConfig
    BrokerConfig "1" *-- "0..*" PrePass
    BrokerConfig "1" *-- "many" RowRule
    BrokerConfig "1" *-- "0..1" XlsxSheet
    Context --> Value : eval returns
    Diagnostics "1" *-- "many" Diagnostic
```
