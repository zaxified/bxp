# CLAUDE.md — bxp-cli

Guidance for Claude Code when working with the bxp-cli package.
For monorepo-level context see [`../CLAUDE.md`](../CLAUDE.md).

## Purpose

**bxp-cli** — Zig 0.16.0 CLI tool that converts broker export statements to portfolio
tracker formats via JSON5 conversion templates. Wealthfolio (`.csvx`) and brycht.app are
the shipping targets today; any other tracker can be reached by writing an
`output_schema` for it — no code change required. All broker logic is configuration-driven
(`bxp-cli.json`) — no compiled-in broker modules.

## Source layout

```text
bxp-cli/
  src/
    main.zig      ← CLI layer: arg parsing, config loading, dispatch
    pipeline.zig  ← Processing: processBroker(), zipPrePass(), xlsxPrePass(), helpers
  build.zig       ← depends on bxp-core (path dep ../bxp-core)
  build.zig.zon
  (scripts/, test-data/ and resources/ moved to monorepo root)
```

## Build and run

```bash
# Build
zig build

# Run all templates from bxp-cli.json
./zig-out/bin/bxp-cli

# Run a single template
./zig-out/bin/bxp-cli --template revolutx_to_wealthfolio

# Override data directory
./zig-out/bin/bxp-cli --template revolutx_to_wealthfolio --data ../my-data/

# Use a custom config file
./zig-out/bin/bxp-cli --config my-config.json

# Print skipped/unmatched rows as JSON
./zig-out/bin/bxp-cli --debug

# Machine-readable run summary: ONE JSON object on stdout (per-template +
# overall files/rows_in/rows_out/warnings/errors/time_ms + captured message
# lines) instead of the human stdout summaries and stderr diagnostics.
# Built for bxp_simulate / CI — counts are structured, so it doesn't break
# when the human wording changes. Conflicts with --trace / --quiet / --debug.
./zig-out/bin/bxp-cli --debug=json

# Suppress all output (exit code still reflects result)
./zig-out/bin/bxp-cli --quiet

# Skip files whose per-file output already exists.
# With `combined_output`, the per-file skip still applies, but the
# combined roll-up is always rebuilt in full so it reflects every input
# (a skipped input is still iterated into the combined sink).
./zig-out/bin/bxp-cli --fresh

# Run the full pipeline in memory but write no output files (preview /
# validation). Independent of --trace.
./zig-out/bin/bxp-cli --dry-run

# Emit the binary BXTB trace stream on stdout (GUI dry-run debugger; forces
# --quiet, conflicts with --debug). --trace-file <path> additionally mirrors a
# full trace to a file, independent of --trace. Value-flags accept
# `--name value` or `--name=value`.
./zig-out/bin/bxp-cli --trace
```

Exit codes: `0` = success, `1` = error, `2` = warnings.

## Configuration (bxp-cli.json)

All broker logic is defined in `bxp-cli.json` — there are no compiled-in broker modules.

### Top-level fields

- `maps` — optional registry of named, reusable `key→value` tables. Each entry is a map name →
  object `{ key: value }`. Referenced from expressions by name via `REMAP(s, 'name')` (whole-value
  lookup) / `REPLACE(s, 'name')` (substring). A template may also define its own `maps` block that
  overrides a same-named global entry. Key order is preserved (REPLACE applies pairs in order).
- `conversion_templates` — map of template ID → template config. At least one required.
- `data_dir` paths are relative to the `bxp-cli.json` location (i.e. `../data/...` for shared `data/` directory).

### Template config fields (key order convention)

```json
{
  "data_dir": "../data/<template_id>",
  "file_pattern_in": ".csv",
  "file_pattern_out": ".csvx",
  "date_filter_from_filename": false,
  "maps": {},
  "zip_input": {},
  "xlsx_sheet": {},
  "pre_pass": {},
  "input_schema": {},
  "row_rules_debug_missing": false,
  "row_rules": [],
  "output_schema": {}
}
```

- `data_dir` — path to directory containing input CSV files.
- `file_pattern_in` — **required** — **literal** suffix filter for input files (a plain
  `endsWith` match, **not** a glob — `*` is not special), e.g. `".csv"` for all CSV files,
  `"_3.csv"` to restrict to files ending in `_3.csv`. The matched suffix is also stripped
  from the filename to derive the output name (with `file_pattern_out`).
- `file_pattern_out` — **required** — output filename suffix. Replaces `file_pattern_in` in the
  output filename (e.g. `"_cash.csv"` → `"_cash.csvx"`). There is no derived default: the loader
  initialises it to `""` and validation rejects an empty value (`config.zig` `validate`).
- `date_filter_from_filename` — optional boolean (default `false`). When `true`, rows whose
  `$date` value falls outside the date range encoded in the filename (`YYYY-MM-DD_YYYY-MM-DD`)
  are silently skipped. Requires `$date` in `input_schema` — validated at startup.
  The row-level filter is a lexical (string) prefix compare against the filename range, so
  `$date` MUST evaluate to ISO `YYYY-MM-DD` (or longer ISO prefix like `YYYY-MM-DDTHH:MM:SS`).
  Non-ISO formats (`DD.MM.YYYY`, `MM/DD/YYYY`, …) will mis-filter silently — use
  `DATE_CONVERT` in `input_schema` to normalise first.
