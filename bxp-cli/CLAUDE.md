# CLAUDE.md — bxp-cli

Guidance for Claude Code when working with the bxp-cli package.
For monorepo-level context see [`../CLAUDE.md`](../CLAUDE.md).

## Purpose

**bxp-cli** — Zig 0.15 CLI tool that converts broker export statements to Wealthfolio
format (`.csvx`) via JSON5 conversion templates. All broker logic is configuration-driven
(`bxp-cli.json`) — no compiled-in broker modules.

## Source layout

```text
bxp-cli/
  src/
    main.zig      ← CLI layer: arg parsing, config loading, dispatch
    pipeline.zig  ← Processing: processBroker(), xlsxPrePass(), helpers
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

# Suppress all output (exit code still reflects result)
./zig-out/bin/bxp-cli --quiet

# Skip files whose output already exists
./zig-out/bin/bxp-cli --fresh
```

Exit codes: `0` = success, `1` = error, `2` = warnings.

## Configuration (bxp-cli.json)

All broker logic is defined in `bxp-cli.json` — there are no compiled-in broker modules.

### Top-level fields

- `ticker_maps` — optional map of named, reusable ticker maps. Each entry is a map name → object
  (same structure as an inline `ticker_map`). Templates reference them by name via `"ticker_map": "name"`.
- `conversion_templates` — map of template ID → template config. At least one required.
- `data_dir` paths are relative to the `bxp-cli.json` location (i.e. `../data/...` for shared `data/` directory).

### Template config fields (key order convention)

```json
{
  "data_dir": "../data/<template_id>",
  "file_pattern_in": ".csv",
  "file_pattern_out": ".csvx",
  "date_filter_from_filename": false,
  "ticker_map": {},
  "xlsx_sheet": {},
  "pre_pass": {},
  "input_schema": {},
  "row_rules_debug_missing": false,
  "row_rules": [],
  "output_schema": {}
}
```

- `data_dir` — path to directory containing input CSV files.
- `file_pattern_in` — **required** — suffix filter for input files, e.g. `".csv"` for all CSV files,
  `"_3.csv"` to restrict to files ending in `_3.csv`.
- `file_pattern_out` — optional output filename suffix. Replaces `file_pattern_in` in the output
  filename (e.g. `"_cash.csv"` → `"_cash.csvx"`). Defaults to appending `"x"` when omitted.
- `date_filter_from_filename` — optional boolean (default `false`). When `true`, rows whose
  `$date` value falls outside the date range encoded in the filename (`YYYY-MM-DD_YYYY-MM-DD`)
  are silently skipped. Requires `$date` in `input_schema` — validated at startup.
- `ticker_map` — optional symbol remapping. Either an inline object `{ "BTC": "BTC-USD" }` or a
  string name referencing an entry in the top-level `ticker_maps` section (e.g. `"xtb"`).
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
  "ticker_map": {},
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
`unary -` → `* /` → `&` (concat) → `+ -` → `= != < > <= >=` → `AND` → `OR`

| Syntax | Description |
| --- | --- |
| `[ColumnName]` | Field value by CSV header name |
| `[n]` | Field value by 1-based column index |
| `FIELDS(n)` | Same as `[n]` but via function call |
| `'text'` | String literal |
| `IF(cond, yes, no)` | Short-circuit conditional |
| `ABS(f)` | Absolute numeric value |
| `DATE_CONVERT(f, from, to)` | Reformat date/time; format tokens use sunrise syntax (see section below) |
| `PRICE_VALUE(f)` | Strip currency symbol/code, return numeric string (`"24.00 CZK"` → `"24.00"`) |
| `PRICE_CURRENCY(f)` | Extract currency code (`"24.00 CZK"` → `"CZK"`, `"$100"` → `"USD"`) |
| `TICKER(f)` | Map field through broker's `ticker_map`; returns as-is if not found |
| `LOOKUP(key, 'field')` / `LOOKUP('name', key, 'field')` | Retrieve value from `pre_pass` table — 2-arg form for legacy single block, 3-arg form for named blocks |
| `SPLIT_PART(f, delim, n)` | Split `f` by `delim`, return nth part (1-based); `""` if fewer than n parts |
| `CONTAINS(f, sub)` | `true` when `sub` is found inside `f` |
| `REPLACE(f, old, new)` | Replace all occurrences of `old` with `new` in `f`; returns `f` unchanged if `old` is empty |
| `TRIM(f)` | Strip leading and trailing whitespace (space, tab, CR, LF) |
| `ROUND(f, n)` | Round `f` to `n` decimal places (`n` may be negative for tens/hundreds) |
| `FLOOR(f)` | Largest integer ≤ `f` |
| `CEILING(f)` | Smallest integer ≥ `f` |
| `NOW()` | Current UTC datetime as `"YYYY-MM-DDTHH:MM:SSZ"` |
| `RAND()` | Cryptographically random float in `[0, 1)` |
| `COALESCE(a, b, ...)` | Return first non-empty argument (empty = whitespace-only string; numbers/booleans are never empty). If all args are empty, returns the last arg verbatim — use `COALESCE(@a, @b, "0")` for a guaranteed default |

