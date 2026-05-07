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
  - [bxp-fmt internals](#bxp-fmt-internals)
  - [Two-pass processing pipeline](#two-pass-processing-pipeline)
  - [Expression evaluator (expr.zig)](#expression-evaluator-exprzig)
  - [Configuration system (config.zig + json5.zig)](#configuration-system-configzig--json5zig)
  - [Memory model](#memory-model)
  - [Error handling philosophy](#error-handling-philosophy)
  - [Debugging workflow](#debugging-workflow)
  - [Adding a new conversion template](#adding-a-new-conversion-template)
  - [Adding a new built-in function](#adding-a-new-built-in-function)
  - [Testing](#testing)
  - [Release process](#release-process)
  - [GUI development](#gui-development)
  - [Where to dig deeper (CLAUDE.md map)](#where-to-dig-deeper-claudemd-map)

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
The monorepo ships `CLAUDE.md` files at four levels — root, `bxp-cli/`, `bxp-core/`,
`bxp-fmt/`, and `bxp-gui/` — Claude loads these automatically and reads project conventions.

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
├── bxp-fmt/                    # developer utility binary (used by bxp-gui and scripts)
│   ├── src/
│   │   └── main.zig            # --config / --expr / --expr-trace / --docs /
│   │                           # --list-templates / --fetch-template
│   ├── build.zig
│   └── build.zig.zon           # depends on bxp-core (path dep)
├── bxp-core/                   # internal shared library (no binary)
│   ├── src/
│   │   ├── csv.zig             # RFC 4180 CSV parser
│   │   ├── xlsx.zig            # .xlsx → CSV (ZIP+XML)
│   │   ├── expr.zig            # expression evaluator + FnDoc catalog
│   │   ├── config.zig          # JSON5 config loader + FieldDoc tables
│   │   ├── json.zig            # JSON array-of-objects → row representation
│   │   ├── json5.zig           # JSON5 preprocessor (comments, unquoted keys, ...)
│   │   ├── docs.zig            # --docs aggregator: re-exports expr + config catalogs
│   │   └── diagnostics.zig     # structured validation collector (Severity, Diagnostic)
│   ├── build.zig               # exports named Zig modules
│   └── build.zig.zon           # depends on sunrise (url dep, auto-fetched)
├── bxp-gui/                    # Flutter desktop app (Linux / macOS / Windows)
│   ├── lib/
│   │   ├── main.dart           # Flutter entry; window + theme + provider wiring
│   │   ├── services/           # subprocess wrappers, AST loader, prefs, updater
│   │   ├── store/              # TraceStore ChangeNotifier + trace data models
│   │   └── ui/                 # widgets: tree editor, expr panel, row debugger, …
│   ├── packages/json5_ast/     # standalone Dart JSON5 AST library (path dep)
│   ├── linux/, macos/, windows/ # per-platform Flutter shells
│   └── pubspec.yaml
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
│   └── trace-protokol.md       # bxp-cli --trace NDJSON protocol spec
├── resources/
│   ├── console/                # bxp-cli sample config + readme (bundled in console archives)
│   └── desktop/                # bxp-gui.desktop template + readme (bundled in desktop archives)
├── scripts/
│   ├── test.sh                 # wrapper: test-01-console.sh + test-02-desktop.sh
│   ├── test-01-console.sh      # bxp-core unit + bxp-fmt smoke + bxp-cli regression
│   ├── test-02-desktop.sh      # flutter analyze + flutter test + json5_ast dart test
│   ├── release.sh              # wrapper: release-01-console.sh + release-02-desktop.sh
│   ├── release-01-console.sh   # cross-compile bxp-cli → bxp-console-* archives
│   ├── release-02-desktop.sh   # Flutter bundle → AppImage / .deb / .exe / .dmg
│   ├── release-03-checksums.sh # emit SHA256SUMS for all release artifacts
│   ├── release-changelog.sh    # generate CHANGELOG entry for a release
│   └── release-tag.sh          # bump versions + create + push git tag
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
  bxp-fmt  ── path dep ──►  bxp-core
  (binary)

  bxp-gui  ── subprocess ──►  bxp-cli  (conversions, --trace stream)
  (Flutter)  └─ subprocess ──►  bxp-fmt  (--config, --docs, --expr, --expr-trace)
```

`bxp-core` is a **local path dependency** (`../bxp-core`) — no network fetch
needed. `sunrise` is a URL dependency fetched automatically by `zig build` on
first run. `bxp-gui` ships both `bxp-cli` and `bxp-fmt` inside the Flutter
bundle and invokes them via `Process.run`.

---

### bxp-core modules

| Module | File | Responsibility |
| -- | -- | -- |
| `csv` | `csv.zig` | RFC 4180 parser. `splitRecords()` slices raw content; `splitFields()` unquotes fields. Spaces preserved — trimmed outside csv.zig at access time in `expr.Context`. |
| `xlsx` | `xlsx.zig` | Converts `.xlsx` to intermediate `.csv`. Reads ZIP+XML, handles shared strings, formula results, dates (via `styles.xml` numFmtId). Max file size 10 MB. |
| `expr` | `expr.zig` | Expression evaluator. Recursive-descent parser → evaluator. Per-row `Context` holds field values, ticker map, lookup table. `eval()` returns `Value` (number/string/bool); `evalString()` coerces to string. Each built-in has a co-located `FnDoc` entry consumed by `docs.zig`. |
| `config` | `config.zig` | Reads `bxp-cli.json` via `json5.zig` preprocessor then `std.json`. Returns `Config` owning all heap memory. `BrokerConfig.validate()` checks semantic constraints. Each struct has a co-located `FieldDoc` table consumed by `docs.zig`. |
| `json` | `json.zig` | Reads a JSON array-of-objects into a flat row representation. Builds a union of all keys across all objects; fills missing keys with empty string. |
| `json5` | `json5.zig` | Single-pass tokenizer that converts JSON5 → standard JSON. Strips comments, converts unquoted keys, removes trailing commas, normalizes single-quoted strings. |
| `docs` | `docs.zig` | Aggregates `expr.zig` FnDoc catalog and `config.zig` FieldDoc tables into the `bxp-fmt --docs` JSON. Single source of truth consumed by bxp-gui at startup. |
| `diagnostics` | `diagnostics.zig` | Structured validation collector. `Severity` (.error / .warning / .info), `Diagnostic` (path, position, code, message, suggest), `Diagnostics` (ArrayList collector). Used by bxp-fmt deep validation; bxp-cli passes a null sink. |

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

### bxp-fmt internals

`bxp-fmt` is a small developer-utility binary sibling to `bxp-cli`. It holds
everything that isn't "run a conversion": config validation, expression
evaluation, schema/docs emission, template lookup. Consumed by `bxp-gui` (via
`Process.run`) and by `scripts/test.sh`.

The binary is intentionally a thin shim — every subcommand delegates to a
`bxp-core` module. bxp-fmt's own job is arg parsing, arena setup, and JSON
serialization.

| Subcommand | Backed by | Purpose |
| -- | -- | -- |
| `--config <path>` | `config.load` + `config.validateCollect` | Annotated JSON output with `$comm_<N>` / `$err_<N>` / `$warn_<N>` / `$info_<N>` siblings |
| `--config <path> --list-templates` | `config.load` | JSON array of template ids |
| `--config <path> --fetch-template <id>` | `config.load` | Raw JSON5 block of one template |
| `--expr '<text>'` | `expr.eval` (empty `Context`) | One-shot expression validation |
| `--expr-trace '<text>' [--row-headers …] [--row-fields …]` | `expr.evalTrace` | Per-call NDJSON trace stream (used by ExprPlayground) |
| `--docs` | `docs.writeDocs` | Full FnDoc / FieldDoc catalog (single source for bxp-gui startup) |
| `--version`, `--help` | — | Standard. `--version` writes to stdout, not stderr |

Subcommands are mutually exclusive (one action per invocation). Each `runX`
function wraps the input GPA in an `ArenaAllocator` — `expr.Context.alloc`
doesn't garbage-collect, so a raw GPA leaks per call.

Adding a subcommand: write a new `runX` in `bxp-fmt/src/main.zig`, dispatch
from arg parsing, delegate the real work to a `bxp-core` module. No new
business logic should land here.

Deeper detail: [`bxp-fmt/CLAUDE.md`](../bxp-fmt/CLAUDE.md).

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

### Error handling philosophy

Three concerns, three mechanisms:

**1. Exit codes (CLI contract).** `bxp-cli`:

| Code | Meaning |
| -- | -- |
| `0` | Success |
| `1` | Fatal error (invalid config, file not found, broken expression at load) |
| `2` | Warnings (typo'd field, unknown column, no input rows) |

Exit `2` runs to completion — the user gets converted output AND a warning
text on stderr. CI scripts treat `2` as failure (see "datasets are exemplary"
convention).

**2. Diagnostics (deep validation).** `bxp-core/diagnostics.zig` defines a
structured collector consumed by `bxp-fmt --config`:

```text
Severity   ∈ { .error, .warning, .info }
Diagnostic = { path, off?, len?, severity, code, message, suggest? }
```

`config.zig`, `json5.zig`, and `expr.zig` accept an optional `*Diagnostics`
sink — `bxp-cli` passes `null` (fail-fast / stderr behaviour preserved),
`bxp-fmt` passes a real bag and renders findings as `$err_<N>` / `$warn_<N>` /
`$info_<N>` siblings in the annotated JSON output. The GUI reads those keys
to decorate the tree with inline error markers.

**3. User-facing messages.** Use `std.process.exit(1)` for fatal CLI
errors — no Zig stack trace leaks to the user. Severity routing in `--trace`
mode: `Output.warning()` writes to stderr (stdout is reserved for NDJSON);
fatal errors also stderr.

---

### Debugging workflow

**bxp-cli verbosity flags** — composable, all on the same binary:

| Flag | What it does |
| -- | -- |
| `--debug` | Prints unmatched rows when `row_rules_debug_missing: true` |
| `--quiet` | Suppresses per-template summaries (exit code still reflects result) |
| `--trace` | Emits NDJSON event stream on stdout (consumed by `bxp-gui`'s dry-run debugger). Implies `--quiet` |
| `--check-fs=N` | Adds filesystem-existence checks (templates' `data_dir`, etc.) with N-second timeout |

**Inspecting an expression in isolation:**

```bash
# Validate syntax only (no row context)
./zig-out/bin/bxp-fmt --expr "IF([Qty] > 0, 'BUY', 'SELL')"

# Trace per-call values against a fake row
./zig-out/bin/bxp-fmt --expr-trace "[Price] * [Qty]" \
    --row-headers '["Price","Qty"]' \
    --row-fields  '["12.50","100"]'
```

**bxp-gui live debug (Claude Code MCP loop):** see [`gui.md`](gui.md#debugging-with-print)
for the `mcp__dart__launch_app` → `hot_reload` → `get_app_logs` cycle. Quick
tip: `print()` from Dart is captured; `developer.log()` is not.

**Settings inspector (Ctrl+Shift+S in bxp-gui):** opens an internal-state
drawer showing the loaded config, parsed AST, schema docs, op log, and
validation errors. The fastest way to confirm "is the GUI seeing what I
think it's seeing?".

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

### Testing

```bash
# run test
./scripts/test.sh
```

`test.sh` runs two sub-scripts in sequence:

**`test-01-console.sh`** — Zig / CLI side:

1. `zig build test` in `bxp-core` (unit tests for `csv.zig`, `expr.zig`, `json5.zig`, `docs.zig`).
2. Builds `bxp-fmt`; runs smoke tests for each subcommand (`--config`, `--expr`, `--docs`, `--list-templates`, `--fetch-template`).
3. Builds `bxp-cli`; iterates every `datasets/<id>/` directory and diffs output against `sample.expected`.

**`test-02-desktop.sh`** — Flutter / Dart side:

1. `flutter analyze` — static analysis of `bxp-gui/`.
2. `flutter test` — widget tests in `bxp-gui/test/`.
3. `dart test` inside `bxp-gui/packages/json5_ast/` — json5_ast unit + round-trip tests.

Individual sub-suites:

```bash
cd bxp-core && zig build test           # Zig unit tests only
bash scripts/test-01-console.sh        # console side only (no Flutter dep)
bash scripts/test-02-desktop.sh        # Flutter side only
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

| Channel | Archives | Content |
| -- | -- | -- |
| `bxp-console` | `bxp-console-<ver>-{linux-x86_64.tar.gz, macos-aarch64.tar.gz, windows-x86_64.zip}` | CLI binary only |
| `bxp-desktop` | `bxp-desktop-<ver>-{linux.AppImage, linux.deb, linux.tar.gz, windows-setup.exe, macos.dmg}` | Flutter GUI + bundled bxp-cli + bxp-fmt |

```bash
# Bump versions + tag + push (triggers GitHub Actions pipeline)
bash scripts/release-tag.sh v0.3.0

# Or build locally without tagging:
bash scripts/release-01-console.sh v0.3.0-rc1   # console archives
bash scripts/release-02-desktop.sh v0.3.0-rc1   # host-OS desktop bundle
```

The GitHub Actions pipeline fans out across ubuntu / windows / macos runners so
all native installers come from real native builds.

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

| Module | File | What's in it |
| -- | -- | -- |
| Monorepo | [`CLAUDE.md`](../CLAUDE.md) | Top-level layout + package dep graph + cross-cutting conventions |
| `bxp-cli` | [`bxp-cli/CLAUDE.md`](../bxp-cli/CLAUDE.md) | Full config reference, expression syntax, broker list, exit codes, output stream routing |
| `bxp-fmt` | [`bxp-fmt/CLAUDE.md`](../bxp-fmt/CLAUDE.md) | Subcommands, annotated JSON shape (`$comm_*`/`$err_*`/…), exit codes |
| `bxp-core` | [`bxp-core/CLAUDE.md`](../bxp-core/CLAUDE.md) | Per-module API surface, build details, "known non-issues" rationale |
| `bxp-gui` | [`bxp-gui/CLAUDE.md`](../bxp-gui/CLAUDE.md) | Flutter app structure, services/store/ui split, MCP debug workflow |
| `json5_ast` | [`bxp-gui/packages/json5_ast/CLAUDE.md`](../bxp-gui/packages/json5_ast/CLAUDE.md) | Standalone-library-candidate status, comment ownership, future extraction recipe |
