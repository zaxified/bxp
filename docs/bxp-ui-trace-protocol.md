# bxp-ui Trace Protocol

> Part of the [developer guide](devel.md).

Defines the NDJSON event stream that `bxp-cli --trace` writes to stdout.
The stream is consumed by [bxp-ui](../bxp-ui/) to drive the dry-run debugger.

---

## Wire format

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

## Current version

```
schema_version = 1
```

## Event reference

### `start`

Emitted once, before any other event.

```jsonc
{
  "t": "start",
  "schema_version": 1,
  "config": "/path/to/bxp-cli.json",
  "templates": ["xtb2_cash", "revolut_stocks"]
}
```

| Field            | Type              | Notes                                               |
| ---------------- | ----------------- | --------------------------------------------------- |
| `schema_version` | `u32`             | Protocol version. Bump on any breaking change.      |
| `config`         | `string`          | Absolute path that bxp-cli loaded the config from.  |
| `templates`      | `array<string>`   | Templates that will be processed, in order.         |

### `file_start`

One input file is about to be processed.

```jsonc
{
  "t": "file_start",
  "template": "xtb2_cash",
  "path": "data/xtb/2026.csv",
  "rows": 42,
  "headers": ["Date", "Symbol", "Qty", "Price"]
}
```

| Field      | Type            | Notes                                                |
| ---------- | --------------- | ---------------------------------------------------- |
| `template` | `string`        | Template id from `conversion_templates`.             |
| `path`     | `string`        | Resolved input path (joined with `data_dir`).        |
| `rows`     | `usize`         | Total row count after parsing the input file.        |
| `headers`  | `array<string>` | Column headers in file order.                        |

### `prepass_set`

One lookup entry accumulated during the optional pre-pass over the input file.
Emitted after `file_start` and before any `row_start` for that file.

```jsonc
{"t": "prepass_set", "key": "AAPL", "field": "isin", "value": "US0378331005"}
```

| Field   | Type     | Notes                                                     |
| ------- | -------- | --------------------------------------------------------- |
| `key`   | `string` | Composite key (join of `pre_pass.key` evaluations).       |
| `field` | `string` | Field name (key in `pre_pass.values`).                    |
| `value` | `string` | Value evaluated from `pre_pass.values[field]`.            |

### `row_start`

Begins a new row. All subsequent `var_eval`, `var_error`, `rule_match`,
`rule_no_match`, `row_filtered`, and `row_output` events belong to this row
until the matching `row_end`.

```jsonc
{"t": "row_start", "file_row": 3, "fields": ["2026-04-01", "AAPL", "10", "150.00"]}
```

| Field      | Type            | Notes                                              |
| ---------- | --------------- | -------------------------------------------------- |
| `file_row` | `usize`         | 1-based row index in the source file.              |
| `fields`   | `array<string>` | Raw cell values in column order (same as headers). |

### `var_eval`

A variable from `input_schema` or the rule's `rows[]` evaluated successfully.

```jsonc
{"t": "var_eval", "name": "$date", "expr": "DATE_CONVERT([Date],'%Y-%m-%d')", "value": "2026-04-01"}
```

### `var_error`

Variable evaluation failed. The row continues with the variable bound to the
empty string, so subsequent rules may still match.

```jsonc
{
  "t": "var_error",
  "name": "$price",
  "expr": "ROUND([Price])",
  "error": "NotANumber",
  "detail": "(pos 12)"
}
```

| Field    | Type     | Notes                                                       |
| -------- | -------- | ----------------------------------------------------------- |
| `name`   | `string` | Variable name (`$…`).                                       |
| `expr`   | `string` | Source expression, for UI display.                          |
| `error`  | `string` | Zig error name (e.g. `NotANumber`, `ParseError`).           |
| `detail` | `string` | Optional position / field hint, e.g. `(line 3, pos 12)`.    |

### `rule_match` / `rule_no_match`

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

### `row_filtered`

The row was silently skipped (e.g. outside the date window derived from the
filename). No `row_output` follows.

```jsonc
{"t": "row_filtered", "reason": "date_filter_from_filename"}
```

### `row_output`

Output values for the matched rule, in `output_schema` column order.

```jsonc
{"t": "row_output", "values": ["2026-04-01", "AAPL", "BUY", "10", "150.00"]}
```

### `row_end`

Terminates the row. Emitted even when the row was filtered, errored, or had no
matching rule — consumers can count `row_end` to verify progress.

```jsonc
{"t": "row_end"}
```

### `file_end`

Summary of one file.

```jsonc
{
  "t": "file_end",
  "template": "xtb2_cash",
  "path": "data/xtb/2026.csv",
  "stats": {"rows": 42, "written": 38, "errors": 0}
}
```

Note: `errors` is currently always `0` — the CLI emits `var_error` events but
does not aggregate them into the file summary yet. Consumers that want a
per-file error count should derive it from `var_error` events.

### `done`

Final event. Exit code of the CLI process.

```jsonc
{"t": "done", "exit_code": 0}
```

| Exit code | Meaning                                                    |
| --------- | ---------------------------------------------------------- |
| `0`       | OK.                                                        |
| `1`       | Fatal error (config load, unrecoverable pipeline error).   |
| `2`       | Warnings present (e.g. empty input files).                 |

## Ordering guarantees

For any file, events appear in this order:

```
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

## Versioning policy

- **Minor** additions (new optional fields, new event kinds) keep
  `schema_version` the same. Consumers MUST ignore unknown fields and unknown
  event kinds.
- **Breaking** changes (renaming a field, removing an event, changing the shape
  of an existing field) bump `schema_version`. Consumers SHOULD reject streams
  with a higher `schema_version` than they were built for.

## Producer

- Zig: [`bxp-cli/src/pipeline.zig`](../bxp-cli/src/pipeline.zig) — `Output.event()`
  writes one event.
- Zig: [`bxp-cli/src/main.zig`](../bxp-cli/src/main.zig) — emits `start` and
  `done`.

## Consumer

- TypeScript: [`bxp-ui/src/mainview/trace/types.ts`](../bxp-ui/src/mainview/trace/types.ts)
  mirrors the event shapes.
- TypeScript: [`bxp-ui/src/mainview/trace/parse.ts`](../bxp-ui/src/mainview/trace/parse.ts)
  parses one NDJSON line to a discriminated union.
- TypeScript: [`bxp-ui/src/mainview/trace/model.ts`](../bxp-ui/src/mainview/trace/model.ts)
  folds events into the `TraceModel` the UI renders.
