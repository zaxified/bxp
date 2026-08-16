# Stateless inspect formats

These are the JSON output shapes of the stateless inspection core
(`bxp-core/src/inspect.zig`): config annotation, single-expression validation
and evaluation, expr-trace, template list/fetch, and the docs catalog. The
shapes are transport-agnostic — they reach callers through the **bxp-mcp** tools
(the agent surface, mapped per subsection below) and the **bxp-gui-bridge** FFI
(in-process for the Dart GUI). The snippets below show each shape via its bxp-mcp
`tools/call` `arguments` object; the bridge produces the identical bytes
in-process through the mapped `bridge_*` op. The `--name` labels below (e.g.
`--expr`, `--config`) are shorthand shape names, **not** CLI flags — each shape is
produced by the bxp-mcp tool and the bridge op shown in the table below.

Each shape's canonical name, the bxp-mcp tool that produces it, and the bridge op:

| Shape (below)      | bxp-mcp tool         | bridge op                         |
| ------------------ | -------------------- | --------------------------------- |
| `--expr`           | `bxp_validate_expr`  | `bridge_eval_expr`                |
| `--expr-trace`     | `bxp_eval_trace`     | `bridge_eval_expr_trace`          |
| `--config`         | `bxp_validate`       | `bridge_inspect {config}`         |
| `--list-templates` | `bxp_list_templates` | `bridge_inspect {list_templates}` |
| `--fetch-template` | `bxp_fetch_template` | `bridge_inspect {fetch_template}` |
| `--docs`           | `bxp_docs`           | `bridge_inspect {docs}`           |

---

## --expr

Validates a single expression against an empty row context (no column refs, no
lookups). Used by bxp-gui's ExprPanel for live per-edit validation.

```jsonc
// bxp_validate_expr arguments
{ "expr": "ABS(-1)" }
```

**Success:** `{ "ok": true }`.

**Error:** `ok:false` with the diagnostic fields inline:

```jsonc
{ "ok": false, "error": "NotANumber", "detail": "(pos 4)", "off": 0, "len": 7 }
```

| Field    | Type     | Notes                                                                                                    |
| -------- | -------- | -------------------------------------------------------------------------------------------------------- |
| `error`  | `string` | Zig error name.                                                                                          |
| `detail` | `string` | Human-readable position hint.                                                                            |
| `off`    | `u32`    | Byte offset of the offending token in the expression source. Present only when the parser pinned a span. |
| `len`    | `u32`    | Byte length of the offending token. Present only when `off` is present.                                  |

Column references (`[ColumnName]`) always fail in the `--expr` shape because
there is no row context; use the `--expr-trace` shape with `headers` / `fields`
for reference resolution.

---

## --expr-trace

Evaluates an expression with per-function-call trace output and optional fake
row context. Used by bxp-gui's expression playground (Variables panel).

```jsonc
// bxp_eval_trace arguments
{
  "expr": "ABS([Price])",
  "headers": ["Date", "Price"],
  "fields": ["2026-04-01", "150.00"],
}
```

One NDJSON line per builtin call (emitted before the sentinel — partial trace
survives a mid-expression error):

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

| Outcome | Sentinel (last NDJSON line)                                                      |
| ------- | -------------------------------------------------------------------------------- |
| Success | `{"t": "final", "value": "150"}`                                                 |
| Error   | `{"t": "error", "error": "NotANumber", "detail": "(pos 4)", "off": 0, "len": 7}` |

The error sentinel carries the same optional `off`/`len` fields as `--expr`.

**Row context arguments** — both required together or omitted together:

| Argument  | Type                   | Notes                                                       |
| --------- | ---------------------- | ----------------------------------------------------------- |
| `headers` | JSON array of `string` | Column names matching the CSV header row.                   |
| `fields`  | JSON array of `string` | Field values for the current row; same length as `headers`. |

Mismatched lengths are rejected as an argument error.

---

## --config

Validates a config file and emits it back as **annotated JSON** — standard JSON
with reserved `$`-prefixed sibling keys that carry preserved comments and
diagnostics. Used by bxp-gui's `loadConfig()` and the VALIDATE button.

```jsonc
// bxp_validate arguments
{ "config": "<bxp-cli.json text>" }
```