- `maps` — optional template-local named maps `{ map_name: { key: value } }`, merged over the
  top-level `maps` registry (this template's entry wins on a name collision). Referenced from
  expressions via `REMAP`/`REPLACE`'s `'name'` argument.
- `zip_input` — optional object `{ "entry_pattern", "dir_mode", "path_separator" }`.
  When present, every `*.zip` in `data_dir` is unpacked into flat intermediate CSV files
  **before** the xlsx and main passes (so the chain is zip → (xlsx) → csv → csvx), e.g. a
  RÚIAN/Oracle "zip of one CSV per region" export. Each member whose in-archive name ends with
  `entry_pattern` (default `".csv"`) is streamed out (memory bounded to one inflate window) and
  written under a flat name per `dir_mode`: `"basename"` (default) keeps only the final path
  component (flattening an in-archive `CSV/foo.csv` → `foo.csv`); `"keep_path"` replaces every
  `/` with `path_separator` (default `"_"`). Output names are always flat, so a member can never
  escape `data_dir` (zip-slip); a member mapping to a separator, `"."`/`".."`, or a name already
  produced by another member is a fatal error rather than a silent clobber. `--fresh` skips a
  member whose intermediate CSV already exists. The unpack runs **in parallel** — the members are
  independent, so workers steal jobs off a shared queue (each with its own file cursor + inflate
  window), beating a single-threaded `unzip` on a multi-core host. Templates sharing a `data_dir`
  unpack it once. See `docs/examples/real-world/ruian-address-points/`.
- `xlsx_sheet` — optional object `{ "name", "header_row", "output_suffix" }`.
  When present, xlsx files in `data_dir` are converted to an intermediate CSV file before the
  normal CSV processing loop. `name` is a prefix of the sheet name in the workbook (prefix
  match, so `"CASH OPERATION"` also matches `"CASH OPERATION 28022026"`);
  `header_row` is the 1-based row number containing column headers; `output_suffix` is appended
  before `.csv` in the output filename (e.g. `"_3"` → `"<stem>_3.csv"`).
  Templates sharing the same `data_dir` — each with their own `xlsx_sheet` — share the xlsx
  extraction pass (each xlsx file is extracted only once).
- `pre_pass` — optional first-pass lookup table(s). Iterates all rows before the main loop,
  collects rows matching `when`, stores `values` expressions keyed by `key`. Two accepted shapes:
  - **Legacy single block** `{ when, key, values }` — accessible via 2-arg
    `LOOKUP(key_expr, 'field_name')`. Internally bound to a synthetic `_default` namespace.
  - **Named blocks** `{ name1: { when, key, values }, name2: { ... } }` — each block is its own
    namespace. Accessed via 3-arg `LOOKUP('name1', key_expr, 'field_name')`. Use this when one
    template needs multiple independent lookup tables.
    Note: `values` keys are lookup field names (plain strings, no `$` prefix) — they are not
    template variables.
- `input_schema` — **required** — variable definitions: `$name` → expression string.
  All variable names use the `$` prefix convention (e.g. `$date`, `$ticker`, `$amount`).
- `row_rules_debug_missing` — optional boolean (default `false`). When `true`, rows that
  match no `row_rules` entry are printed to stdout when `--debug` is active.
- `row_rules` — ordered list of routing rules. First matching rule wins.
  Each rule: `{ "when": "expr", "rows": [ { "$var": "expr", ... } ] }`.
  `when` is evaluated against raw CSV fields. `rows: []` = silent skip.
  `rows` entries set `$action` and can override any `$variable`.
- `output_schema` — **required** — ordered map of output CSV header → `$variable` name.
  Determines both output columns and their order.

### Input/output format and CSV-dialect fields

Optional per-template keys controlling how input is parsed and output is
written. All default to a standard comma/dot/UTF-8 CSV, so a plain broker
export needs none of them.

- `file_type_in` / `file_type_out` — `"csv"` (default) or `"json"`. `json` in =
  array-of-objects input (streamed via `json.zig`); `json` out = the
  `output_schema` rows emitted as a JSON array instead of CSV.
- `csv_delimiter_in` / `csv_delimiter_out` — field separator (single char,
  default `","`; e.g. `";"`, `"\t"`, `"|"`). CSV only.
- `csv_decimal_separator_in` / `csv_decimal_separator_out` — decimal char in
  numeric fields (default `"."`). Set `_in` to `","` for European exports.
- `csv_text_quote_in` / `csv_text_quote_out` — `"none"`, `"single"` (`'`), or
  `"double"` (`"`); input default `"double"`, output default `"none"`.
- `csv_input_encoding` / `csv_output_encoding` — character encoding of the
  input / output CSV file (default `"utf-8"`). Accepts `"utf-8"`,
  `"windows-1250"`, `"windows-1252"`, `"iso-8859-1"`, `"iso-8859-2"`,
  `"iso-8859-15"` (Layer 0). Input is transcoded to UTF-8 on read, output from
  UTF-8 on write (unrepresentable characters become `?`). Use for legacy
  non-UTF-8 exports, e.g. `"windows-1250"` for a Czech Excel CSV. CSV only —
  JSON and xlsx are always UTF-8 (a UTF-16 xlsx is skipped with a warning).
- `csv_header_line` — 1-based line of the CSV header (default `1`). `0` =
  headerless input — no header row, first line is data, columns reachable only
  by position via `FIELDS(n)`; `N>1` skips `N-1` preamble lines. CSV input only.
- `combined_output` — boolean (default `false`). When `true`, every input file
  _additionally_ writes its rows into one merged file
  `1-{template_id}-combined{file_pattern_out}` in `data_dir`, alongside the
  normal per-file outputs. The combined roll-up is always rebuilt in full
  (a `--fresh`-skipped input is still iterated into it).

### Variable naming convention

All template-internal variables use the `$` prefix:

- `$date` — datetime string (required when `date_filter_from_filename` is `true`)
- `$action` — activity type (set exclusively by `row_rules`, never in `input_schema`)
- `$ticker`, `$quantity`, `$unitprice`, `$currency`, `$fee`, `$amount` — trade data

Raw CSV column references use `[ColumnName]` syntax — these are not variables.

### Variable model

`input_schema` evaluates one `$variable` per expression per row. `row_rules` matches
on raw fields and sets `$action` (plus any overrides) for the output row. `output_schema`
maps output column headers to `$variable` names, controlling column set and order.

## Adding a new conversion template

```json
"<broker>_to_<tracker>": {
  "data_dir": "../data/<broker>_to_<tracker>",
  "maps": {},
  "input_schema": {
    "$date":      "<date expression>",
    "$ticker":    "<ticker expression>",
    "$quantity":  "<quantity expression>",
    "$unitprice": "<unit price expression>",
    "$currency":  "<currency expression>",
    "$fee":       "<fee expression>",
    "$amount":    "<amount expression>"
  },
  "row_rules_debug_missing": true,
  "row_rules": [
    { "when": "<condition>", "rows": [ { "$action": "'BUY'" } ] },
    { "when": "<condition>", "rows": [] }
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

No code changes required.

## File selection

All `.csv` files in the template's `data_dir` are processed. If the filename contains
`YYYY-MM-DD_YYYY-MM-DD` anywhere (before the extension), and `date_filter_from_filename`
is `true`, those dates are used to filter rows by `$date`. Otherwise all records are written.

## Expression reference (expr.zig)

Expressions are evaluated per row. Operator precedence (high → low):
`unary -` → `* /` → `&` (concat) → `+ -` → `= != < > <= >=` → `NOT` → `AND` → `OR`

| Syntax                                                  | Description                                                                                                                                                                                                     |
| ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `[ColumnName]`                                          | Field value by CSV header name (name lookup only — a numeric `[4]` looks up a column literally named "4", **not** the 4th column)                                                                               |
| `FIELDS(n)`                                             | Field value by 1-based column **position** — use this for headerless/positional inputs (HL7 segments, year-indexed TSV) where columns are addressed by number                                                   |
| `'text'`                                                | String literal                                                                                                                                                                                                  |
| `IF(cond, yes, no)`                                     | Short-circuit conditional                                                                                                                                                                                       |
| `CASE(expr, m1, r1, …, default)`                        | Multi-branch mapping — first `r` whose `m` equals `expr`, else trailing `default` (or `""`). Only the chosen result is evaluated. Collapses nested `IF` chains                                                  |
| `IFERROR(expr, fallback)`                               | `expr`'s value, or `fallback` on a data error (bad number/date, overflow). Template errors (unknown function, arity, syntax) still surface                                                                       |
| `ABS(f)`                                                | Absolute numeric value                                                                                                                                                                                          |
| `DATE_CONVERT(f, from, to)`                             | Reformat date/time; format tokens use datefmt syntax (see section below)                                                                                                                                        |
| `PRICE_VALUE(f)`                                        | Strip currency symbol/code, return numeric string (`"24.00 CZK"` → `"24.00"`)                                                                                                                                   |
| `PRICE_CURRENCY(f)`                                     | Extract currency code (`"24.00 CZK"` → `"CZK"`, `"$100"` → `"USD"`)                                                                                                                                             |
| `REMAP(s, 'name' \| k, v, ...)`                         | Whole-value lookup: if `s` exactly equals a map key, return its value, else `s` unchanged. Named form resolves a `maps` entry; inline form `REMAP(s, k1,v1, ...)` gives pairs directly. Whole-value sibling of `REPLACE` (symbol/code/enum remap) |
| `LOOKUP(key, 'field')` / `LOOKUP('name', key, 'field')` | Retrieve value from `pre_pass` table — 2-arg form for legacy single block, 3-arg form for named blocks                                                                                                          |
| `SPLIT_PART(f, delim, n)`                               | Split `f` by `delim`, return nth part (1-based); `""` if fewer than n parts                                                                                                                                     |
| `CONTAINS(f, sub)`                                      | `true` when `sub` is found inside `f`                                                                                                                                                                           |
| `REGEX_MATCH(f, pattern)`                               | `true` when regex `pattern` matches anywhere in `f`. Linear-time engine (anchors, classes, quantifiers, groups, alternation; no backreferences/lookaround). Unicode-scalar mode, but `\d`/`\w`/`\s` stay ASCII — match accented letters with an explicit class like `[A-ZÁ-Ž]`. Use only when a literal CONTAINS / IN won't do                |
| `REGEX_EXTRACT(f, pattern)`                             | First part of `f` matched by regex `pattern` (the first capture group `(...)` if present, else the whole match), or `""` if no match. Pulls a ticker/code/token a literal `REPLACE`/`SPLIT_PART` can't isolate. Same syntax + Unicode notes as `REGEX_MATCH`                                                                                  |
| `NOT expr`                                              | Boolean negation keyword. Precedence between comparison operators and `AND` — `NOT [A] = 1` means `NOT ([A] = 1)`. Multiple NOTs stack.                                                                         |
| `NULLIF(value, sentinel)`                               | Empty string when `value` equals `sentinel`, otherwise `value`. Equality matches `=` operator. Use to collapse sentinels (`-9999`, `\N`, `N/A`).                                                                |
| `IN(value, v1, v2, ...)`                                | Variadic equality OR-chain — `true` when `value` matches any option. Replaces nested `IF([X] = 'A' OR [X] = 'B' ...)`.                                                                                          |
| `STARTS_WITH(f, prefix)`                                | `true` when `f` begins with `prefix` (case-sensitive); empty `prefix` always matches                                                                                                                            |
| `ENDS_WITH(f, suffix)`                                  | `true` when `f` ends with `suffix` (case-sensitive); empty `suffix` always matches                                                                                                                              |
| `LEFT(f, n)`                                            | First `n` bytes of `f` (`n` clamped to `[0, len]`; non-finite or negative `n` → `""`)                                                                                                                           |
| `RIGHT(f, n)`                                           | Last `n` bytes of `f` (`n` clamped to `[0, len]`; non-finite or negative `n` → `""`)                                                                                                                            |
| `SUBSTR(f, start, length)`                              | `length` bytes from `f` starting at 1-based `start`; non-positive/non-finite `start` or `length` → `""`                                                                                                         |
| `LPAD(s, len, pad)` / `RPAD(s, len, pad)`               | Pad `s` (left / right) with `pad` to `len` bytes; truncates if longer, empty `pad` returns `s`. `len` clamped to `[0, 65535]`                                                                                    |
| `POSITION(needle, haystack)`                            | 1-based byte position of the first `needle` inside `haystack`, `0` if absent; empty `needle` → `1`                                                                                                              |
| `PROPER(f)`                                             | Title-case — upper-case the first letter of each word, lower-case the rest (`apple inc` → `Apple Inc`); words break on any non-letter                                                                            |
| `MOD(a, b)`                                             | Remainder of `a / b` with the sign of `a` (truncated, like SQL/C `%`); `MOD(a, 0)` → `""`                                                                                                                       |
| `ISEMPTY(x)`                                            | `true` when `x` is empty or whitespace-only — the safe emptiness test (`x = ''` wrongly matches `'0'`)                                                                                                          |
| `IS_NUMERIC(x)`                                         | `true` when `x` actually holds a number (grouping like `1,234.56` accepted). Stricter than arithmetic on purpose: `""`, `nan` and `inf` coerce to 0 in a sum but are `false` here, which is how you find those rows |
| `UPPER(f)` / `LOWER(f)`                                 | Full-Unicode case conversion (`café`→`CAFÉ`, `ß`→`SS`, `я`→`Я`); unicameral scripts (CJK/Arabic/Hebrew) and invalid UTF-8 bytes pass through unchanged                                                            |
| `UNACCENT(f)`                                           | Strip Latin diacritics (`café`→`cafe`, `ÀÉ`→`AE`, `ß`→`ss`, `ø`→`o`); Latin-scope like Postgres — non-Latin keeps its base script (`Ά`→`Α`), CJK/Arabic pass through, ligatures not folded                       |
| `REPLACE(f, old, new, ...)`                             | Replace all occurrences of `old` with `new` in `f` (substring match, multi-byte UTF-8 safe). Variadic `REPLACE(f, o1, n1, o2, n2, ...)` applies the pairs in one left-to-right pass (first match per position wins; output not re-scanned) — one allocation instead of nesting. Empty `old` matches nothing                       |
| `TRIM(f)`                                               | Strip leading and trailing whitespace (space, tab, CR, LF)                                                                                                                                                      |
| `ROUND(f, n)`                                           | Round `f` to `n` decimal places, half away from zero — Excel-style (`n` may be negative for tens/hundreds; `n>=12` is a no-op)                                                                                  |
| `FLOOR(f)`                                              | Largest integer ≤ `f`                                                                                                                                                                                           |
| `CEILING(f)`                                            | Smallest integer ≥ `f`                                                                                                                                                                                          |
| `TRUNC(x [, n])`                                        | Cut `x` off after `n` decimal places (default 0) **toward zero** — differs from its neighbours only on negatives: `TRUNC(-3.999)` = `-3` vs `FLOOR` `-4`, `TRUNC(-3.999,2)` = `-3.99` vs `ROUND` `-4`. For values that must never grow in magnitude (cents truncated, never rounded up). `n` clamped to ±30 |
| `POWER(b, n)`                                           | `b` to the whole power `n` (0 ≤ `n` ≤ 1024), exact then rounded to scale 12 — `POWER(1.1,2)` is `1.21`. Fractional or negative `n` → `""` (use `SQRT`, or `1 / POWER(b, n)`); past the numeric range → `NumberOverflow` |
| `SQRT(x)`                                               | Square root of `x`, correctly rounded to scale 12 (`SQRT(2)` = `1.414213562373`), exact when the root is (`SQRT(6.25)` = `2.5`). Negative `x` → `""` |
| `NOW()`                                                 | Current UTC datetime as `"YYYY-MM-DDTHH:MM:SSZ"`                                                                                                                                                                |
| `RAND(n)`                                               | String of exactly `n` cryptographically random digits (first 1–9, rest 0–9); `n` clamped to `[1, 65]`                                                                                                           |
| `FILENAME()`                                            | Input file stem — directory + matched `file_pattern_in` suffix removed (the stem used for output naming); e.g. `SPLIT_PART(FILENAME(), '_', 3)` reads a field from the name. `""` in stateless eval             |
| `RECORD_NUM()`                                          | 1-based input record number of the current row within the file; `0` in stateless eval / pre_pass scan                                                                                                           |
| `SHEET_NAME()`                                          | Source `xlsx_sheet.name` for xlsx-derived input; `""` for native CSV/JSON and stateless eval                                                                                                                    |
| `COALESCE(a, b, ...)`                                   | Return first non-empty argument (empty = whitespace-only string; numbers/booleans are never empty). If all args are empty, returns the last arg verbatim — use `COALESCE([a],[b],'0')` for a guaranteed default |
| `LEN(s)`                                                | Byte length of `s` (UTF-8 byte count, not codepoint/grapheme); empty → `0`                                                                                                                                      |
| `GREATEST(a, b, ...)`                                   | Largest numeric value among args — per-row maximum (not cross-row aggregation); empty coerces to `0`, non-numeric raises an error                                                                               |
| `LEAST(a, b, ...)`                                      | Smallest numeric value among args — per-row minimum; same coercion rules as `GREATEST`                                                                                                                          |

### Date arithmetic functions

One reader serves this whole table plus the timezone functions below, so a
timestamp column works with `MONTH()` exactly as it works with `HOUR()`.
Accepted: `YYYY-MM-DD`, `YYYY-MM-DD hh:mm:ss`, the `T`-separated variant, and
an ISO tail (fractional seconds, `Z`, `±HH:MM`) which is read and ignored — the
builtins here are wall-clock; only `TO_UTC` honours an offset, through its own
format argument. A date function given a timestamp ignores the time half; a
time function given a bare date reads midnight.

The reader matches the **whole** string: `2024-03-15 nonsense` is an error, not
midnight. Everything else returns ISO `YYYY-MM-DD`; an empty argument yields
`""`, a malformed one raises (`IS_DATE` answers instead of raising). Pre-1970
dates are fully supported.

| Syntax                             | Description                                                                                                                                                                                                             |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DATEADD(d, n)`                    | Add `n` calendar days to `d` (negative subtracts). For business days use `WORKDAY`.                                                                                                                                     |
| `DATEDIFF(d1, d2)`                 | Calendar days from `d2` to `d1` (positive when `d1` is later)                                                                                                                                                           |
| `WORKDAY(d, n)`                    | Add `n` business days to `d`, skipping Sat/Sun (negative subtracts). T+2 settlement math; does **not** account for exchange holidays. `n=0` returns `d`                                                                 |
| `YEAR(d)` / `MONTH(d)` / `DAY(d)`  | Year / month (1–12) / day-of-month (1–31) component of `d` as a number                                                                                                                                                  |
| `WEEKDAY(d)`                       | ISO day-of-week (Mon=1 … Sun=7); weekend trade detection = `WEEKDAY([Date]) > 5`                                                                                                                                        |
| `QUARTER(d)`                       | Calendar quarter of `d`, 1–4 (Jan–Mar = 1); a fiscal year starting elsewhere shifts first, e.g. `QUARTER(DATEADD([Date], -90))` |
| `WEEKNUM(d)`                       | ISO 8601 week number of `d`, 1–53 (week 1 holds the first Thursday). Crosses the year: 2021-01-01 is week 53, 2024-12-30 is week 1 — not sortable without its own year |
| `EOMONTH(d)`                       | Last calendar day of `d`'s month, as `YYYY-MM-DD` (month-end snapping)                                                                                                                                                  |
| `NTH_DOW(year, month, weekday, n)` | Date of the `n`-th `weekday` (ISO Mon=1 … Sun=7) in `year`/`month`; negative `n` counts from month end (`-1` = last). `""` when it doesn't exist. EU DST = `NTH_DOW(YEAR(d), 3, 7, -1)` … `NTH_DOW(YEAR(d), 10, 7, -1)` |
| `HOUR(t)` / `MINUTE(t)` / `SECOND(t)` | Time components of a datetime, 0-23 / 0-59 / 0-59. A bare date reads as midnight, so a date-only column answers 0 |
| `IS_DATE(d [, format])`            | `true` when `d` parses — against the shapes above with one arg, or under `format` with two (what `DATE_CONVERT` accepts, 4-letter month abbreviations included). Never raises; blank is `false` |

### Timezone functions

DST-aware, backed by a bundled IANA tzdata snapshot — the `tz` module from the
pinned `zig_libs` fetch dep, whose offset tables compile into the binary (no
runtime tzdata lookup). Zone ids are IANA names or fixed offsets; unknown
zone → `""` / `false`.

| Syntax | Description |
| --- | --- |
| `TO_UTC(ts, from)` | Normalise an offset-bearing timestamp to UTC. `from` includes the `ZZ` offset token (or a literal `Z`); the parsed offset is subtracted → `YYYY-MM-DD hh:mm:ss`. No tzdata needed. `TO_UTC('...T14:23:01+02:00', 'YYYY-MM-DD[T]hh:mm:ssZZ')` → `... 12:23:01` |
| `TZ_OFFSET(datetime, zone)` | DST-aware UTC offset `±HH:MM` of IANA `zone` at local wall-clock `datetime` (`YYYY-MM-DD[ hh:mm:ss]`) |
| `TZ_CONVERT(ts, from_zone, to_zone)` | Convert wall-clock `ts` between zones (IANA id, fixed offset, or `UTC`) → `YYYY-MM-DD hh:mm:ss` |
| `IS_DST(datetime, zone)` | `true` when DST is in effect in IANA `zone` at local `datetime`, else `false` |

Type coercions: empty string → `0` in numeric context; any non-empty string → `true` in boolean context.

### Numeric model — fixed-point decimal

Computed numbers use a fixed-point decimal core (`i128` scaled by 1e12 → 12
fractional digits), not binary floating point. Consequences:

- Decimal money math is **exact**: `0.02 + 0.08` is `0.10`, not `0.0999…`.
  `+ −` are exact. `× ÷` and `ROUND(f, n)` all round **half away from zero**
  ("school" rounding, matching Excel/LibreOffice: `ROUND(2.5, 0) = 3`). A
  product or quotient with more than 12 fractional digits is rounded (not
  truncated) at the 12th.
- Arithmetic that overflows the range (below) is a `NotANumber`-class error,
  never a crash.
- Output prints the integer part plus up to 12 fractional digits, trailing
  zeros trimmed (`1000.00` → `1000`, `1/3` → `0.333333333333`).
- Magnitude is bounded to ≈ ±1.7e26 (far past world money supply); a literal
  or computed value beyond the range, or a genuinely non-numeric string used as
  a number, is a `NotANumber` error. There is no `Inf`/`NaN`.
- The non-finite tokens `nan` / `inf` / `-inf` (case-insensitive) are treated
  as **missing data** — coerced to `0` like an empty field, **not** an error —
  so a bad CSV export (a stray `nan`/`inf`) never turns an otherwise-working
  numeric expression into a counted error. (Used as an index they coerce to 0 →
  silent `""`, matching the historical skip.)
- **Passthrough** strings (a field copied straight through, e.g. a 15-digit
  coordinate or a 21-digit ID) are **never** routed through the numeric core,
  so their full precision survives — only genuinely _computed_ values quantise
  to 12 places.

## datefmt date format tokens

Used in `DATE_CONVERT(f, from_fmt, to_fmt)`. Both `from_fmt` and `to_fmt` use the same token set.
Implemented by the `datefmt` date core, consumed from the pinned `zig_libs`
fetch dependency (see `bxp-core/CLAUDE.md` → _External dependencies_).

| Token          | Meaning                                             | Example               |
| -------------- | --------------------------------------------------- | --------------------- |
| `YYYY`         | 4-digit year                                        | `2024`                |
| `YY`           | 2-digit year (00–69 → 2000–2069, 70–99 → 1970–1999) | `24`                  |
| `MM`           | 2-digit month (01–12)                               | `03`                  |
| `M`            | 1–2 digit month                                     | `3`                   |
| `MMMM`         | Full month name                                     | `March`               |
| `MMM`          | 3-char month abbreviation                           | `Mar`                 |
| `DD`           | 2-digit day (01–31)                                 | `07`                  |
| `D`            | 1–2 digit day                                       | `7`                   |
| `hh`           | 2-digit hour, **24h** (00–23)                       | `14`                  |
| `h`            | 1–2 digit hour, 24h                                 | `14`                  |
| `ii`           | 2-digit hour, **12h** (01–12)                       | `02`                  |
| `i`            | 1–2 digit hour, 12h                                 | `2`                   |
| `mm`           | 2-digit minute                                      | `05`                  |
| `m`            | 1–2 digit minute                                    | `5`                   |
| `ss`           | 2-digit second                                      | `09`                  |
| `s`            | 1–2 digit second                                    | `9`                   |
| `A`            | AM/PM uppercase                                     | `PM`                  |
| `a`            | am/pm lowercase                                     | `pm`                  |
| `ZZ`           | UTC offset `±HH:MM` (literal `Z` → `+00:00`)         | `+02:00`              |
| `EEEE`         | Full day name                                       | `Monday`              |
| `EEE`/`EE`/`E` | Short day name                                      | `Mon`                 |
| `e`            | Day of week as number (1=Mon … 7=Sun)               | `1`                   |
| `[text]`       | Literal string (escaped)                            | `[T]` → matches `T`   |
| `[*]`          | Wildcard — skip until next token                    | skips timezone suffix |

**Gotchas:**

- `mm` = minute, `MM` = month — easy to mix up
- `MMM` expects exactly 3 chars; `normalizeMonthAbbrev` in `expr.zig` pre-processes 4-char variants like `Sept`, `June`
- Pre-1970 dates are fully supported — `DATE_CONVERT` is a pure field reshuffle
  (parse → format) and never round-trips through a Unix epoch, so birthdates,
  census, and archival dates convert losslessly
- Range violations (month 13, Feb 30, hour 25, …) are rejected; the field then
  yields `""` silently, matching the blank-field passthrough contract
- Missing components (e.g. date-only format) default to 1970-01-01

## Conversion templates

| ID                           | data_dir                            | Input format                                                                                                                                                                                               |
| ---------------------------- | ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `revolutx_to_wealthfolio`    | `../data/revolutx_to_wealthfolio`   | `Symbol,Type,Quantity,Price,Value,Fees,Date` — date as `"26 Jun 2022, 16:02:36"`, prices with trailing `CZK` unit                                                                                          |
| `trading212_to_wealthfolio`  | `../data/trading212_to_wealthfolio` | `Action,Time,ISIN,Ticker,...` — Trading 212 export; multi-row expansion for Currency conversion, ADR Fee, Result/Dividend adjustment                                                                       |
| `anycoin_to_wealthfolio`     | `../data/anycoin_to_wealthfolio`    | `Date,Type,Amount,Currency,Order ID` — ISO datetime; paired rows (`trade payment` + `trade fill`) joined via `pre_pass` on `Order ID`                                                                      |
| `xtb1_closed_to_wealthfolio` | `xtb1_to_wealthfolio`               | xlsx sheet `CLOSED POSITION` (header row 13); file pattern `_closed.csv`; SELL; old XTB format                                                                                                             |
| `xtb1_cash_to_wealthfolio`   | `xtb1_to_wealthfolio`               | xlsx sheet `CASH OPERATION` (header row 11); file pattern `_cash.csv`; DIV/TAX/INTEREST/DEPOSIT + BUY from `Stock purchase` rows (qty+price from Comment via `SPLIT_PART`); old XTB format                 |
| `xtb2_closed_to_wealthfolio` | `xtb2_to_wealthfolio`               | xlsx sheet `Closed Positions` (header row 5); file pattern `_closed.csv`; SELL; new XTB format from 2026-07-01                                                                                             |
| `xtb2_cash_to_wealthfolio`   | `xtb2_to_wealthfolio`               | xlsx sheet `Cash Operations` (header row 5); file pattern `_cash.csv`; DIV/TAX/INTEREST/DEPOSIT + BUY from `Stock purchase` rows (qty+price from Comment via `SPLIT_PART`); new XTB format from 2026-07-01 |

## Output stream routing

bxp-cli splits its output across stdout and stderr by purpose, not by severity:

- **stdout** — machine-consumable: human-readable per-template `summary` lines,
  the final `overallLine`, and (in `--trace` mode) the binary BXTB frame stream.
- **stderr** — diagnostics: `fatal` errors, `warning` text, panics, usage errors.

Capture them separately. Piping `2>&1` interleaves them and breaks the BXTB
frame reader (the GUI parser requires clean stdout). `--trace` implies
`--quiet` so per-template summaries do not pollute the frame stream; warnings
still go to stderr in trace mode so a stderr badge can surface them in the GUI.

## Notes

- All code comments and documentation must be in English.
- User-facing error messages use `std.process.exit(1)` (no Zig stack trace).
- `BXP_METRICS` env var (opt-in, dev/bench): when set to any non-empty
  value, bxp-cli emits one `bxp-metrics wall_ms=<N> peak_rss_kb=<N>` line to
  **stderr** just before exit (wall via `std.Io.Clock.Timestamp`, peak RSS via
  `getrusage(RUSAGE_SELF)` on POSIX / `GetProcessMemoryInfo` on Windows).
  Lets `scripts/test-05-bench-guard.sh` + `scripts/bench/bench.sh` measure
  perf cross-platform without GNU `/usr/bin/time`. Off by default; never on
  stdout, so it doesn't disturb data/trace output. The self-handle is always
  valid, so no child-process plumbing is needed (`peakRssKb` in `main.zig`).
- `alloc` lifetime: `file_alloc` (ArenaAllocator) owns file content and parsed data,
  freed after each file. `line_alloc` (ArenaAllocator) is reset per row.
- Real input/output data lives in `../data/<template_id>/` and can be used for testing.
- Test data with expected outputs lives in `../datasets/<template_id>/`.
- CSV parser (the zig-libs `csvstream` module, driven by `pipeline.zig`) is RFC 4180
  compliant with two intentional deviations. First, a `\n` always ends a record —
  a quoted field may not span physical lines ("lazy quotes", à la Go
  `encoding/csv`), so a stray quote is a one-line problem and every `\n` is a
  safe boundary for the parallel chunk split. A record with an unbalanced quote
  is counted and warned about, not dropped. Second, leading/trailing spaces are
  trimmed from field values and header names (`expr.zig Context.field`,
  `pipeline.zig` header parsing). RFC 4180 §2 says spaces are part of the value; we trim them
  because broker exports frequently pad fields and downstream parsing (dates, numbers) requires clean values.
- A CSV input that never gives the streaming reader a line break to stop on is
  refused (`error.RecordTooLong` → a fatal naming the file). This is a **memory
  guard, not an exact record-size limit**: the check tests how much is already
  buffered *before* pulling the next 10 MB read, so the point at which a
  newline-free record trips it depends on where that record starts relative to a
  chunk boundary — the effective ceiling lands somewhere between 10 MB and
  roughly 20 MB. What is guaranteed is the property the diagnostic states ("no
  line break found in 10 MB of buffered input"): without it a newline-free file —
  including a bare-CR "classic Mac" export — would be buffered whole.

## Known non-issues — deliberately not refactored

Audit follow-up rationale captured here so future audits don't re-flag
the same observations. If the rationale stops applying, revisit.

- **No per-template "N expression errors" summary.** A previous audit
  proposed surfacing a count whenever `evalAllVars` / row_rules `when`
  / override eval / pre_pass eval silently substitutes `""`. Skipped
  after empirical check on the real DEV/ corpus (5 brokers, 42 files,
  5260 rows, ~70k variable evals): `var_error` count is **0**;
  `rule_no_match` with `error` field is **0**. The ~30k empty
  variable values that DO appear are entirely intentional —
  literal `''` overrides for non-applicable fields (e.g. deposit rows
  setting `$ticker: ''`), `IF(fee > 0, fee, '')` patterns explicitly
  emitting empty for "doesn't apply", and `PRICE_CURRENCY([Value])`
  on activity types where `[Value]` is genuinely absent. The audit
  conflated **silent type coercion** (a designed feature: empty
  fields → empty strings → `0` in numeric context) with **silent
  error suppression** (a hypothetical bug). They're not the same.
  A summary would either always print `0 errors` (useless noise)
  or — if we counted empty results — print 30k+ on every run as
  pure FUD against intentional emptiness.

- **`date_fast_path` does not count expr errors on date-filtered rows.**
  When `date_filter_from_filename` is on, `$date` is declared, and no
  `row_rules` overrides `$date`, the pipeline evaluates `$date` first and
  `return`s on an out-of-range row before `evalAllVars` (`pipeline.zig`
  `date_fast_path`). A broken non-`$date` expression on a row that is filtered
  out of the output therefore never bumps `file_expr_errors`, so it cannot flip
  the exit code to 2. This is intentional — a row that produces no output line
  should not affect the exit code — and is the single accounting difference
  from the pre-optimization slow path, which evaluated every row's vars (and
  counted their errors) before dropping the row in the late filter. Output is
  byte-identical; only the exit code on the broken-expr + filtered-out edge
  case differs. Confirmed acceptable in the 2026-06-05 audit.

- **The ~10 repeated fatal-exit epilogues in `run()` are left inline.** The
  block `overall.has_fatal = true; out.info("=== overall summary ===");
overall.time_ns = timer.read(); out.overallLine(overall); return
error.Fatal;` recurs ~10× and looks like pure duplication, but it sits
  alongside deliberate near-variants — usage errors (`unknown argument`,
  `--data requires --template`) exit fatal WITHOUT printing the summary, and
  the xlsx pre-pass path `merge`s stats before the same tail. A blanket
  `fatalEpilogue` helper would invite homogenising those intentional
  differences for a purely cosmetic line-count win in the control-flow
  function CLAUDE.md keeps deliberately linear. Considered and declined in the
  2026-06-05 audit.

- **(Resolved by the Zig 0.16 migration) `--version` / `--help` no longer pay a
  thread-pool startup cost.** The 2026-06-14 audit flagged that the old
  `pool.init(.{ .n_jobs = ncpu })` ran before the info-flag short-circuit, so
  `bxp-cli --version` spun up `ncpu` OS threads to print one line. The 0.16
  migration retired the explicit `std.Thread.Pool` for the `std.Io.Group` async
  model: `main()` now only calls `std.Thread.getCpuCount()` (spawns nothing) and
  stores `max_workers` in `Runtime`; worker tasks come from `io`'s pool lazily on
  the first `processBlockParallel`. The startup cost is gone — kept here so the
  old finding isn't re-raised.

- **`--data` / `--config` value-flags swallow a following flag token.**
  `matchValueArg`'s space form returns the next token verbatim with no
  "looks like a flag" check, so `--data --fresh` treats `--fresh` as the data
  dir → a confusing "directory not found: --fresh" instead of "--data needs a
  value". Same class as most hand-rolled parsers; a UX papercut, not a
  correctness bug. Not worth special-casing unless reported.

- **`validatePath` permits absolute paths and a single `..`.** It blocks shell
  metacharacters and `> 1` `..`, so `--data /tmp/out` or `--data ../foo` write
  outside the cwd subtree. This is correct for a user-run CLI with the user's
  own privileges (not a server boundary) and is required by the default
  `../data/...` layout. Noted only because the doc-comment frames it as a
  "path traversal" defense — the real, narrower guarantee is blocking injection
  chars + accidental deep traversal, which is the appropriate scope here.
