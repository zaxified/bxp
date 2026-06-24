# Implementation Details

## Two-pass processing pipeline

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

## Expression evaluator (expr.zig)

The evaluator is a hand-written recursive-descent parser.
Operator precedence (high → low):

```text
unary -  →  * /  →  & (concat)  →  + -  →  = != < > <= >=  →  AND  →  OR
```

**How to add a new function:** see [Adding a new built-in function](howto.md#adding-a-new-built-in-function).

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

## Configuration system (config.zig + json5.zig)

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

## Memory model

Two arena allocators are used during processing:

| Allocator                     | Lifetime                    | Owns                                          |
| ----------------------------- | --------------------------- | --------------------------------------------- |
| `file_alloc` (ArenaAllocator) | Reset after each input file | File content, parsed rows, expression results |
| `line_alloc` (ArenaAllocator) | Reset after each row        | Per-row expression evaluation scratch space   |

The root GPA (`std.heap.DebugAllocator`) catches leaks in debug builds.

---

## Limits and key constants

Hard limits are small named constants in the source — change them there, not in
config. Current values and where they live:

| Limit                     | Value  | Constant                  | Defined in                 |
| ------------------------- | ------ | ------------------------- | -------------------------- |
| Config file size          | 1 MiB  | `CONFIG_MAX_FILE_SIZE`    | `bxp-core/src/config.zig`  |
| XLSX shared-strings table | 1 GiB  | `XLSX_SHARED_STRINGS_CAP` | `bxp-core/src/xlsx.zig`    |
| CSV read chunk            | 10 MiB | `CHUNK_SIZE`              | `bxp-cli/src/pipeline.zig` |
| Columns per row           | 16384  | `MAX_COLUMNS`             | `bxp-cli/src/pipeline.zig` |

CSV and XLSX inputs are **streamed**, so there is no whole-file size limit — a
multi-GB CSV converts at flat RSS. The only file-size cap is on the config file
(`bxp-cli.json`) itself. A row wider than `MAX_COLUMNS` is truncated with a
warning rather than rejected.

---

## Error handling philosophy

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
> [`bxp-core/src/btrace.zig`](https://github.com/zaxified/bxp/blob/master/bxp-core/src/btrace.zig) as
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
