# BXP Subprocess Protocol Reference

> [← docs/](README.md)

Machine-readable output formats emitted by **bxp-cli** (the binary BXTB trace)
and the stateless **inspect** core (config / expression / docs / template JSON,
surfaced through bxp-mcp + the bxp-gui-bridge FFI). Consumed by bxp-gui (via the
bridge) and by `scripts/test.sh`.

- [bxp-cli --trace](#bxp-cli---trace)
  - [Wire format](#wire-format)
  - [Frame reference](#frame-reference)
  - [Ordering guarantees](#ordering-guarantees)
  - [Drill-down model](#drill-down-model)
  - [Versioning policy](#versioning-policy)
- [Stateless inspect formats](#stateless-inspect-formats)
  - [--expr](#--expr)
  - [--expr-trace](#--expr-trace)
  - [--config](#--config)
  - [--docs](#--docs)
- [Producer / Consumer](#producer--consumer)

---

## bxp-cli --trace

Invoked as `bxp-cli --trace [--config ...] [--template ...]`. Writes a binary
**BXTB** frame stream to **stdout**; everything else goes to **stderr**.
`--trace=bin` is an explicit alias; any other `--trace=<x>` argument is a usage
error (the legacy `--trace=json` NDJSON path was removed in v0.3.0).

The optional `--trace-file <path>` flag mirrors the same byte stream to a file
on disk, so a run can simultaneously drive a downstream consumer on stdout
and persist the stream for offline inspection.

### Wire format

The stream begins with a 4-byte little-endian magic `0x42545842` (ASCII
`BXTB`) and is followed by a sequence of frames. There is **no schema-version
field** — bxp-cli and bxp-gui ship together in every release and the magic is
the only handshake.

Each frame has a fixed 7-byte header followed by a type-specific payload:

```text
┌────────────┬────────────┬─────────────────────────────────────────┐
│  byte 0    │  1..2 LE   │  3..6 LE                                │
├────────────┼────────────┼─────────────────────────────────────────┤
│  type:u8   │  chunk:u16 │  pay_len:u32     payload (pay_len B)    │
└────────────┴────────────┴─────────────────────────────────────────┘
```

- `type` — frame kind. Unknown types are silently skipped via `pay_len`
  (forward compat).
- `chunk_id` — reserved for future multicore frame dispatch; producers emit
  `0` today.
- `pay_len` — payload byte count following the header.

Variable-length strings inside payloads are length-prefixed (lp): `u32 len`
little-endian followed by `len` bytes. All multi-byte integers are
little-endian. There are no padding bytes between fields.

Non-frame diagnostics (panics, usage errors, human progress lines) go to
**stderr**. Mixing with stdout is never allowed — `--trace` implies `--quiet`
so summaries never appear on the frame stream.

The authoritative protocol definition lives in
[`bxp-core/src/btrace.zig`](../bxp-core/src/btrace.zig); this section
documents the same shape for consumers that don't link the Zig writer.

### Frame reference

Seven frame types are defined today:

| Code   | Name            | Purpose                                                                 |
| ------ | --------------- | ----------------------------------------------------------------------- |
| `0x01` | `file_start`    | Begin one input file (template + path + headers).                       |
| `0x02` | `file_end`      | Close one input file (per-file counters).                               |
| `0x03` | `output_row`    | One output row written to the `.csvx`. Carries the source-row locator.  |
| `0x04` | `filtered_row`  | Source row skipped silently (no `output_row`, no `error_row`).          |
| `0x05` | `error_row`     | Expression evaluation error against a source row.                       |
| `0x06` | `prepass_entry` | One entry accumulated during the optional pre-pass over the input file. |
| `0x07` | `done`          | Final frame. Carries the process exit code.                             |

Frames carry **metadata only**: per-output-row pointers into the source CSV
(`source_locator` byte offset), error list, pre_pass dump, aggregate stats.
Per-row drill-down (variable values, rule evaluation traces, output cells) is
**not** in the stream — see [Drill-down model](#drill-down-model).

#### `0x01 file_start`

```text
input_format:u8       # 0 = csv, 1 = json, 2 = xlsx_intermediate_csv
template:lp_string
path:lp_string
headers_count:u16
headers:lp_string × headers_count
```

The `input_format` enum lets a consumer pick the right re-read strategy for
drill-down: CSV reads via `source_locator` byte offset, JSON re-parses
materialised, xlsx is read as the intermediate CSV exported during processing.

#### `0x02 file_end`

```text
source_rows:u64
written_rows:u64
errors:u32           # input_schema expression failures
warnings:u32         # non-fatal per-file issues
```

#### `0x03 output_row`

```text
source_locator:u64   # byte offset into the source file for re-read
output_idx:u64       # 1-based output row index within this file
rule_idx:i32         # which row_rules entry produced this output (0-based)
action:lp_string     # $action value, retained for at-a-glance display
```

#### `0x04 filtered_row`

```text
source_locator:u64
reason:lp_string     # e.g. "date_filter_from_filename"
```

#### `0x05 error_row`

```text
source_locator:u64
var_name:lp_string
error_kind:lp_string
detail:lp_string
origin:lp_string     # "input_schema" | "rule_override" | "pre_pass" | …
```

#### `0x06 prepass_entry`

```text
name:lp_string       # pre_pass block name ("_default" for legacy single-block)
key:lp_string
field:lp_string
value:lp_string
```

#### `0x07 done`

```text
exit_code:i32
```

| Exit code | Meaning                                                  |
| --------- | -------------------------------------------------------- |
| `0`       | OK.                                                      |
| `1`       | Fatal error (config load, unrecoverable pipeline error). |
| `2`       | Warnings present (e.g. empty input files).               |

### Ordering guarantees

For any file, frames appear in this order:

```text
file_start
prepass_entry*                                (may be zero)
( output_row | filtered_row | error_row )*    (one per source row, or many
                                               for 1:N templates that emit
                                               multiple outputs per source row)
file_end
```

`error_row` for a given `source_locator` MAY precede the matching `output_row`
or `filtered_row` — bxp-cli evaluates `input_schema` (which can fail) before
running `row_rules`, so the error frame is emitted as soon as the failure is
known. Consumers should drain pending `error_row`s onto the row when its
output / filtered frame arrives.

Across files, `file_start` / `file_end` pairs are emitted in
`conversion_templates` order; a `file_end` always precedes the next
`file_start`. The stream is closed by exactly one `done` frame. A missing
`done` means the process crashed; consumers should treat stderr as
authoritative in that case.

### Drill-down model

The frame stream is deliberately **metadata-only**. Each `output_row` and
`error_row` carries a `source_locator` (byte offset into the source CSV) but
**no** per-row variable bindings, rule evaluation trace, or output cell values.
For files emitted via the xlsx path, the locator points into the intermediate
CSV materialised during xlsx → CSV conversion.

When the GUI needs that detail (user clicks one row in the drill-down panel),
it:

1. Seeks the source CSV to `source_locator` and reads one record.
2. Calls the bridge's `eval_batch` op (in-process; the same shape the former
   `bxp-fmt --expr-batch` produced) with the row fields + the current config's
   `input_schema` and `row_rules` to recompute variable values, rule matches,
   and output cells.

This shifts the per-row eval cost from the trace producer to on-demand
consumption. Effects:

- Trace bytes shrink from O(rows × variables × bytes-per-trace-event) to
  O(rows × small header) — roughly two orders of magnitude on real
  workloads.
- Drill-down latency stays low for clicked rows (one re-eval ≈ 50 ms) and is
  paid only for rows the user actually opens.
- The current config is the source of truth at click time — drill-down
  reflects edits made after the trace was produced.

### Versioning policy

There is no in-band schema version. bxp-cli and bxp-gui are built and
released together from the same monorepo; a mismatched producer/consumer
pair is a build error, not a runtime concern.

Forward compatibility within one release line is provided by `pay_len`:
unknown frame types are skipped, and the frame layout uses fixed offsets
plus length-prefixed strings so adding optional payload fields requires a
new frame type (or a new release).

---

## Stateless inspect formats

These are the JSON output shapes of the stateless inspection core
(`bxp-core/src/inspect.zig`): config annotation, single-expression validation
and evaluation, expr-trace, template list/fetch, and the docs catalog. The
shapes are transport-agnostic — they reach callers through the **bxp-mcp** tools
(the agent surface, mapped per subsection below) and the **bxp-gui-bridge** FFI
(in-process for the Dart GUI). The bash snippets below are illustrative of each
shape; the now-removed `bxp-fmt` CLI emitted the same bytes on stdout/stderr.

Each subsection notes the bxp-mcp tool that produces the shape today:

| Shape (below)     | bxp-mcp tool         | bridge op                  |
| ----------------- | -------------------- | -------------------------- |
| `--expr`          | `bxp_validate_expr`  | `bridge_eval_expr`         |
| `--expr-trace`    | `bxp_eval_trace`     | `bridge_eval_expr_trace`   |
| `--config`        | `bxp_validate`       | `bridge_inspect {config}`  |
| `--list-templates`| `bxp_list_templates` | `bridge_inspect {list_templates}` |
| `--fetch-template`| `bxp_fetch_template` | `bridge_inspect {fetch_template}` |
| `--docs`          | `bxp_docs`           | `bridge_inspect {docs}`    |

### --expr

Validates a single expression against an empty row context (no column refs, no
lookups). Used by bxp-gui's ExprPanel for live per-edit validation.

```bash
bxp-fmt --expr 'ABS(-1)'
```

**Success:** stdout empty, exit 0.

**Error:** JSON object on **stderr**, exit 1:

```jsonc
{ "error": "NotANumber", "detail": "(pos 4)", "off": 0, "len": 7 }
```

| Field    | Type     | Notes                                                                                                    |
| -------- | -------- | -------------------------------------------------------------------------------------------------------- |
| `error`  | `string` | Zig error name.                                                                                          |
| `detail` | `string` | Human-readable position hint.                                                                            |
| `off`    | `u32`    | Byte offset of the offending token in the expression source. Present only when the parser pinned a span. |
| `len`    | `u32`    | Byte length of the offending token. Present only when `off` is present.                                  |

Column references (`[ColumnName]`) always fail in `--expr` mode because there
is no row context; use `--expr-trace --row-headers/--row-fields` for reference
resolution.

### --expr-trace

Evaluates an expression with per-function-call trace output and optional fake
row context. Used by bxp-gui's expression playground (Variables panel).

```bash
bxp-fmt --expr-trace 'ABS([Price])' \
  --row-headers '["Date","Price"]' \
  --row-fields  '["2026-04-01","150.00"]'
```

One NDJSON line per builtin call emitted to **stdout** (emitted before the
sentinel — partial trace survives a mid-expression error):

```jsonc
{ "fn": "ABS", "src_start": 4, "src_end": 15, "value": "150" }
```

| Field       | Type     | Notes                                                                        |
| ----------- | -------- | ---------------------------------------------------------------------------- |
| `fn`        | `string` | Built-in function name (e.g. `ABS`, `DATE_CONVERT`).                         |
| `src_start` | `usize`  | Byte offset of the function name in the expression source.                   |
| `src_end`   | `usize`  | Byte offset just past the closing `)`.                                       |
| `value`     | `string` | Return value coerced to string. Numbers formatted as decimal (`150`, `1.5`). |

**Sentinel lines** — always the last line on their respective stream:

| Outcome | Stream | Shape                                                                            |
| ------- | ------ | -------------------------------------------------------------------------------- |
| Success | stdout | `{"t": "final", "value": "150"}`                                                 |
| Error   | stderr | `{"t": "error", "error": "NotANumber", "detail": "(pos 4)", "off": 0, "len": 7}` |

The error sentinel carries the same optional `off`/`len` fields as `--expr`.

**Row context flags** — both required together or omitted together:

| Flag            | Type                   | Notes                                                             |
| --------------- | ---------------------- | ----------------------------------------------------------------- |
| `--row-headers` | JSON array of `string` | Column names matching the CSV header row.                         |
| `--row-fields`  | JSON array of `string` | Field values for the current row; same length as `--row-headers`. |

Mismatched lengths → exit 2 (usage error).

### --config

Validates a config file and emits it back as **annotated JSON** — standard JSON
with reserved `$`-prefixed sibling keys that carry preserved comments and
diagnostics. Used by bxp-gui's `loadConfig()` and the VALIDATE button.

```bash
bxp-fmt --config bxp-cli.json [--check-fs=N]
```

`--check-fs=N` runs the filesystem existence check (data directories, input
file patterns) with an `N`-second timeout per template. Omitted or `0` skips
the check.

**Output:** annotated JSON to **stdout**, exit 0 on success or exit 1 when any
`$err_*` is present.

#### Annotated JSON keys

All `$`-prefixed keys share a single monotonically-increasing counter `<N>` so
every sibling key is unique. Each finding is inserted immediately before the
offending key in its parent object; appended at the end when the offending key
is absent (e.g. a missing required field).

| Key prefix  | Shape                                                                          | Meaning                  |
| ----------- | ------------------------------------------------------------------------------ | ------------------------ |
| `$comm_<N>` | `{ "text": "...", "placement": "leading"\|"trailing"\|"block"\|"standalone" }` | Preserved JSON5 comment. |
| `$err_<N>`  | `{ "message": "...", "off"?: N, "len"?: N, "suggest"?: "..." }`                | Validation error.        |
| `$warn_<N>` | same shape as `$err_<N>`                                                       | Non-fatal warning.       |
| `$info_<N>` | same shape as `$err_<N>`                                                       | Informational finding.   |

`off`, `len`, and `suggest` are omitted when the diagnostic has no source span
or did-you-mean hint. `off`/`len` are byte offsets into the expression source
string of the offending token (from Phase G1).

`placement` values for `$comm_<N>`:

| Value        | Meaning                                                  |
| ------------ | -------------------------------------------------------- |
| `leading`    | Comment on its own line immediately before the next key. |
| `trailing`   | Inline comment on the same line as the preceding value.  |
| `block`      | `/* ... */` block comment.                               |
| `standalone` | Block comment at the end of an object (before `}`).      |

The runtime config loader (`bxp-cli`) uses `json5.preprocess` (non-annotated
variant), so `$comm_<N>` / `$err_<N>` keys never reach the conversion pipeline.

#### --list-templates modifier

```bash
bxp-fmt --config bxp-cli.json --list-templates
```

Emits a JSON array of template ids to **stdout**, exit 0. No semantic
validation — reports whatever keys appear under `conversion_templates`, even if
a template body is malformed.

```jsonc
["xtb2_cash", "revolut_stocks", "anycoin"]
```

#### --fetch-template modifier

```bash
bxp-fmt --config bxp-cli.json --fetch-template xtb2_cash
```

Emits the raw JSON5 block for one template as a JSON string to **stdout**, exit 0. Exit 1 if the template id is not found.

### --docs

Emits the full language + schema documentation catalog as pretty-printed JSON
to **stdout**, exit 0. Single source of truth consumed by bxp-gui at startup.

```bash
bxp-fmt --docs
```

#### Top-level structure

```jsonc
{
  "functions":     [...],
  "keywords":      [...],
  "operators":     [...],
  "tokens":        [...],
  "config_schema": [...]
}
```

#### `functions` entry

```jsonc
{
  "name": "ABS",
  "signature": "ABS(value)",
  "description": "Absolute value of a number.",
  "args": [{ "name": "value", "kind": "expr" }],
  "min_args": 1,
  "max_args": 1,
}
```

`args[].kind` values: `expr` (any expression) | `string` (any string-typed
expression) | `literal_string` (bare string literal) | `number` (any
numeric-typed expression) | `positive_integer` (positive integer literal, ≥ 1) |
`integer_in_range` (integer literal within a builtin-specific range) |
`date_format` (datefmt date-format pattern) | `pre_pass_name` (name of a
declared `pre_pass` block).

#### `keywords` entry

```jsonc
{ "name": "true", "description": "Boolean literal true." }
```

#### `operators` entry

```jsonc
{ "token": "+", "description": "Addition or string concatenation." }
```

#### `tokens` entry

```jsonc
{
  "kind": "field_ref",
  "syntax": "[ColName]",
  "description": "Reference a CSV column by name.",
}
```

#### `config_schema` entry

Flat array ordered by schema declaration (envelope entries first, then
per-struct fields in definition order — used by the GUI's insert-position
logic). Each entry describes one config tree path.

```jsonc
{
  "key":             "conversion_templates.*.data_dir",
  "type_name":       "string",
  "required":        true,
  "default":         null,
  "description":     "Directory scanned for input files ...",
  "enum_values":     null,
  "ordered":         false,
  "insert_order":    "schema",
  "insert_template": { ... },
  "validator":       "none",
  "autocomplete":    "none"
}
```

| Field             | Notes                                                                                 |
| ----------------- | ------------------------------------------------------------------------------------- |
| `key`             | Dotted path. `*` means "any map key at this level".                                   |
| `type_name`       | Zig-style type hint (`string`, `bool`, `?string`, ...).                               |
| `required`        | Whether the field must be present.                                                    |
| `default`         | Default value as a JSON scalar, or `null`.                                            |
| `enum_values`     | Array of allowed string values, or `null`.                                            |
| `ordered`         | `true` when key insertion order is significant (e.g. `row_rules`).                    |
| `insert_order`    | GUI add-child hint: `"schema"` (FieldDoc order) \| `"append"` \| `"alpha"` \| `null`. |
| `insert_template` | Default value JSON pre-filled when inserting a new entry, or `null`.                  |
| `validator`       | Static validator tag used by the Dart-side `DartValidator`.                           |
| `autocomplete`    | Autocomplete hint for the GUI expression editor.                                      |

---

## Producer / Consumer

| Binary     | Role                                 | Source file                                                                                                        |
| ---------- | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| `bxp-cli`  | Produces `--trace` BXTB frame stream | [`bxp-cli/src/pipeline.zig`](../bxp-cli/src/pipeline.zig) — `Output.binEmit*()`                                    |
| `bxp-core` | BXTB writer / reader                 | [`bxp-core/src/btrace.zig`](../bxp-core/src/btrace.zig)                                                            |
| `bxp-core` | All stateless inspect outputs        | [`bxp-core/src/inspect.zig`](../bxp-core/src/inspect.zig)                                                          |
| `bxp-mcp`  | MCP wrappers over inspect            | [`bxp-mcp/src/tools.zig`](../bxp-mcp/src/tools.zig)                                                                |
| `bxp-gui-bridge` | FFI wrappers over inspect      | [`bxp-gui-bridge/src/main.zig`](../bxp-gui-bridge/src/main.zig)                                                    |
| `bxp-core` | Per-call trace in `--expr-trace`     | [`bxp-core/src/expr.zig`](../bxp-core/src/expr.zig) — `emitCallTrace()`                                            |
| `bxp-core` | `--docs` catalog                     | [`bxp-core/src/docs.zig`](../bxp-core/src/docs.zig) — `writeDocs()`                                                |
| `bxp-gui`  | Consumes `--trace`                   | [`bxp-gui/lib/store/trace_store.dart`](../bxp-gui/lib/store/trace_store.dart) — `_streamRunBtrace`                 |
| `bxp-gui`  | Consumes `--expr-trace`              | [`bxp-gui/lib/services/bxp_process_client.dart`](../bxp-gui/lib/services/bxp_process_client.dart) — `traceExpr()`  |
| `bxp-gui`  | Consumes `--config`                  | [`bxp-gui/lib/services/bxp_process_client.dart`](../bxp-gui/lib/services/bxp_process_client.dart) — `loadConfig()` |
| `bxp-gui`  | Consumes `--docs`                    | [`bxp-gui/lib/store/trace_store.dart`](../bxp-gui/lib/store/trace_store.dart) — `loadDocs()`                       |
| `bxp-gui`  | Event model                          | [`bxp-gui/lib/store/trace_model.dart`](../bxp-gui/lib/store/trace_model.dart)                                      |
