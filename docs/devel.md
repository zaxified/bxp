# BXP - Developer Guide

> For end-user documentation see [`resources/readme.md`](../resources/readme.md) \
> For architecture diagrams see [`docs/architecture.md`](architecture.md)

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
  - [Two-pass processing pipeline](#two-pass-processing-pipeline)
  - [Expression evaluator (expr.zig)](#expression-evaluator-exprzig)
  - [Configuration system (config.zig + json5.zig)](#configuration-system-configzig--json5zig)
  - [Memory model](#memory-model)
  - [Adding a new conversion template](#adding-a-new-conversion-template)
  - [Adding a new built-in function](#adding-a-new-built-in-function)
  - [Testing](#testing)
  - [Release process](#release-process)

---

## Part 1 - Getting Started

### VS Code setup

Install these extensions for a productive experience:

| Extension | ID | Purpose |
| -- | -- | -- |
| **Zig Language** | `ziglang.vscode-zig` | Zig language, Syntax highlighting, ZLS integration, build tasks |
| **Rainbow CSV** | `mechatroner.rainbow-csv` | Column-aware CSV viewer - helpful when reading broker exports |
| **JSON5** | `blueglassblock.better-json5` | Syntax highlighting for `JSON5` config files |
| **Mermaid preview** | `bierner.markdown-mermaid` | Renders Mermaid diagrams in Markdown preview (useful for `architecture.md`) |
| **Mermaid syntax** | `bpruitt-goddard.mermaid-markdown-syntax-highlighting` | Syntax highlighting for Mermaid diagrams (useful for `architecture.md`) |

**ZLS (Zig Language Server)** and **Zig language** is bundled with the `ziglang.vscode-zig` extension in recent versions - it provides completions, go-to-definition and inline error diagnostics out of the box.

---

### Verify Zig language version

| Tool | Version | Notes |
| -- | -- | -- |
| Zig | **0.15.2** | Exact version - `build.zig.zon` sets `minimum_zig_version = "0.15.0"` |

No other runtime dependencies. `bxp-core` fetches `sunrise` (datetime library) automatically via `zig build` on first run.

In VS Code terminal:

```bash
zig version
# expected: 0.15.2
```

---

### Claude Code setup

BXP development in Zig works seamlessly with [Claude Code](https://claude.ai/code).
The monorepo ships `CLAUDE.md` files at the root, `bxp-cli/`, and `bxp-core/` levels - Claude loads these automatically and reads project conventions.

### Skills to use

Install Zig skills from <https://github.com/rudedogg/zig-skills>

| Skill | When to use |
| -- | -- |
| `/zig` | Before writing any new Zig code - loads Zig 0.15.2 API patterns |
| `/zig-build` | Compile the project and get structured error analysis |
| `/zig-check` | Fast syntax/type check without full build |
| `/zig-test` | Run the test suite and analyze failures |

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
├── bxp-core/                   # internal shared library (no binary)
│   ├── src/
│   │   ├── csv.zig             # RFC 4180 CSV parser
│   │   ├── xlsx.zig            # .xlsx → CSV (ZIP+XML)
│   │   ├── expr.zig            # expression evaluator
│   │   ├── config.zig          # JSON5 config loader
│   │   ├── json.zig            # JSON array-of-objects → row representation
│   │   └── json5.zig           # JSON5 preprocessor (comments, unquoted keys, ...)
│   ├── build.zig               # exports named Zig modules
│   └── build.zig.zon           # depends on sunrise (url dep, auto-fetched)
├── datasets/                   # anonymized sample data + expected outputs
│   └── <template_id>/
│       ├── sample.csv          # .csv or .xlsx (then .csv is intermediate)
│       ├── sample.csvx         # final output file
│       └── sample.expected     # expected output - test.sh regression baseline (diff with csvx)
├── docs/
│   ├── devel.md                # this file
│   └── architecture.md         # Bird's-eye view, data flow, execution diagrams
├── resources/
│   ├── bxp-cli.examples.json   # example config (released alongside binary)
│   └── readme.md               # end-user documentation (released alongside binary)
├── scripts/
│   ├── test.sh                 # test suite (unit + regression)
│   └── release.sh              # cross-compile + package
└── README.md                   # basic readme about project
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

The test script:

1. Runs `zig build test` in `bxp-core` (unit tests for `csv.zig`, `expr.zig`, `json5.zig`).
2. Builds `bxp-cli`.
3. Iterates every `datasets/<id>/` directory, runs bxp-cli against the sample inputs, and diffs the output against `sample.expected`.

Individual unit tests only:

```bash
cd bxp-core && zig build test
```

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
  bxp-cli  ── path dep ──►  bxp-core  ── url dep ──►  sunrise
  (binary)                  (library)                 (datetime)
```

`bxp-core` is referenced as a **local path dependency** (`../bxp-core`) in
`bxp-cli/build.zig.zon` - no network fetch needed during development.
`sunrise` is a URL dependency fetched by Zig's package manager on first build.

---

### bxp-core modules

| Module | File | Responsibility |
| -- | -- | -- |
| `csv` | `csv.zig` | RFC 4180 parser. `splitRecords()` slices raw content; `splitFields()` unquotes fields. Intentional deviation: leading/trailing whitespace trimmed (broker exports pad fields). |
| `xlsx` | `xlsx.zig` | Converts `.xlsx` to intermediate `.csv`. Reads ZIP+XML, handles shared strings, formula results, dates (via `styles.xml` numFmtId). Max file size 10 MB. |
| `expr` | `expr.zig` | Expression evaluator. Recursive-descent parser → evaluator. Per-row `Context` holds field values, ticker map, lookup table. `eval()` returns `Value` (number/string/bool); `evalString()` coerces to string. |
| `config` | `config.zig` | Reads `bxp-cli.json` via `json5.zig` preprocessor then `std.json`. Returns `Config` owning all heap memory. `BrokerConfig.validate()` checks semantic constraints. |
| `json` | `json.zig` | Reads a JSON array-of-objects into a flat row representation. Builds a union of all keys across all objects; fills missing keys with empty string. |
| `json5` | `json5.zig` | Single-pass tokenizer that converts JSON5 → standard JSON. Strips comments, converts unquoted keys, removes trailing commas, normalizes single-quoted strings. |

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
- `SectionStats` - accumulates warning/error counts across templates.

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
    number: f64,
    string: []const u8,
    boolean: bool,
};

pub const Context = struct {
    fields: []const []const u8,                 // raw CSV field values for current row
    col_index: std.StringHashMap(usize),        // header name → field index
    ticker_map: std.StringHashMap([]const u8),
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

| Allocator | Lifetime | Owns |
| -- | -- | -- |
| `file_alloc` (ArenaAllocator) | Reset after each input file | File content, parsed rows, expression results |
| `line_alloc` (ArenaAllocator) | Reset after each row | Per-row expression evaluation scratch space |

The root GPA (`std.heap.DebugAllocator`) catches leaks in debug builds.

---

### Adding a new conversion template

No code changes required. Add an entry to `bxp-cli.json`:

```json
"broker_to_tracker": {
  "data_dir": "../data/broker_to_tracker",
  "file_pattern_in": ".csv",
  "ticker_map": {},
  "input_schema": {
    "$date":      "DATE_CONVERT([Date], 'DD/MM/YYYY', 'YYYY-MM-DD')",
    "$ticker":    "TICKER([Symbol])",
    "$quantity":  "[Quantity]",
    "$unitprice": "PRICE_VALUE([Price])",
    "$currency":  "PRICE_CURRENCY([Price])",
    "$fee":       "[Fee]",
    "$amount":    "[Total]"
  },
  "row_rules_debug_missing": true,                  // false if all rows handled
  "row_rules": [
    { "when": "[Type] = 'buy'",  "rows": [ { "$action": "'BUY'" } ] },
    { "when": "[Type] = 'sell'", "rows": [ { "$action": "'SELL'" } ] },
    { "when": "1",               "rows": [] }       // skip everything else
  ],
  "output_schema": {
    "date":         "$date",
    "symbol":       "$ticker",
    "quantity":     "$quantity",
    "activityType": "$action",
    "unitPrice":    "$unitprice",
    "currency":     "$currency",
    "fee":          "$fee",
    "amount":       "$amount"
  }
}
```

**Tips:**

- Start with `"row_rules_debug_missing": true` and run with `--debug` to see which rows are not matched by any rule.
- Use `[ColumnName]` to reference raw CSV columns by header name.
- Use `PRICE_VALUE` / `PRICE_CURRENCY` for columns like `"24.00 CZK"` or `"$100.50"`.
- `pre_pass` is needed when values from one row are needed in another (e.g. AnyCoin pairs a `trade payment` row with a `trade fill` row via `Order ID`).

---

### Adding a new built-in function

1. **Define the function** in `bxp-core/src/expr.zig`:
   - Find the `evalFunc()` helper (called from the parser when a function name is recognized).
   - Add a new `if (std.mem.eql(u8, name, "MY_FUNC")) { ... }` branch.
   - Functions receive already-evaluated `Value` arguments.
   - Return a `Value` or propagate an error.

2. **Document it** in the expression reference table in `bxp-cli/CLAUDE.md` (and `resources/readme.md` if user-facing).

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

### Testing

```bash
# run test
./scripts/test.sh

# background process
├── bxp-core unit tests  (zig build test in bxp-core)
│   ├── csv.zig   - all test cases
│   ├── expr.zig  - all test cases
│   └── json5.zig - all test cases
└── bxp-cli regression tests
    └── datasets/<id>/  - diff output vs sample.expected

# ... output ...
Running unit tests (bxp-core)...

Building bxp-cli...

  [anycoin_to_wealthfolio]                         PASS
  [revolutx_to_wealthfolio]                        PASS
  [trading212_to_wealthfolio]                      PASS
  [xtb1_cash_to_wealthfolio]                       PASS
  [xtb1_closed_to_wealthfolio]                     PASS
  [xtb2_cash_to_wealthfolio]                       PASS
  [xtb2_closed_to_wealthfolio]                     PASS

Results: 7 passed, 0 failed
All tests passed.

```

**Adding a regression test:**  
Place `sample.csv` (or `.xlsx`) + `sample.expected` + `sample.json` in `datasets/<template_id>/`. \
The test script picks them up automatically.

**Anonymizing test data:**  
Before committing `.csv` or `.xlsx` files in `datasets/`, strip real account or confidential informations .

---

### Release process

```bash
# run release
./scripts/release.sh
```

The release script cross-compiles `bxp-cli` for selected targets:

| Target | Output |
| -- | -- |
| `x86_64-linux-gnu` | `bxp-cli-linux-x86_64` |
| `aarch64-macos` | `bxp-cli-macos-aarch64` |
| `x86_64-windows` | `bxp-cli-windows-x86_64.exe` |

Outputs are placed in releases/.
