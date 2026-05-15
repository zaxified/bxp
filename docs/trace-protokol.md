# BXP Subprocess Protocol Reference

> [← docs/](README.md)

Machine-readable output formats emitted by **bxp-cli** and **bxp-fmt**.
Consumed by bxp-gui (Dart via subprocess) and by `scripts/test.sh`.

- [bxp-cli --trace](#bxp-cli---trace)
  - [Wire format](#wire-format)
  - [Current version](#current-version)
  - [Event reference](#event-reference)
  - [Ordering guarantees](#ordering-guarantees)
  - [Versioning policy](#versioning-policy)
- [bxp-fmt](#bxp-fmt)
  - [Exit codes](#exit-codes)
  - [--expr](#--expr)
  - [--expr-trace](#--expr-trace)
  - [--config](#--config)
  - [--docs](#--docs)
- [Producer / Consumer](#producer--consumer)

---

## bxp-cli --trace

Invoked as `bxp-cli --trace [--config ...] [--template ...]`. Writes one NDJSON
event per line to **stdout**; everything else goes to **stderr**.

### Wire format

- One JSON object per line on **stdout**, terminated by `\n` (no comma, no
  trailing array).
- Each object has a `"t"` field naming the event kind. Payload fields follow.
- Strings are JSON-escaped by `std.json.Stringify`; consumers must parse with a
  standard JSON reader, not line-split.
- Non-NDJSON diagnostics (panics, usage errors, human progress lines) go to
  **stderr**. Mixing with stdout is never allowed.
- `--trace` implies `--quiet` so human-readable progress messages never pollute
  stdout.

The first event is always `start` and carries `schema_version`. Consumers
should refuse to parse if the version is higher than they know.

### Current version

```text
schema_version = 1
```

### Event reference

#### `start`

Emitted once, before any other event.

```jsonc
{
  "t": "start",
  "schema_version": 1,
  "config": "/path/to/bxp-cli.json",
  "templates": ["xtb2_cash", "revolut_stocks"],
}
```

| Field            | Type            | Notes                                              |
| ---------------- | --------------- | -------------------------------------------------- |
| `schema_version` | `u32`           | Protocol version. Bump on any breaking change.     |
| `config`         | `string`        | Absolute path that bxp-cli loaded the config from. |
| `templates`      | `array<string>` | Templates that will be processed, in order.        |

#### `file_start`

One input file is about to be processed.

```jsonc
{
  "t": "file_start",
  "template": "xtb2_cash",
  "path": "data/xtb/2026.csv",
  "rows": 42,
  "headers": ["Date", "Symbol", "Qty", "Price"],
}
```

| Field      | Type            | Notes                                         |
| ---------- | --------------- | --------------------------------------------- |
| `template` | `string`        | Template id from `conversion_templates`.      |
| `path`     | `string`        | Resolved input path (joined with `data_dir`). |
| `rows`     | `usize`         | Total row count after parsing the input file. |
| `headers`  | `array<string>` | Column headers in file order.                 |

#### `prepass_set`

One lookup entry accumulated during the optional pre-pass over the input file.
Emitted after `file_start` and before any `row_start` for that file.

```jsonc
{ "t": "prepass_set", "key": "AAPL", "field": "isin", "value": "US0378331005" }
```

| Field   | Type     | Notes                                               |
| ------- | -------- | --------------------------------------------------- |
| `key`   | `string` | Composite key (join of `pre_pass.key` evaluations). |
| `field` | `string` | Field name (key in `pre_pass.values`).              |
| `value` | `string` | Value evaluated from `pre_pass.values[field]`.      |

#### `row_start`

Begins a new row. All subsequent `var_eval`, `var_error`, `rule_match`,
`rule_no_match`, `row_filtered`, and `row_output` events belong to this row
until the matching `row_end`.

```jsonc
{
  "t": "row_start",
  "file_row": 3,
  "fields": ["2026-04-01", "AAPL", "10", "150.00"],
}
```

| Field      | Type            | Notes                                              |
| ---------- | --------------- | -------------------------------------------------- |
| `file_row` | `usize`         | 1-based row index in the source file.              |
| `fields`   | `array<string>` | Raw cell values in column order (same as headers). |

#### `var_eval`

A variable from `input_schema` or the rule's `rows[]` evaluated successfully.

```jsonc
{
  "t": "var_eval",
  "name": "$date",
  "expr": "DATE_CONVERT([Date],'YYYY-MM-DD')",
  "value": "2026-04-01",
}
```

#### `var_error`

Variable evaluation failed. The row continues with the variable bound to the
empty string, so subsequent rules may still match.

```jsonc
{
  "t": "var_error",
  "name": "$price",
  "expr": "ROUND([Price])",
  "error": "NotANumber",
  "detail": "(pos 12)",
}
```

| Field    | Type     | Notes                                                    |
| -------- | -------- | -------------------------------------------------------- |
| `name`   | `string` | Variable name (`$...`).                                  |
| `expr`   | `string` | Source expression, for UI display.                       |
| `error`  | `string` | Zig error name (e.g. `NotANumber`, `ParseError`).        |
| `detail` | `string` | Optional position / field hint, e.g. `(line 3, pos 12)`. |

#### `rule_match` / `rule_no_match`

Rule evaluation for the current row. At most one `rule_match` per row (rules
are evaluated top-down, stopping at the first match).

```jsonc
{"t": "rule_match",    "rule_index": 2, "when": "$action = 'BUY'"}
{"t": "rule_no_match", "rule_index": 0, "when": "$action = 'DIV'"}
{"t": "rule_no_match", "rule_index": 1, "when": "...", "error": "ParseError"}
```

The `error` field on `rule_no_match` is present only when the `when` expression
failed to evaluate. The rule is treated as non-matching in that case.
Consumers MUST tolerate the field's absence (treat missing `error` as "rule
evaluated cleanly to false") — do not require it.

#### `row_filtered`

The row was silently skipped (e.g. outside the date window derived from the
filename). No `row_output` follows.

```jsonc
{ "t": "row_filtered", "reason": "date_filter_from_filename" }
```

#### `row_output`

Output values for the matched rule, in `output_schema` column order.

```jsonc
{ "t": "row_output", "values": ["2026-04-01", "AAPL", "BUY", "10", "150.00"] }
```

#### `row_end`

Terminates the row. Emitted even when the row was filtered, errored, or had no
matching rule — consumers can count `row_end` to verify progress.

```jsonc
{ "t": "row_end" }
```

#### `file_end`

Summary of one file.

```jsonc
{
  "t": "file_end",
  "template": "xtb2_cash",
  "path": "data/xtb/2026.csv",
  "stats": { "rows": 42, "written": 38, "errors": 0, "warnings": 0 },
}
```

`errors` is the count of `input_schema` expression failures during this file's
processing. (`var_error` events for `row_rules` overrides are not yet
aggregated here; consumers wanting a complete count should also tally
`var_error` events.) `warnings` is the count of non-fatal per-file issues
(date-filter no-range, malformed `YYYY-MM-DD_YYYY-MM-DD` in filename). Both
default to `0` for files that processed cleanly.

#### `done`

Final event. Exit code of the CLI process.

```jsonc
{ "t": "done", "exit_code": 0 }
```

| Exit code | Meaning                                                  |
| --------- | -------------------------------------------------------- |
| `0`       | OK.                                                      |
| `1`       | Fatal error (config load, unrecoverable pipeline error). |
| `2`       | Warnings present (e.g. empty input files).               |

### Ordering guarantees

For any file, events appear in this order:

```text
file_start
prepass_set*                      (may be zero)
(row_start
    var_eval | var_error*         (input_schema vars)
    (rule_no_match | rule_match)*
    (rule_match
        var_eval | var_error*     (rule-local vars)
        row_filtered? | row_output?)
    row_end)*
file_end
```

Across files, `file_start` / `file_end` pairs are interleaved per
`conversion_templates` order, but a `file_end` always precedes the next
`file_start`.

The stream is framed by a single `start` event at the beginning and a single
`done` event at the end. A missing `done` means the process crashed; consumers
should treat stderr as authoritative in that case.

### Versioning policy

- **Minor** additions (new optional fields, new event kinds) keep
  `schema_version` the same. Consumers MUST ignore unknown fields and unknown
  event kinds.
- **Breaking** changes (renaming a field, removing an event, changing the shape
  of an existing field) bump `schema_version`. Consumers SHOULD reject streams
  with a higher `schema_version` than they were built for.

---

## bxp-fmt

bxp-fmt is a developer utility invoked with exactly one action flag. All
subcommands emit to **stdout** on success; errors go to **stderr**. Each
invocation is stateless and short-lived.

### Exit codes

| Code | Meaning                                                                          |
| ---- | -------------------------------------------------------------------------------- |
| `0`  | Success.                                                                         |
| `1`  | Validation failure — config diagnostic, expression error, template id not found. |
| `2`  | Usage error — unknown flag, missing argument, mutually-exclusive actions.        |

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

`args[].kind` values: `expr` (any expression) | `literal_string` (bare string
literal) | `literal_int_positive` (positive integer literal, ≥ 1) |
`sunrise_format` (sunrise date-format pattern) | `pre_pass_name` (name of a
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

| Binary     | Role                             | Source file                                                                                                        |
| ---------- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `bxp-cli`  | Produces `--trace` NDJSON stream | [`bxp-cli/src/pipeline.zig`](../bxp-cli/src/pipeline.zig) — `Output.event()`                                       |
| `bxp-cli`  | Emits `start` / `done`           | [`bxp-cli/src/main.zig`](../bxp-cli/src/main.zig)                                                                  |
| `bxp-fmt`  | All subcommand outputs           | [`bxp-fmt/src/main.zig`](../bxp-fmt/src/main.zig)                                                                  |
| `bxp-core` | Per-call trace in `--expr-trace` | [`bxp-core/src/expr.zig`](../bxp-core/src/expr.zig) — `emitCallTrace()`                                            |
| `bxp-core` | `--docs` catalog                 | [`bxp-core/src/docs.zig`](../bxp-core/src/docs.zig) — `writeDocs()`                                                |
| `bxp-gui`  | Consumes `--trace`               | [`bxp-gui/lib/store/trace_builder.dart`](../bxp-gui/lib/store/trace_builder.dart)                                  |
| `bxp-gui`  | Consumes `--expr-trace`          | [`bxp-gui/lib/services/bxp_process_client.dart`](../bxp-gui/lib/services/bxp_process_client.dart) — `traceExpr()`  |
| `bxp-gui`  | Consumes `--config`              | [`bxp-gui/lib/services/bxp_process_client.dart`](../bxp-gui/lib/services/bxp_process_client.dart) — `loadConfig()` |
| `bxp-gui`  | Consumes `--docs`                | [`bxp-gui/lib/store/trace_store.dart`](../bxp-gui/lib/store/trace_store.dart) — `loadDocs()`                       |
| `bxp-gui`  | Event model                      | [`bxp-gui/lib/store/trace_model.dart`](../bxp-gui/lib/store/trace_model.dart)                                      |