Type coercions: empty string → `0` in numeric context; any non-empty string → `true` in boolean context.

## sunrise date format tokens (v0.1.0)

Used in `DATE_CONVERT(f, from_fmt, to_fmt)`. Both `from_fmt` and `to_fmt` use the same token set.

| Token | Meaning | Example |
| --- | --- | --- |
| `YYYY` | 4-digit year | `2024` |
| `YY` | 2-digit year (00–69 → 2000–2069, 70–99 → 1970–1999) | `24` |
| `MM` | 2-digit month (01–12) | `03` |
| `M` | 1–2 digit month | `3` |
| `MMMM` | Full month name | `March` |
| `MMM` | 3-char month abbreviation | `Mar` |
| `DD` | 2-digit day (01–31) | `07` |
| `D` | 1–2 digit day | `7` |
| `hh` | 2-digit hour, **24h** (00–23) | `14` |
| `h` | 1–2 digit hour, 24h | `14` |
| `ii` | 2-digit hour, **12h** (01–12) | `02` |
| `i` | 1–2 digit hour, 12h | `2` |
| `mm` | 2-digit minute | `05` |
| `m` | 1–2 digit minute | `5` |
| `ss` | 2-digit second | `09` |
| `s` | 1–2 digit second | `9` |
| `A` | AM/PM uppercase | `PM` |
| `a` | am/pm lowercase | `pm` |
| `EEEE` | Full day name | `Monday` |
| `EEE`/`EE`/`E` | Short day name | `Mon` |
| `e` | Day of week as number (1=Mon … 7=Sun) | `1` |
| `[text]` | Literal string (escaped) | `[T]` → matches `T` |
| `[*]` | Wildcard — skip until next token | skips timezone suffix |

**Gotchas:**

- `mm` = minute, `MM` = month — easy to mix up
- `MMM` expects exactly 3 chars; `normalizeMonthAbbrev` in `expr.zig` pre-processes 4-char variants like `Sept`, `June`
- Parse rejects years before 1970 (`OutOfRange`)
- Missing components (e.g. date-only format) default to 1970-01-01

## Conversion templates

| ID | data_dir | Input format |
| --- | --- | --- |
| `revolutx_to_wealthfolio` | `../data/revolutx_to_wealthfolio` | `Symbol,Type,Quantity,Price,Value,Fees,Date` — date as `"26 Jun 2022, 16:02:36"`, prices with trailing `CZK` unit |
| `trading212_to_wealthfolio` | `../data/trading212_to_wealthfolio` | `Action,Time,ISIN,Ticker,...` — Trading 212 export; multi-row expansion for Currency conversion, ADR Fee, Result/Dividend adjustment |
| `anycoin_to_wealthfolio` | `../data/anycoin_to_wealthfolio` | `Date,Type,Amount,Currency,Order ID` — ISO datetime; paired rows (`trade payment` + `trade fill`) joined via `pre_pass` on `Order ID` |
| `xtb1_closed_to_wealthfolio` | `xtb1_to_wealthfolio` | xlsx sheet `CLOSED POSITION` (header row 13); file pattern `_closed.csv`; SELL; old XTB format |
| `xtb1_cash_to_wealthfolio` | `xtb1_to_wealthfolio` | xlsx sheet `CASH OPERATION` (header row 11); file pattern `_cash.csv`; DIV/TAX/INTEREST/DEPOSIT + BUY from `Stock purchase` rows (qty+price from Comment via `SPLIT_PART`); old XTB format |
| `xtb2_closed_to_wealthfolio` | `xtb2_to_wealthfolio` | xlsx sheet `Closed Positions` (header row 5); file pattern `_closed.csv`; SELL; new XTB format from 2026-07-01 |
| `xtb2_cash_to_wealthfolio` | `xtb2_to_wealthfolio` | xlsx sheet `Cash Operations` (header row 5); file pattern `_cash.csv`; DIV/TAX/INTEREST/DEPOSIT + BUY from `Stock purchase` rows (qty+price from Comment via `SPLIT_PART`); new XTB format from 2026-07-01 |

## Notes

- All code comments and documentation must be in English.
- User-facing error messages use `std.process.exit(1)` (no Zig stack trace).
- `alloc` lifetime: `file_alloc` (ArenaAllocator) owns file content and parsed data,
  freed after each file. `line_alloc` (ArenaAllocator) is reset per row.
- Real input/output data lives in `../data/<template_id>/` and can be used for testing.
- Test data with expected outputs lives in `../datasets/<template_id>/`.
- CSV parser (`csv.zig` + `main.zig`) is RFC 4180 compliant with one intentional deviation:
  leading/trailing spaces are trimmed from field values and header names (`expr.zig Context.field`,
  `main.zig` header parsing).  RFC 4180 §2 says spaces are part of the value; we trim them
  because broker exports frequently pad fields and downstream parsing (dates, numbers) requires clean values.
