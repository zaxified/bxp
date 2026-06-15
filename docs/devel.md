# BXP - Developer Guide

> [← docs/](README.md)

---

## Table of Contents

- [Part 1 - Getting Started](#part-1---getting-started)
  - [VS Code setup](#vs-code-setup)
  - [Verify Zig language version](#verify-zig-language-version)
  - [Claude Code setup](#claude-code-setup)
  - [Repository layout](#repository-layout)
  - [Clone and build](#clone-and-build)
  - [Run the test suite](#run-the-test-suite)
- [Part 2 - Architecture and Internals](#part-2---architecture-and-internals)
  - [Design philosophy](#design-philosophy)
  - [Package dependency graph](#package-dependency-graph)
  - [bxp-core modules](#bxp-core-modules)
  - [bxp-cli internals](#bxp-cli-internals)
  - [inspect core](#inspect-core-stateless-surface)
  - [Two-pass processing pipeline](#two-pass-processing-pipeline)
  - [Expression evaluator (expr.zig)](#expression-evaluator-exprzig)
  - [Configuration system (config.zig + json5.zig)](#configuration-system-configzig--json5zig)
  - [Memory model](#memory-model)
  - [Error handling philosophy](#error-handling-philosophy)
  - [Debugging workflow](#debugging-workflow)
  - [Known issues](#known-issues)
  - [Adding a new conversion template](#adding-a-new-conversion-template)
  - [Adding a new built-in function](#adding-a-new-built-in-function)
  - [Adding a new bridge FFI export](#adding-a-new-bridge-ffi-export)
  - [Testing](#testing)
  - [Release process](#release-process)
  - [Performance model](#performance-model)
  - [Release optimize mode (Small vs Fast)](#release-optimize-mode-small-vs-fast)
  - [GUI development](#gui-development)
  - [Where to dig deeper (CLAUDE.md map)](#where-to-dig-deeper-claudemd-map)

---

## Part 1 - Getting Started

### VS Code setup

Install these extensions for a productive experience:

| Extension           | ID                                                     | Purpose                                                                     |
| ------------------- | ------------------------------------------------------ | --------------------------------------------------------------------------- |
| **Zig Language**    | `ziglang.vscode-zig`                                   | Zig language, Syntax highlighting, ZLS integration, build tasks             |
| **Rainbow CSV**     | `mechatroner.rainbow-csv`                              | Column-aware CSV viewer - helpful when reading broker exports               |
| **JSON5**           | `blueglassblock.better-json5`                          | Syntax highlighting for `JSON5` config files                                |
| **Mermaid preview** | `bierner.markdown-mermaid`                             | Renders Mermaid diagrams in Markdown preview (useful for `architecture.md`) |
| **Mermaid syntax**  | `bpruitt-goddard.mermaid-markdown-syntax-highlighting` | Syntax highlighting for Mermaid diagrams (useful for `architecture.md`)     |

**ZLS (Zig Language Server)** and **Zig language** is bundled with the `ziglang.vscode-zig` extension in recent versions - it provides completions, go-to-definition and inline error diagnostics out of the box.

---

### Verify Zig language version

| Tool | Version    | Notes                                                                 |
| ---- | ---------- | --------------------------------------------------------------------- |
| Zig  | **0.15.2** | Exact version - `build.zig.zon` sets `minimum_zig_version = "0.15.0"` |

`bxp-core` has a **single external (fetch) dependency** — `uucode` (MIT), the
Unicode case-mapping tables behind `UPPER`/`LOWER`, pinned in
`bxp-core/build.zig.zon`. The date and numeric cores stay in-house
(`bxp-core/src/datefmt.zig`, `decimal.zig`). The fetch is cached after the first
build; CI runners have network.

In VS Code terminal:

```bash
zig version
# expected: 0.15.2
```

---

### Claude Code setup

BXP development in Zig works seamlessly with [Claude Code](https://claude.ai/code).
The monorepo ships seven `CLAUDE.md` files — root, `bxp-cli/`, `bxp-core/`,
`bxp-mcp/`, `bxp-gui/`, `bxp-gui-bridge/`, and `bxp-gui/packages/json5_ast/` —
Claude loads these automatically and reads project conventions.

### Skills to use

Install Zig skills from <https://github.com/rudedogg/zig-skills>

| Skill        | When to use                                                     |
| ------------ | --------------------------------------------------------------- |
| `/zig`       | Before writing any new Zig code - loads Zig 0.15.2 API patterns |
| `/zig-build` | Compile the project and get structured error analysis           |
| `/zig-check` | Fast syntax/type check without full build                       |
| `/zig-test`  | Run the test suite and analyze failures                         |

---

### Repository layout

```diagram
bxp/                            # monorepo root (git root)
├── bxp-cli/                    # user-facing CLI binary
│   ├── src/
│   │   ├── main.zig            # arg parsing, config loading, dispatch
│   │   └── pipeline.zig        # processBroker(), xlsxPrePass(), Output, SectionStats
│   ├── build.zig               # imports bxp-core modules by name
│   └── build.zig.zon           # depends on bxp-core (path dep)
├── bxp-mcp/                    # MCP server (JSON-RPC over stdio) for AI agents
│   ├── src/
│   │   ├── main.zig            # entry: arena + --help + server.run()
│   │   ├── server.zig          # MCP stdio loop + JSON-RPC writers
│   │   ├── tools.zig           # tool catalog → bxp-core/inspect calls
│   │   └── sim.zig             # bxp_simulate: stage + spawn bxp-cli + diff
│   ├── build.zig
│   └── build.zig.zon           # depends on bxp-core (path dep)
├── bxp-core/                   # internal shared library (no binary)
│   ├── src/
│   │   ├── csv.zig             # RFC 4180 CSV parser
│   │   ├── xlsx.zig            # .xlsx → CSV (ZIP+XML)
│   │   ├── expr.zig            # expression evaluator + FnDoc catalog
│   │   ├── datefmt.zig         # in-house date parse/format + civil arithmetic (DATE_CONVERT core)
│   │   ├── unicode.zig         # UTF-8 case mapping (UPPER/LOWER) over uucode tables
│   │   ├── config.zig          # JSON5 config loader + FieldDoc tables
│   │   ├── json.zig            # JSON array-of-objects → row representation
│   │   ├── json5.zig           # JSON5 preprocessor (comments, unquoted keys, ...)
│   │   ├── docs.zig            # --docs aggregator: re-exports expr + config catalogs
│   │   └── diagnostics.zig     # structured validation collector (Severity, Diagnostic)
│   ├── build.zig               # exports named Zig modules
│   └── build.zig.zon           # one fetch dep: uucode (Unicode tables)
├── bxp-gui/                    # Flutter desktop app (Linux / macOS / Windows)
│   ├── lib/
│   │   ├── main.dart           # Flutter entry; window + theme + provider wiring
│   │   ├── services/           # subprocess + FFI wrappers, AST loader, prefs, updater
│   │   ├── store/              # TraceStore ChangeNotifier + trace data models
│   │   └── ui/                 # widgets: tree editor, expr panel, row debugger, …
│   ├── packages/json5_ast/     # standalone Dart JSON5 AST library (path dep)
│   ├── linux/, macos/, windows/ # per-platform Flutter shells
│   └── pubspec.yaml
├── bxp-gui-bridge/             # Zig FFI shared library — Win subprocess proxy
│   ├── src/main.zig            # + cross-platform in-proc expr evaluator
│   ├── test/test_helper.zig    # bridge_run / bridge_run_streaming /
│   ├── build.zig               # bridge_eval_expr* C-ABI surface
│   └── build.zig.zon           # depends on bxp-core (path dep)
├── datasets/                   # anonymized sample data + expected outputs
│   └── <template_id>/
│       ├── sample.csv / .xlsx  # input file
│       ├── sample.json         # bxp-cli config for this dataset
│       └── sample.expected     # expected .csvx output (regression baseline)
├── docs/
│   ├── devel.md                # this file
│   ├── architecture.md         # bird's-eye view + data-flow diagrams
│   ├── gui.md                  # bxp-gui developer guide
│   ├── release.md              # release process walkthrough
│   ├── roadmap.md              # forward-looking milestones
│   └── trace-protokol.md       # bxp-cli --trace BXTB + stateless inspect output formats
├── resources/
│   ├── console/                # bxp-cli sample config + readme (bundled in console archives)
│   ├── desktop/                # bxp-gui.desktop template + readme (bundled in desktop archives)
│   └── icons/                  # SVG variants + build-icons.sh (single source for app icons)
├── scripts/
│   ├── test.sh                 # wrapper: runs every test-NN-*.sh in numeric order
│   ├── test-lib.sh             # shared section/step/summary helpers (sourced)
│   ├── test-01-console.sh      # bxp-core unit (incl. inspect) + bxp-cli build + readme src-sync + json5_ast unit
│   ├── test-02-mcp.sh          # bxp-mcp build + unit tests + JSON-RPC smoke (incl. bxp_simulate)
│   ├── test-03-bridge.sh       # bxp-gui-bridge build + unit tests
│   ├── test-04-desktop.sh      # flutter analyze + flutter test + json5_ast dart test (builds bridge .so)
│   ├── test-05-bench-guard.sh  # coarse perf gate: recycles Console's ReleaseSafe bxp-cli
│   ├── test-06-expr-corpus.sh  # cross-runner expression corpus regression gate
│   ├── test-07-datasets.sh     # bxp-cli regression vs datasets/*/*.expected
│   ├── release.sh              # wrapper: release-01-console.sh + release-02-desktop.sh
│   ├── release-01-console.sh   # cross-compile bxp-cli → bxp-console-* archives
│   ├── release-02-desktop.sh   # Flutter bundle → AppImage / .deb / .exe / .dmg
│   ├── release-03-checksums.sh # emit SHA256SUMS for all release artifacts
│   ├── release-changelog.sh    # bump versions + generate CHANGELOG.md entry + commit
│   ├── release-tag.sh          # read version from manifest + tag + push
│   └── check-formatting.sh     # prettier --write + markdownlint + mermaid (pre-release; not auto-run)
└── README.md                   # project overview
```

---

### Clone and build

```bash
# Clone this repository
git clone https://github.com/zaxified/bxp.git

# Build bxp-cli (fetches dependencies on first run)
cd ./bxp/bxp-cli
zig build

# Run
./zig-out/bin/bxp-cli --help
```

Running `bxp-cli` without arguments processes every template defined in `bxp-cli.json`
in the current working directory. \
The typical dev workflow:

```bash
# From the monorepo root
./bxp-cli/zig-out/bin/bxp-cli --config ./datasets/anycoin_to_wealthfolio/sample.json --debug
```

---

### Run the test suite

```bash
# From the monorepo root - runs unit tests + all regression tests
bash scripts/test.sh
```

The test script auto-discovers `test-NN-*.sh` siblings and runs them in numeric order:

1. `test-01-console.sh` — Zig unit tests (incl. `inspect`) + `bxp-cli` build + readme src-sync + `json5_ast` Dart tests.
2. `test-02-mcp.sh` — `bxp-mcp` build + unit tests + JSON-RPC smoke (incl. `bxp_simulate`).
3. `test-03-bridge.sh` — Zig unit tests for the FFI bridge.
4. `test-04-desktop.sh` — `flutter analyze` + `flutter test` for `bxp-gui` (builds the bridge `.so`).
5. `test-05-bench-guard.sh` — coarse perf-regression gate (see below).
6. `test-06-expr-corpus.sh` — expression corpus regression gate (see below).
7. `test-07-datasets.sh` — runs `bxp-cli` against every `datasets/<id>/sample.json` and diffs against `sample.expected`.

All phases build one optimize mode (ReleaseSafe) to minimise the codegen/safety
error surface; the shipped archives (release-01) are the only ReleaseSmall build.

Individual unit tests only:

```bash
cd bxp-core && zig build test
```

#### Expression corpus

`scripts/test-06-expr-corpus.sh` walks `scripts/test-06-expr-corpus.txt` and runs each line through bxp-mcp's `bxp_validate_expr` tool. Format is TAB-separated:

```text
expr<TAB>ok<TAB>expression
expr<TAB>err<TAB>expression<TAB>error_name
```

The corpus doubles as living documentation for the BXP expression language — readable for both contributors and AI template generators. When a parser bug surfaces, add a failing case before fixing; when adding a new built-in function, add an `ok` case + an `err` case for the wrong arity.

`scripts/test.sh` enforces a 60-second per-phase budget on the corpus phase via the `timeout` command, so a parser infinite-loop regression is caught quickly.

---

## Part 2 - Architecture and Internals

See [`docs/architecture.md`](architecture.md) for visual diagrams.

---

### Design philosophy

BXP is a **configuration-driven ETL micro-tool**. The core principle is:

> Adding a new data source = writing a JSON5 template. No code, no recompilation.

Consequences of this design:

- All broker-specific logic lives in `bxp-cli.json` (`conversion_templates` section).
- `bxp-core` is a generic engine: CSV/XLSX parser, expression evaluator, config loader.
- `bxp-cli` is a thin orchestrator: reads config, finds files, calls the engine.
- The expression language is intentionally limited - it handles per-row transformations, not general-purpose computation.

---

### Package dependency graph

```text
  bxp-cli         ── path dep ──►  bxp-core   ── fetch dep ──►  uucode
  (binary)                         (library)                    (Unicode tables)
  bxp-mcp         ── path dep ──►  bxp-core           (wraps inspect.zig; spawns bxp-cli
  (binary)                                             for bxp_simulate)
  bxp-gui-bridge  ── path dep ──►  bxp-core           (links inspect.zig + expr.zig directly)
  (.dll/.so/.dylib)

  bxp-gui  ── FFI ──►  bxp-gui-bridge   (single backend, all platforms:
  (Flutter)                              in-proc inspect + proxied bxp-cli runs)
```

`bxp-core` is a **local path dependency** (`../bxp-core`) and pulls one external
fetch dependency of its own: `uucode` (Unicode case-mapping tables, pinned in
`build.zig.zon`). The date core lives in-house at `bxp-core/src/datefmt.zig`,
replacing the former `sunrise` URL dependency.
`bxp-gui` ships `bxp-cli`, `bxp-mcp`, and `bxp-gui-bridge.{dll,so,dylib}`
inside the Flutter bundle.

### Why the bridge exists

Two independent forces drive the bridge — they happen to combine into one
shared library, but each role solves a different problem.

1. **Windows-only: `dart:io` pipe truncation
   ([dart-lang/sdk#1727](https://github.com/dart-lang/sdk/issues/1727)).**
   `Process.start` on Windows silently cuts subprocess stdout at ~8 KB.
   The docs catalog is ~30 KB and `bxp-cli --trace` is megabytes — both
   unusable through `dart:io`. The bridge reads pipes from native Zig code
   so the drain doesn't depend on the Flutter event loop. On Windows the
   bridge is the **only** path for every subprocess; DLL probe failure at
   startup is fatal (no `Process.start` fallback to silently misbehave).
2. **All platforms: per-keystroke expression eval needs to skip spawn.**
   Validating an expression as a subprocess costs ~50 ms of startup before any
   actual evaluation. The expression editor validates on every keystroke, so the
   spawn cost dominates. `bridge_eval_expr` links `bxp-core/inspect` + `expr`
   directly into the GUI process — no spawn, no pipe drain, sub-millisecond
   evaluation. This path runs on all platforms.

### Per-call routing

Since the v0.3.0 proxy flip every backend call goes through the bridge — there
is no `Process.start` path and no subprocess fallback on any platform:

| GUI call                               | Bridge entry point                                 |
| -------------------------------------- | -------------------------------------------------- |
| config validation (load + save)        | `bridge_inspect {config}`                          |
| docs catalog (startup gate)            | `bridge_inspect {docs}`                            |
| list / fetch templates                 | `bridge_inspect {list_templates / fetch_template}` |
| eval-batch (drill-down re-eval)        | `bridge_inspect {eval_batch}`                      |
| live expr validation (per keystroke)   | `bridge_eval_expr`                                 |
| ExprPlayground per-call trace          | `bridge_eval_expr_trace`                           |
| `bxp-cli --trace` (dry-run / full-run) | `bridge_run_streaming`                             |
| `bxp-cli --version` (probe)            | `bridge_run`                                       |

The first six are in-process (no subprocess); the last two proxy the `bxp-cli`
spawn, draining its pipes in native Zig code. Library probe failure at startup is
fatal on every platform.

Implementation: routing decisions live in
[`bxp-gui/lib/services/bxp_process_client.dart`](../bxp-gui/lib/services/bxp_process_client.dart)
(`_runOneShot`, `_runCliTraceViaBridge`, `traceExpr`). See
[`bxp-gui-bridge/CLAUDE.md`](../bxp-gui-bridge/CLAUDE.md) for the C-ABI surface
of each `bridge_*` entry point.

---

### bxp-core modules

| Module        | File              | Responsibility                                                                                                                                                                                                                                                                                                                      |
| ------------- | ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `csv`         | `csv.zig`         | RFC 4180 parser. `LineIterator` yields records from an in-memory chunk; `splitFields()` unquotes fields. Spaces preserved — trimmed outside csv.zig at access time in `expr.Context`.                                                                                                                                               |
| `xlsx`        | `xlsx.zig`        | Converts `.xlsx` to intermediate `.csv`. Reads ZIP+XML, handles shared strings, formula results, dates (via `styles.xml` numFmtId). Max file size 10 MB.                                                                                                                                                                            |
| `expr`        | `expr.zig`        | Expression evaluator. Recursive-descent parser → evaluator. Per-row `Context` holds field values, ticker map, lookup table. `eval()` returns `Value` (string/decimal/bool — decimal is fixed-point i128, see `decimal.zig`); `evalString()` coerces to string. Each built-in has a co-located `FnDoc` entry consumed by `docs.zig`. |
| `datefmt`     | `datefmt.zig`     | In-house date core (parse / format / civil arithmetic), file-relative `@import` by `expr.zig` — replaced the former `sunrise` dependency. Pre-1970 dates supported (pure parse → format, no epoch round-trip).                                                                                                                      |
| `decimal`     | `decimal.zig`     | Fixed-point `i128` at scale 1e12 (12 fractional digits) numeric core: exact `+ −`, half-away-from-zero `× ÷` / `ROUND`. The named module behind `Value.decimal`; shared by the csv / json / xlsx input paths so an identical numeric string parses identically everywhere.                                                          |
| `config`      | `config.zig`      | Reads `bxp-cli.json` via `json5.zig` preprocessor then `std.json`. Returns `Config` owning all heap memory. `BrokerConfig.validate()` checks semantic constraints. Each struct has a co-located `FieldDoc` table consumed by `docs.zig`.                                                                                            |
| `json`        | `json.zig`        | Reads a JSON array-of-objects into a flat row representation. Builds a union of all keys across all objects; fills missing keys with empty string.                                                                                                                                                                                  |
| `btrace`      | `btrace.zig`      | Binary BXTB trace `Writer` / `Reader` for `bxp-cli --trace`. Carries metadata only (per-row source byte offsets, errors, pre_pass dump, stats); per-row drill-down is recomputed on demand by the GUI via the bridge. The sole trace format since the v0.3.0 NDJSON removal.                                                        |
| `json5`       | `json5.zig`       | Single-pass tokenizer that converts JSON5 → standard JSON. Strips comments, converts unquoted keys, removes trailing commas, normalizes single-quoted strings.                                                                                                                                                                      |
| `docs`        | `docs.zig`        | Aggregates `expr.zig` FnDoc catalog and `config.zig` FieldDoc tables into the docs catalog JSON. Single source of truth consumed by bxp-gui at startup.                                                                                                                                                                             |
| `diagnostics` | `diagnostics.zig` | Structured validation collector. `Severity` (.error / .warning / .info), `Diagnostic` (path, position, code, message, suggest), `Diagnostics` (ArrayList collector). Used by the config validator's deep validation; bxp-cli passes a null sink.                                                                                    |

---

### bxp-cli internals

**`main.zig`** - entry point:

1. Parses `--config`, `--template`, `--data`, `--debug`, `--quiet`, `--fresh`, `--version` flags.
2. Validates file paths (rejects shell metacharacters, limits `../` depth).
3. Loads and validates all templates in config (`config.validate()`).
4. Calls `pipeline.xlsxPrePass()` for any templates that reference `.xlsx` files.
5. Calls `pipeline.processBroker()` for each selected template.
6. Exits with code `0` (success), `1` (error), or `2` (warnings).

**`pipeline.zig`** - processing engine:

- `xlsxPrePass()` - iterates all templates with `xlsx_sheet` defined, converts each
  `.xlsx` file to an intermediate `.csv`. Templates sharing the same `data_dir` share
  the extraction pass (each file extracted once).
- `processBroker()` - the main processing loop (intentionally monolithic):
  1. Reads input files (CSV, JSON, or intermediate CSV from xlsx pre-pass).
  2. Runs `pre_pass` if defined: one full iteration over all rows building a lookup map.
  3. Main loop: evaluates `input_schema` expressions, matches `row_rules`, renders `output_schema` to produce output rows.
  4. Writes RFC 4180-compliant CSV to `.csvx` output files.
- `Output` - thin wrapper around stdout that respects `--quiet` and `--debug` flags.
- `SectionStats` - accumulates warning/error counts and elapsed time across templates.

Deeper detail: [`bxp-cli/CLAUDE.md`](../bxp-cli/CLAUDE.md).

---

### inspect core (stateless surface)

Everything that isn't "run a conversion" — config validation, expression
validation / evaluation / trace, expr-batch, schema/docs emission, template
list/fetch — lives in one stateless module, `bxp-core/src/inspect.zig`. It is
pure: it never reads argv, never writes stdout/stderr, never exits; callers own
all I/O and the arena. Two thin adapters wrap it: **bxp-mcp** (MCP/stdio for
agents) and **bxp-gui-bridge** (FFI for the GUI). A former `bxp-fmt` CLI adapter
wrapped the same calls argv→stdout and was removed once both covered every op.

| inspect function                            | Backed by                                | Purpose                                                                           |
| ------------------------------------------- | ---------------------------------------- | --------------------------------------------------------------------------------- |
| `annotateRaw` / `annotateConfigFromFile`    | `config.load` + `config.validateCollect` | Annotated JSON with `$comm_<N>` / `$err_<N>` / `$warn_<N>` / `$info_<N>` siblings |
| `listTemplatesValue` / `fetchTemplateValue` | `config.load`                            | Template id array / one template's raw JSON                                       |
| `validateExpr` / `validateExprJson`         | `expr.eval` + static FnArgDoc lint       | Authoring-time validation of one expression                                       |
| `evalExpr`                                  | `expr.evalString`                        | Lenient runtime value of one expression                                           |
| `evalTrace`                                 | `expr.eval` (trace_writer)               | Per-call NDJSON trace stream                                                      |
| `evalBatch`                                 | `expr.evalString` ×N                     | Evaluate N exprs against one row in a single call; `{results:[…]}`                |
| `docsJson`                                  | `docs.writeDocs`                         | Full FnDoc / FieldDoc catalog (single source for bxp-gui startup)                 |

Adding an op: write the pure function in `inspect.zig`, then expose it from each
adapter (a `bxp-mcp` tool in `bxp-mcp/src/tools.zig` + a `bridge_*` entry in
`bxp-gui-bridge/src/main.zig`). No business logic lives in the adapters.

Deeper detail: [`bxp-mcp/CLAUDE.md`](../bxp-mcp/CLAUDE.md),
[`bxp-gui-bridge/CLAUDE.md`](../bxp-gui-bridge/CLAUDE.md).

---

### Two-pass processing pipeline

```text
Input file (CSV/XLSX/JSON)
        │
        ▼
[xlsx_prepass]  ← if xlsx_sheet defined  → intermediate .csv
        │
        ▼
[pre_pass]      ← optional: full scan    → lookup table (keyed by expression)
        │
        ▼
[main loop - per row]
  1. Evaluate input_schema   → $variables
  2. Match row_rules         → set $action (+ overrides)
  3. Render output_schema    → output row
  4. Write to .csvx
```

A single input row can produce **0, 1, or N output rows** depending on `row_rules`. \
`rows: []` = silent skip \
`rows: [{...}, {...}]` = two output rows from one input row.

---

### Expression evaluator (expr.zig)

The evaluator is a hand-written recursive-descent parser.
Operator precedence (high → low):

```text
unary -  →  * /  →  & (concat)  →  + -  →  = != < > <= >=  →  AND  →  OR
```

**How to add a new function:** see [Adding a new built-in function](#adding-a-new-built-in-function) below.

Key types:

```c
pub const Value = union(enum) {
    string: []const u8,
    decimal: Decimal,   // fixed-point i128 @ 1e12 (decimal.zig), not f64/f80
    boolean: bool,
};

pub const Context = struct {
    fields: []const []const u8,                 // raw CSV field values for current row
    col_index: std.StringHashMap(usize),        // header name → field index
    maps: ?*MapRegistry,                        // named maps for REMAP/REPLACE
    lookup_table: ?*LookupTable,
    alloc: std.mem.Allocator,
    decimal_sep_in: u8,                         // '.' or ','
    quote_out: u8,                              // output quoting character
};
```

Type coercions:

- Empty string → `0` in numeric context.
- Any non-empty string → `true` in boolean context.
- Numbers are formatted as strings: trailing `.0` stripped (`"99.00"` → `"99"`).

---

### Configuration system (config.zig + json5.zig)

Config loading sequence:

```text
bxp-cli.json  →  json5.preprocess()  →  std.json.parseFromSlice()  →  Config struct
```

`json5.zig` is a pure preprocessor - it only transforms text. The output is always
valid JSON consumed by the standard library parser. This means the full JSON5 feature
set (comments, trailing commas, unquoted keys, single-quoted strings) is supported
at zero cost: no custom JSON parser needed.

`Config` owns all heap-allocated strings. Call `cfg.deinit()` to free everything.
`BrokerConfig` (one per template) holds the parsed template fields, pre_pass config,
input/output schemas, and row rules.

---

### Memory model

Two arena allocators are used during processing:

| Allocator                     | Lifetime                    | Owns                                          |
| ----------------------------- | --------------------------- | --------------------------------------------- |
| `file_alloc` (ArenaAllocator) | Reset after each input file | File content, parsed rows, expression results |
| `line_alloc` (ArenaAllocator) | Reset after each row        | Per-row expression evaluation scratch space   |

The root GPA (`std.heap.DebugAllocator`) catches leaks in debug builds.

---

### Error handling philosophy

Three concerns, three mechanisms:

**1. Exit codes (CLI contract).** `bxp-cli`:

| Code | Meaning                                                                 |
| ---- | ----------------------------------------------------------------------- |
| `0`  | Success                                                                 |
| `1`  | Fatal error (invalid config, file not found, broken expression at load) |
| `2`  | Warnings (typo'd field, unknown column, no input rows)                  |

Exit `2` runs to completion — the user gets converted output AND a warning
text on stderr. CI scripts treat `2` as failure (see "datasets are exemplary"
convention).

**2. Diagnostics (deep validation).** `bxp-core/diagnostics.zig` defines a
structured collector consumed by config validation (`inspect.annotateRaw`):

```text
Severity   ∈ { .error, .warning, .info }
Diagnostic = { path, off?, len?, severity, code, message, suggest? }
```

`config.zig`, `json5.zig`, and `expr.zig` accept an optional `*Diagnostics`
sink — `bxp-cli` passes `null` (fail-fast / stderr behaviour preserved),
The config validator passes a real bag and renders findings as `$err_<N>` / `$warn_<N>` /
`$info_<N>` siblings in the annotated JSON output. The GUI reads those keys
to decorate the tree with inline error markers.

**3. User-facing messages.** Use `std.process.exit(1)` for fatal CLI
errors — no Zig stack trace leaks to the user. Severity routing in `--trace`
mode: `Output.warning()` writes to stderr (stdout is reserved for the binary
BXTB frame stream); fatal errors also stderr.

> **Naming note — BXTB.** Short for **BXP Trace Binary**; nothing to do with
> the XTB broker that several conversion templates target. The four ASCII
> bytes `B`, `X`, `T`, `B` are written verbatim as the file-format magic at
> the start of every `--trace` stream so `bxp-gui` and offline tools can
> reject anything that does not begin with them. Defined in
> [`bxp-core/src/btrace.zig`](../bxp-core/src/btrace.zig) as
> `FRAME_MAGIC = 0x42545842` (little-endian).

**4. Template-strict, data-lenient (expr engine).** Two audiences get two
policies, by who can fix the problem and when:

- **Template author** — literals, config, expressions. A mistake here is a
  bug the author can fix, so fail **loud and early**: static literal checks
  (`SplitPartBadIndex`, `DateFormatBadToken`) at config-load, `$err_`
  diagnostics, exit 1. The central `validateArgs` dispatcher
  (`expr.zig`) enforces arity + arg-domain contracts here too.
- **Broker data** — runtime field values from CSV/JSON. A "bad" value is
  almost always an imperfection in the source the author can't fix (blank
  settlement date, missing optional column, odd format), so **accommodate**:
  return `""` / coerce (`toNumber("") → 0`, `DATE_CONVERT` parse-fail → `""`,
  date builtins on empty → `""`, an out-of-range `FIELDS`/`DATEADD` index →
  `""`). Aborting a 10k-row conversion over one messy row is worse than
  emitting `""` and continuing.

These compose, they don't conflict: a runtime silent-`""` is a deliberate
**output policy**, while **code safety is orthogonal and still required** —
the path that produces the skip must not panic (`@intFromFloat` on Inf/huge
is guarded by `toPositiveIndex` / `toDayOffset`, which then return the
lenient `""`). When hardening such a path, fix the crash but keep the silent
`""`; do not "upgrade" a data-derived skip into a loud error. The lenient
runtime is safe because other layers answer "did I write the template
right?": the static checks above, `--debug` + `row_rules_debug_missing`
(unmatched-row surfacing), and the GUI per-cell trace where the author sees
the `""`.

---

### Debugging workflow

**bxp-cli verbosity flags** — composable, all on the same binary:

| Flag           | What it does                                                                                    |
| -------------- | ----------------------------------------------------------------------------------------------- |
| `--debug`      | Prints unmatched rows when `row_rules_debug_missing: true`                                      |
| `--quiet`      | Suppresses per-template summaries (exit code still reflects result)                             |
| `--trace`      | Emits BXTB frame stream on stdout (consumed by `bxp-gui`'s dry-run debugger). Implies `--quiet` |
| `--check-fs=N` | Adds filesystem-existence checks (templates' `data_dir`, etc.) with N-second timeout            |

**Inspecting an expression in isolation** (via the `bxp-mcp` server — one
JSON-RPC object per line on stdin):

```bash
# Validate one expression (authoring-time check; no row context)
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"bxp_validate_expr","arguments":{"expr":"IF([Qty] > 0, '\''BUY'\'', '\''SELL'\'')"}}}' \
  | ./bxp-mcp/zig-out/bin/bxp-mcp

# Trace per-call values against a fake row (bxp_eval_trace)
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"bxp_eval_trace","arguments":{"expr":"[Price] * [Qty]","headers":"[\"Price\",\"Qty\"]","fields":"[\"12.50\",\"100\"]"}}}' \
  | ./bxp-mcp/zig-out/bin/bxp-mcp
```

**bxp-gui live debug (Claude Code MCP loop):** see [`gui.md`](gui.md#debugging-with-print)
for the `mcp__dart__launch_app` → `hot_reload` → `get_app_logs` cycle. Quick
tip: `print()` from Dart is captured; `developer.log()` is not.

**Settings inspector (Ctrl+Shift+S in bxp-gui):** opens an internal-state
drawer showing the loaded config, parsed AST, schema docs, op log, and
validation errors. The fastest way to confirm "is the GUI seeing what I
think it's seeing?".

---

### Known issues

**VMware Workstation host: maximize lag on ultra-wide resolutions.**
When running bxp-gui inside a VMware Workstation Windows guest,
maximizing the window onto a viewport larger than ~1920×1200 produces a
1-3 s freeze on the maximize transition. Bare-metal Windows, macOS,
Linux, and VirtualBox guests are not affected.

The freeze is the VMware SVGA D3D11 driver reallocating swap-chain
surfaces on size change — initial paint at the same target resolution
is fluid; only the size-change event triggers it. This is upstream
Flutter / Win32 D3D11 behaviour and cannot be patched in the runner.

**Workaround:** none required. The lag clears itself in 1-3 s, the
window does not crash, and subsequent resizes within the same surface
size are smooth. Documented here so a "maximize is laggy on VMware"
report is not mistaken for a regression.

---

### Adding a new conversion template

No code changes required — adding a broker is purely configuration work. The
full config schema, expression reference, and field-by-field walkthrough live
in the user-facing guide:

→ [`resources/console/readme.md`](../resources/console/readme.md)

That document is what gets shipped inside `bxp-console` archives, so it
double-serves new contributors and end users. The short skeleton:

```json
"broker_to_tracker": {
  "data_dir":     "../data/broker_to_tracker",
  "file_pattern_in": ".csv",
  "input_schema": { "$date": "...", "$ticker": "...", /* ... */ },
  "row_rules":    [ { "when": "...", "rows": [ { "$action": "'BUY'" } ] } ],
  "output_schema": { "date": "$date", /* ... */ }
}
```

Dev-only tips (not in the user guide):

- Start with `row_rules_debug_missing: true` + run with `--debug` to surface
  rows that match no rule.
- For paired-row brokers (one row references another via an order ID),
  use `pre_pass` + `LOOKUP()`. AnyCoin is the reference template.
- Drop a `datasets/<template_id>/{sample.csv, sample.json, sample.expected}`
  triple to wire the template into the regression suite — `scripts/test.sh`
  picks it up automatically.

---

### Adding a new built-in function

1. **Define the function** in `bxp-core/src/expr.zig`:
   - Find the `evalFunc()` helper (called from the parser when a function name is recognized).
   - Add a new `if (std.mem.eql(u8, name, "MY_FUNC")) { ... }` branch.
   - Functions receive already-evaluated `Value` arguments.
   - Return a `Value` or propagate an error.

2. **Add a `FnDoc` entry** co-located with the implementation — follow the `── MY_FUNC ──`
   section-header pattern used by the existing built-ins. `docs.zig` re-exports the
   catalog automatically; no separate doc file to update.

3. **Add unit tests** inline in `expr.zig`:

   ```c
   test "MY_FUNC basic" {
       // ... uses std.testing.expectEqualStrings / expectApproxEqAbs
   }
   ```

4. **Run tests:**

   ```bash
   cd bxp-core && zig build test --summary all
   ```

---

### Adding a new bridge FFI export

The bridge hosts a **new-style FFI family** — synchronous, in-process C-ABI
exports that link a stateless `bxp-core` routine directly into the GUI process,
skipping the subprocess spawn. The first two members are `bridge_eval_expr`
(in-proc expr validation) and `bridge_eval_expr_trace` (in-proc expr
trace). The plan is to add more such direct calls once `bxp-core`'s
`inspect` surface stabilises and stops churning internally — every new
member follows the conventions below so adding the tenth export is as
mechanical as adding the first.

> These conventions cover the **stateless `bridge_eval_*` family only**. The
> legacy subprocess-proxy exports (`bridge_run`, `bridge_run_streaming`,
> `bridge_cancel`, `bridge_ack`, `bridge_free`) keep their own established
> conventions from the proxy era. A future **handle-based** family (stateful,
> e.g. a loaded-config handle) would need a separate convention set — lifecycle,
> per-handle memory, handle-table thread safety — deliberately out of scope here.

**1 — Buffer protocol.** Caller supplies the output buffer; the bridge never
`malloc`s the result and there is no Dart-side free for this family.

```zig
export fn bridge_eval_xxx(
    /* input params */
    out_buf: [*]u8, out_size: u32,
) callconv(.c) i32;
```

| Return | Meaning                                                                   |
| ------ | ------------------------------------------------------------------------- |
| `0`    | Success, no payload (valid, nothing to report)                            |
| `> 0`  | `bytes_written` to `out_buf` — may carry a success **or** failure payload |
| `< 0`  | Bridge-level error code (see rule 2)                                      |

A positive return does **not** automatically mean success: for exports where
error info belongs in the payload (`bridge_eval_expr` returns
`{"error":...,"off":...,"len":...}` JSON), the caller always parses `out_buf`
when `bytes_written > 0`. What a non-zero payload means is documented per-export
in its doc comment. On overflow the caller retries with a bigger buffer (4 KB
default for expr, 64 KB retry) — mirrors the `largeBufSize` retry in
`BridgeClient`.

**2 — Error codes.** Bridge-level failures (problems originating _in the bridge
layer_, not in evaluation) are a negative `i32` enum:

```zig
const BridgeFfiError = enum(i32) {
    out_of_memory = -1,   // c_allocator can't satisfy the per-call arena
    buf_too_small = -2,   // out_buf overflowed mid-write; caller retries bigger
    invalid_input = -3,   // caller's request is malformed: fix the call site
};
```

Note there is **no `eval_error` code**. Evaluation-level failures (syntax error,
unknown function, divide-by-zero) are _not_ a negative code — they return
`bytes_written > 0` with a structured JSON payload (rule 4). This was a
deliberate Phase-1 decision: keep negative codes for "your call is broken" and
let payloads carry "the expression is broken, show the user." Any new export
follows the same split.

**3 — Memory ownership: caller-owns-everything.** Input pointers are owned by
the caller for the call's duration; the bridge must hold no reference past
return. The output buffer is caller-allocated and caller-freed. Internally the
export opens a per-call `ArenaAllocator.init(c_allocator)` with `defer
arena.deinit()` — every transient allocation dies at return. No handle table,
no Dart-side `bridge_free` for this family.

**4 — Stateless + thread-safe.** Calling `bridge_eval_xxx(args)` 100× is
semantically identical to calling it once: no loaded configs, cached rows, or
counters survive between calls (the only allowed global is the read-only,
init-once docs catalog). Because there is no shared mutable state and the arena
is per-call, the family is thread-safe without mutexes — safe to call directly
from the Dart main isolate (sub-ms latency, well under one frame budget). If a
future export genuinely needs persistent state, it belongs in the handle-based
family, not here.

**5 — UTF-8, length-prefixed strings.** Inputs are `ptr: [*]const u8, len: u32`,
**not** null-terminated (`[*:0]`): Dart strings may contain interior `\0`, the
explicit length skips a `strlen`, and it stays consistent with the output buffer
protocol. JSON args (e.g. `row_headers` / `row_fields` for the trace export)
follow the same shape.

**6 — Output JSON shape matches the `inspect` core contract.** A failure payload is
byte-identical to the shape `inspect.validateExpr` produces (the same one bxp-mcp returns),
so the existing Dart parser handles bridge and subprocess responses
identically — no Dart parser change when wiring a new export:

```json
{"error":"<ErrorName>","detail":"<detail>","off":N,"len":N,"suggest":"..."}
```

`off` / `len` / `suggest` are optional (emitted only when the parser pins a token
or has a "did-you-mean" candidate). The trace export instead emits an NDJSON
stream identical to `inspect.evalTrace` output, where success/failure is read
from the `t` field of the last line.

**Worked reference — the shipped `bridge_eval_expr`:** see
[`bxp-gui-bridge/src/main.zig`](../bxp-gui-bridge/src/main.zig) (`bridge_eval_expr`,
`writeExprErrorJson`, `writeStaticErrorJson`). Note it does two things beyond a
bare `expr.eval`: it runs `expr.staticCheckCalls` after a clean eval to catch
literal-only mistakes the runtime skips (e.g. `SPLIT_PART(..., 0)`), mirroring
`BrokerConfig.validate()` so editor-time and Save-time diagnostics agree. The
Dart side lives in
[`bxp-gui/lib/services/bridge_client.dart`](../bxp-gui/lib/services/bridge_client.dart).

Any ABI change (signature, new error code) must bump both the bridge export and
its Dart shim in the **same commit** — there is no auto-versioned compatibility
shim, so a stale `.so`/`.dll` against a new GUI silently misbehaves.

---

### Testing

```bash
# run test
./scripts/test.sh
```

`test.sh` runs seven sub-scripts in numeric order. Every phase builds the same
optimize mode (**ReleaseSafe**) — one codegen + safety config across the whole
gate keeps the error surface small (a mode-specific bug, like the bridge's
Debug-only SEGV, can't slip through a gap the tests never exercise). The shipped
archives (`release-01`) are the only ReleaseSmall build.

**`test-01-console.sh`** — Zig / CLI build + unit:

1. `zig build test` in `bxp-core` (unit tests for `csv.zig`, `expr.zig`, `json5.zig`, `docs.zig`, `diagnostics.zig`).
2. Builds `bxp-cli` + runs its unit tests.
3. `dart test` inside `bxp-gui/packages/json5_ast/` + readme src-sync drift guard.

**`test-02-mcp.sh`** — `bxp-mcp` build + unit tests + JSON-RPC smoke for the
stateless tools (`bxp_validate`, `bxp_validate_expr`, `bxp_eval_batch`, …) plus
a full `bxp_simulate` run.

**`test-03-bridge.sh`** — `bxp-gui-bridge` build + unit tests (FFI surface).

**`test-04-desktop.sh`** — Flutter / Dart side:

1. Builds `bxp-gui-bridge` shared library (needed for `expr_corpus_bridge_test.dart`).
2. `flutter analyze` — static analysis of `bxp-gui/`.
3. `flutter test` — widget + service tests in `bxp-gui/test/`.
4. `dart test` inside `bxp-gui/packages/json5_ast/` — json5_ast unit + round-trip tests.

**`test-05-bench-guard.sh`** — coarse perf-regression gate; recycles the Console
phase's ReleaseSafe `bxp-cli` and asserts an RSS ceiling + a scaling ratio.

**`test-06-expr-corpus.sh`** — expression corpus regression gate (TAB-separated
`expr<TAB>ok|err<TAB>...` cases).

**`test-07-datasets.sh`** — bxp-cli regression: iterates every `datasets/<id>/`
directory and diffs output against `sample.expected`.

> Docs formatting is **not** a test phase. `scripts/check-formatting.sh`
> (`prettier --write` + `markdownlint` + mermaid parse) is a standalone
> pre-release step — `test.sh` does not run it.

Individual sub-suites:

```bash
cd bxp-core && zig build test           # Zig unit tests only
bash scripts/test-01-console.sh        # console side only (no Flutter dep)
bash scripts/test-03-desktop.sh        # Flutter side only
```

**Adding a regression test:**
Place `sample.csv` (or `.xlsx`) + `sample.expected` + `sample.json` in `datasets/<template_id>/`.
The test script picks them up automatically.

**Anonymizing test data:**
Before committing `.csv` or `.xlsx` files in `datasets/`, strip real account or personal data.

---

### Release process

See [`docs/release.md`](release.md) for the full operator walkthrough. Summary:

Two release channels, distinct archives:

| Channel       | Archives                                                                                    | Content                                                  |
| ------------- | ------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| `bxp-console` | `bxp-console-<ver>-{linux-x86_64.tar.gz, macos-aarch64.tar.gz, windows-x86_64.zip}`         | CLI binary only                                          |
| `bxp-desktop` | `bxp-desktop-<ver>-{linux.AppImage, linux.deb, linux.tar.gz, windows-setup.exe, macos.dmg}` | Flutter GUI + bundled bxp-cli + bxp-mcp + bxp-gui-bridge |

```bash
# 1. Bump manifests + CHANGELOG (commits "release: prepare X.Y.Z (YYYY.MM.DD)")
bash scripts/release-changelog.sh patch   # or minor / major / 0.3.0

# 2. Push the bump commit so the tag points at a public ref
git push origin master

# 3. Tag from the version just bumped + push (triggers GitHub Actions pipeline)
bash scripts/release-tag.sh

# Or build locally without tagging:
bash scripts/release-01-console.sh v0.3.0-rc1   # console archives
bash scripts/release-02-desktop.sh v0.3.0-rc1   # host-OS desktop bundle
```

The GitHub Actions pipeline fans out across ubuntu / windows / macos runners so
all native installers come from real native builds.

---

### Performance model

A simplified map of what makes the runtime fast and what slows it down, plus
where the benchmarks live. The whole model rests on one invariant: **every
output row is a pure function of one input row plus the (already-built)
pre_pass lookup table** — no cross-row state in the main loop. That purity is
what unlocks streaming, parallelism, and parse-once below.

**What speeds it up** (roughly in order of impact):

- **Streaming + bounded memory.** `processBroker` reads CSV in
  `CHUNK_SIZE = 10 MiB` blocks (`ChunkReader`) and resets a per-chunk arena
  between blocks; JSON streams through `std.json.Reader` in a two-pass design.
  Peak RSS is `O(longest row + pre_pass table)`, **not** `O(file size)` — a
  pre-2026-05-17 pipeline grew RSS `O(N)` (~10 GB on 2M rows); the streaming
  rewrite holds it to a small constant (~24 MB across the bench matrix).
- **Per-block parallel evaluation.** Rows within a chunk are independent, so
  they fan out across a `std.Thread.Pool` and re-stitch in source order — see
  [architecture.md → Parallel Evaluation](architecture.md#parallel-evaluation-per-block-fork-join).
- **Parse-once expression eval (Phase 3B).** `input_schema` and `row_rules`
  expressions are tokenized/parsed **once per file** into `compiled_schema` /
  `compiled_rules` `Node` arrays (`pipeline.zig`), then evaluated per row
  without re-parsing.
- **Constant folding.** Row-invariant `input_schema` vars (no column / field
  reference) are evaluated once at file-start and reused for every row
  (`folded_vars`).
- **Skip dead work.** The `date_fast_path` evaluates `$date` first and drops
  an out-of-range row **before** `evalAllVars` when `date_filter_from_filename`
  is on; a var that a matched rule overrides skips its base evaluation (the
  override supplies the value).
- **Free passthrough.** A field copied straight to output never routes through
  the numeric core — it keeps full precision _and_ pays no parse cost. Only
  genuinely _computed_ numbers go through `decimal.zig` (fixed-point `i128`,
  exact, float-free).
- **`memchr`-based scanning.** CSV record/field boundaries are found with
  `std.mem.indexOfScalar` / `lastIndexOfScalar` (lazy-quotes parser), 12–41 %
  faster than the prior byte loop on large inputs.

**What slows it down** (cost factors to expect):

- **`--trace`** emits a BXTB metadata frame per output/filtered/error row —
  budget extra IO for dry-runs vs a plain conversion.
- **ReleaseSmall** (the shipped console binary) is ~1.3–1.7× slower than
  `ReleaseFast` on compute-heavy runs — see the table below.
- **Wide columns** cost `O(cols)` per row (field split + `col_index` lookups);
  a 1024-col file is dominated by per-row column work, not codegen.
- **Heavy computed arithmetic** (vs passthrough) routes every value through the
  decimal core; lots of `ROUND` / `*` / `/` per row shows up here.
- **Debug builds** are 10–50× slower with a different RSS profile — never
  perf-measure a `zig build` (Debug) artifact; build `-Doptimize=ReleaseFast`.

**Benchmarking.** Two harnesses, different jobs:

- **`scripts/bench/bench.sh`** — the stress-test matrix. Sweeps rows / columns
  / cell-width / expr-count / trace on/off (`S1`–`S6`); `gen.py` emits a
  synthetic `input.in.csv` + `bxp-cli.json` per point; each run is measured
  under `/usr/bin/time -f '%e %M'`. Output → `scripts/bench/results/results-<UTC>.csv`
  (columns: `wall_s`, RSS, output bytes, trace event count/bytes). It rebuilds
  `ReleaseFast` first; knobs: `BENCH_WORK`, `BENCH_TIMEOUT`, `BENCH_PARALLEL`,
  `BENCH_SKIP_BUILD`. Dev-only — **not** part of `test.sh`.
- **`scripts/test-05-bench-guard.sh`** — the coarse perf gate, a `test.sh`
  phase. Asserts only two **machine-independent** invariants so it can't flake
  on absolute seconds: an **RSS ceiling** (`GUARD_RSS_MB`, default 64 MB —
  catches any regression back to `O(N)` buffering) and a **scaling ratio**
  (`wall(large N) / wall(small N)` must stay near the row ratio — catches an
  accidental `O(n²)` path). Recycles the Console phase's `ReleaseSafe` bxp-cli
  (same package cache → no second build, just the measured runs); the whole
  suite is one mode, so the guard measures the same codegen the tests do.
- **`scripts/bench/verify-output.sh`** — correctness, not speed: runs bxp-cli
  over `datasets/` + `examples/real-world/` into a dir for a before/after
  `diff -r` (use around any optimization to prove output stays byte-identical).

---

### Release optimize mode (Small vs Fast)

`scripts/release-01-console.sh` builds bxp-cli with `-Doptimize=ReleaseSmall`.
The console archive ships the small binary by design — small downloads,
small docker layers, small footprint for users who run bxp-cli once a week
on a few-hundred-row broker export.

For perf-critical local runs (large CSVs, repeated batch processing) you can
rebuild with `zig build -Doptimize=ReleaseFast`. Measured deltas on
representative synthetic workloads (serial, warm cache, NVMe-backed, 3 reps
each, median wall-clock):

| Scenario                                                | Profile          | Small  | Fast   | Speedup |
| ------------------------------------------------------- | ---------------- | ------ | ------ | ------- |
| 100k rows × 1024 cols, w=20 (2.0 GB CSV, per-block ‖)   | wide-cols, ‖ CPU | 22.59s | 17.24s | 1.31×   |
| 2M rows × 16 cols, w=20 (551 MB CSV, reader-bound)      | row-heavy        | 9.82s  | 5.99s  | 1.64×   |
| 100k rows × 16 cols, w=20 (28 MB CSV, passthrough only) | minimal work     | 0.39s  | 0.23s  | 1.70×   |

Binary size cost: 377 KB → 5.5 MB (≈ 15×). RSS in both modes is identical
(within measurement noise; ~24 MB across all three scenarios).

The wide-cols parallel path benefits the **least** from ReleaseFast because
it is dominated by per-block synchronization and IO rather than per-row
codegen quality. The minimal-work passthrough benefits the **most** because
fixed-cost dispatch overhead is where codegen quality shows up cleanest.

Bench artifacts: `scripts/bench/work/rsrf/` (driver + per-run CSV).
Reproduce via `scripts/bench/work/rsrf/run.sh` after generating inputs with
`python3 scripts/bench/gen.py`.

---

### GUI development

See [`docs/gui.md`](gui.md) for a full bxp-gui developer guide covering Flutter
architecture, subprocess wiring, the json5_ast AST library, dev-run workflow, and
key patterns (ValueNotifier streaming, HardwareKeyboard shortcuts, fractional splitters).

---

### Where to dig deeper (CLAUDE.md map)

`docs/` covers orientation and cross-module flow. The deepest reference for
each module — internal API contracts, design decisions, "known non-issue"
rationales — lives in per-module `CLAUDE.md` files. They're loaded
automatically by Claude Code, but you can read them directly any time.

| Module           | File                                                                              | What's in it                                                                             |
| ---------------- | --------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Monorepo         | [`CLAUDE.md`](../CLAUDE.md)                                                       | Top-level layout + package dep graph + cross-cutting conventions                         |
| `bxp-cli`        | [`bxp-cli/CLAUDE.md`](../bxp-cli/CLAUDE.md)                                       | Full config reference, expression syntax, broker list, exit codes, output stream routing |
| `bxp-mcp`        | [`bxp-mcp/CLAUDE.md`](../bxp-mcp/CLAUDE.md)                                       | MCP tool catalog, annotated JSON shape (`$comm_*`/`$err_*`/…), wire protocol             |
| `bxp-mcp`        | [`bxp-mcp/CLAUDE.md`](../bxp-mcp/CLAUDE.md)                                       | MCP server: adapter model, tool catalog, in-proc vs spawn, wire protocol, bxp_simulate   |
| `bxp-core`       | [`bxp-core/CLAUDE.md`](../bxp-core/CLAUDE.md)                                     | Per-module API surface, build details, "known non-issues" rationale                      |
| `bxp-gui`        | [`bxp-gui/CLAUDE.md`](../bxp-gui/CLAUDE.md)                                       | Flutter app structure, services/store/ui split, MCP debug workflow                       |
| `bxp-gui-bridge` | [`bxp-gui-bridge/CLAUDE.md`](../bxp-gui-bridge/CLAUDE.md)                         | C-ABI surface, Debug→ReleaseSafe rewrite rationale, Win-mandatory / cross-platform roles |
| `json5_ast`      | [`bxp-gui/packages/json5_ast/CLAUDE.md`](../bxp-gui/packages/json5_ast/CLAUDE.md) | Standalone-library-candidate status, comment ownership, future extraction recipe         |