The GUI's `bridge_inspect {config}` call passes a `check_fs` deadline (seconds)
that runs the filesystem existence check (data directories, input file patterns)
per template; `0` — the `bxp_validate` agent default — skips it.

**Output:** annotated JSON; the call is flagged as an error when any `$err_*` is
present.

### Annotated JSON keys

All `$`-prefixed keys share a single monotonically-increasing counter `<N>` so
every sibling key is unique. Each finding is inserted immediately before the
offending key in its parent object; appended at the end when the offending key
is absent (e.g. a missing required field).

| Key prefix  | Shape                                                                                 | Meaning                |
| ----------- | ------------------------------------------------------------------------------------- | ---------------------- |
| `$err_<N>`  | `{ "message": "...", "off"?: N, "len"?: N, "line"?: N, "col"?: N, "suggest"?: "..." }` | Validation error.      |
| `$warn_<N>` | same shape as `$err_<N>`                                                              | Non-fatal warning.     |
| `$info_<N>` | same shape as `$err_<N>`                                                              | Informational finding. |

`message` is the only key always present; every other key is omitted when the
diagnostic does not carry it. The two optional pairs locate different things:

- `off` / `len` — byte offsets into the **expression source string** of the
  offending token (what the GUI's ExprPanel highlights).
- `line` / `col` — 1-based **position in the config file**, carried by the
  diagnostics the config loader's own scanner produces: JSON5 syntax errors and
  duplicate keys. These let a finding that has no place in the config tree still
  be pointed at a source line.

`suggest` is the did-you-mean hint, separate from the prose in `message`.

A JSON5 syntax error therefore arrives positioned rather than as a bare error
name — the loader is re-run over the same bytes to recover the position even
when nothing parseable can be built:

```jsonc
// config with `data_dir: [1,,]` on line 4
{
  "$err_1": {
    "message": "unexpected character — check for missing quotes, commas, or brackets",
    "line": 4,
    "col": 22
  }
}
```

`$err_<N>` may also appear with a bare **string** value instead of an object —
`inspect.formatRootErr` still emits that older form for a root error. A strict
consumer must branch on the value type.

**Comments are not carried.** `json5.preprocessAnnotated` strips them exactly as
the plain `preprocess` does — what "annotated" buys is the source-offset
bookkeeping the markers above are positioned by, not comment retention. No
`$comm_<N>` key is ever emitted; the `json5` module has a test asserting it.
`config.isAnnotationKey` nonetheless matches the `$comm_` prefix defensively, so
a stray one would be filtered rather than read as a config key. The GUI keeps
comments by parsing the same file itself with `packages/json5_ast`, which is
what makes its CST-preserving Save possible; the annotated JSON is a diagnostics
channel, not a round-trip format.

The runtime config loader (`bxp-cli`) uses `json5.preprocess` (non-annotated
variant), so `$err_<N>` keys never reach the conversion pipeline.

### --list-templates

```jsonc
// bxp_list_templates arguments
{ "config": "<bxp-cli.json text>" }
```

Returns a JSON array of template ids. No semantic validation — reports whatever
keys appear under `conversion_templates`, even if a template body is malformed.

```jsonc
["xtb2_cash", "revolut_stocks", "anycoin"]
```

### --fetch-template

```jsonc
// bxp_fetch_template arguments
{ "config": "<bxp-cli.json text>", "id": "xtb2_cash" }
```

Returns the raw JSON5 block for one template as a JSON string, or an error when the template id is not found.

---

## --docs

Returns the full language + schema documentation catalog as JSON. Single source
of truth consumed by bxp-gui at startup.

```jsonc
// bxp_docs — no arguments
{}
```

### Top-level structure

```jsonc
{
  "functions":     [...],
  "keywords":      [...],
  "operators":     [...],
  "tokens":        [...],
  "config_schema": [...]
}
```

### `functions` entry

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

### `keywords` entry

```jsonc
{ "name": "true", "description": "Boolean literal true." }
```

### `operators` entry

```jsonc
{ "token": "+", "description": "Addition or string concatenation." }
```

### `tokens` entry

```jsonc
{
  "kind": "field_ref",
  "syntax": "[ColName]",
  "description": "Reference a CSV column by name.",
}
```

### `config_schema` entry

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
