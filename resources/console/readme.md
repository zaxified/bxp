# Broker eXchange Parser (BXP Console)

A CLI tool + FMT tool that converts broker export statements (CSV,
XLSX, JSON) into portfolio-tracker CSV formats using declarative JSON5
templates. [Wealthfolio](https://wealthfolio.app/) and
[brycht.app](https://brycht.app/) are the two trackers with shipping
templates today; any other tracker is reachable by writing an
`output_schema` for it — no code changes. Everything runs locally; your
data never leaves the machine.

The console package ships two binaries that work together:

- **`bxp-cli`** — the conversion engine. Produces the actual `.csvx`
  files from your broker exports and the JSON5 templates.
- **`bxp-fmt`** — companion validator and docs catalog: validates a
  config (`--config`), evaluates one expression against a sample row
  (`--expr-trace` / `--expr-batch`), and dumps the function / field
  reference (`--docs`). Use it to self-test a template before running it.

---

## Basic usage

### Three-step recipe

1. Drop the broker's export file into the template's `data_dir`.
2. Run `./bxp-cli --template <id>`.
3. Pick up the generated `*.csvx` file next to the input — ready to
   import into the tracker the template targets (Wealthfolio for
   `*_to_wealthfolio`, brycht.app for `*_to_brychtapp`).

### Built-in templates

| Template ID | Broker |
| --- | --- |
| `revolutx_to_wealthfolio` | Revolut X (crypto) |
| `trading212_to_wealthfolio` | Trading 212 |
| `anycoin_to_wealthfolio` | Anycoin (crypto) |
| `xtb1_closed_to_wealthfolio` | XTB — closed positions (old) |
| `xtb1_cash_to_wealthfolio` | XTB — cash operations (old) |
| `xtb2_closed_to_wealthfolio` | XTB — closed positions (new) |
| `xtb2_cash_to_wealthfolio` | XTB — cash operations (new) |
| `trading212_to_brychtapp` | Trading 212 → brycht.app (tracker) |
| `xtb2_cash_to_brychtapp` | XTB — cash operations (new) → brycht.app (tracker) |
| `xtb2_closed_to_brychtapp` | XTB — closed positions (new) → brycht.app (tracker) |

### `bxp-cli` reference

All flags are optional. Without arguments, bxp-cli reads `bxp-cli.json`
from the current directory and processes every template in it.

| Flag | Argument | What it does |
| --- | --- | --- |
| `--config <file>` | path | Use a specific config file. Default: `./bxp-cli.json` in the current directory. |
| `--template <id>` | template id | Process only the named template. Without it, all templates run. |
| `--data <dir>` | directory path | Override the template's `data_dir`. Useful for testing with files in a different location. |
| `--debug` | — | Print rows no `row_rules` entry matched (when `row_rules_debug_missing: true`). JSON on stdout. |
| `--quiet` | — | Suppress per-template summaries. Exit code still reflects success / warnings / failure. |
| `--fresh` | — | Skip files whose output already exists. Useful when re-running on a folder where some `.csvx` files are already produced. |
| `--check-fs=N` | seconds (0–60) | Run extra filesystem-existence checks (verifies `data_dir`, etc.). `N` is the deadline in seconds — `0` skips entirely (default). |
| `--version` | — | Print the binary version to stdout and exit. |
| `--help` | — | Print the built-in help to stdout and exit. |

```bash
./bxp-cli --help                                  # print usage
./bxp-cli                                         # process all templates from bxp-cli.json
./bxp-cli --template <id>                         # process a single template
./bxp-cli --template <id> --data ./my-data/       # override data_dir for that template
```

### `bxp-fmt` reference

bxp-fmt is a small validator / catalog binary that ships alongside
bxp-cli. Each invocation runs exactly one action — subcommands are
mutually exclusive.

| Subcommand | Output | Purpose |
| --- | --- | --- |
| `--config <file>` | annotated JSON on stdout | Validate config, return tree with `$err_*` / `$warn_*` / `$info_*` / `$comm_*` siblings. Exit `1` on validation error, `0` on success. |
| `--config <file> --list-templates` | JSON array on stdout | List every template id declared in the config. |
| `--config <file> --fetch-template <id>` | JSON on stdout | Return the raw JSON5 block of one template. |
| `--expr '<text>'` | empty on stdout, `{error,detail,off,len}` on stderr | One-shot expression syntax / static check. Exit `1` on error. |
| `--expr-trace '<text>'` | NDJSON stream on stdout | Run an expression with optional row context and emit per-call trace events. Combine with `--row-headers '<json>'` and `--row-fields '<json>'`. |
| `--docs` | JSON on stdout | Full FnDoc / FieldDoc catalog (single source for the GUI's autocomplete). |
| `--check-fs=N` | (modifier on `--config`) | Add filesystem-existence checks to `--config`; `N` is the deadline in seconds. |
| `--version` | — | Print version to stdout. |
| `--help` | — | Print help to stdout. |

```bash
# Validate one expression in isolation:
./bxp-fmt --expr "IF([Qty] > 0, 'BUY', 'SELL')"

# Trace an expression against a fake row:
./bxp-fmt --expr-trace "[Price] * [Qty]" \
    --row-headers '["Price","Qty"]' \
    --row-fields  '["12.50","100"]'

# Pretty-print the full schema catalog:
./bxp-fmt --docs | jq '.config_schema'

# List templates a config defines:
./bxp-fmt --config ~/my-bxp-cli.json --list-templates
```

### Exit codes

| Binary | Code | Meaning |
| --- | --- | --- |
| bxp-cli | `0` | Success — all matched rows converted, no warnings. |
| bxp-cli | `1` | Fatal error — config invalid, file missing, expression failure. |
| bxp-cli | `2` | Completed with warnings — output written but at least one warning emitted (typo'd field, no input rows, …). |
| bxp-fmt | `0` | Success. |
| bxp-fmt | `1` | Validation / runtime error. |
| bxp-fmt | `2` | Usage error (unknown flag, missing argument, mutually-exclusive flags). |

### Where output goes

- **stdout** — per-template summaries, the final overall line, and
  (in `--debug`) JSON dumps of unmatched rows.
- **stderr** — fatal errors and warning text. Pipe `2>/dev/null` to
  silence warnings while still capturing exit code.

Don't pipe `2>&1` if you intend to feed stdout to another tool —
bxp-cli's streaming output assumes stdout and stderr stay separate.

---

## Need a broker that isn't listed?

**Ask your AI assistant.** bxp-cli templates are plain JSON5 — a capable
AI (Claude, ChatGPT, …) can write one for you. **Two files are required
context:** this `readme.md` AND `bxp-cli.examples.json` (also at the
project's GitHub repository). The readme defines the language and the
target output spec; the examples.json carries working per-broker
patterns the AI is expected to pattern-match against. If the AI doesn't
have examples.json, it will refuse to guess.

Paste this prompt into your assistant, attach both files, then drop in
5 rows of your broker's raw CSV:

> *"I use BXP. Please read the **Advanced usage** section of `readme.md`
> and the comments in `bxp-cli.examples.json`. Here is a sample of my
> broker's export: `<paste 5 rows including the header>`. Add a new
> entry under `conversion_templates` in my `bxp-cli.json` that converts
> this to Wealthfolio CSV, following the same patterns as the existing
> templates. Follow the rules in the 'Rules for an AI assistant'
> section: self-test your output (`bxp-fmt --config` + `bxp-cli
> --debug`) before returning, return JSON5 with `//` comments
> explaining non-obvious decisions, and end your reply with a 'Things
> to check in bxp-gui' list for anything you couldn't fully verify."*

---

## Advanced usage

This section is written so that a capable AI assistant can produce a
working broker template given only this file and `bxp-cli.examples.json`.
It is also useful as a human reference.

### Architecture in one paragraph

bxp-cli is a two-pass declarative data pipeline. Pass one (optional
`pre_pass`) scans all rows and builds a lookup table for cross-row
joins. Pass two iterates rows, evaluates `input_schema` expressions
into per-row `$variable`s, then routes each row through the ordered
`row_rules` list — the first matching rule decides the row's activity
type and whether it produces 0, 1, or N output rows. `output_schema`
then projects the final `$variable`s into CSV columns in a fixed order.
Input may be CSV, XLSX, or JSON; output is RFC 4180–compliant CSV or
JSON.

### `bxp-cli.json` layout

```json5
{
  ticker_maps: {
    // optional; named, reusable symbol remapping tables
    // map_name → { broker_symbol: yahoo_symbol, ... }
    // templates reference a map by name or define one inline
    anycoin:  { "BTC": "BTC-EUR" },
    revolutx: { "BTC": "BTC-USD" },
  },
  conversion_templates: {
    // required; map of template_id → template config (see skeleton below)
    mybroker_to_wealthfolio: { /* ... */ },
  },
}
```

All `data_dir` paths are resolved relative to the location of
`bxp-cli.json`.

### Blank template skeleton (copy, fill in, run)

```json5
mybroker_to_wealthfolio: {

  // required; path to input files, relative to bxp-cli.json
  data_dir:                  "mybroker_to_wealthfolio",

  // default "csv"; options: "csv", "json" (array-of-objects)
  file_type_in:              "csv",
  file_type_out:             "csv",

  // required; suffix filter for input files, e.g. ".csv" / "_closed.csv"
  file_pattern_in:           ".csv",
  // required; suffix of output filename, replaces file_pattern_in
  file_pattern_out:          ".csvx",

  // input CSV parsing — match the broker's actual format
  csv_delimiter_in:          ",",       // ",", ";", "\t", "|", ...
  csv_decimal_separator_in:  ".",       // ".", ","
  csv_text_quote_in:         "double",  // "none" | "single" ' | "double" "

  // output CSV formatting
  csv_delimiter_out:         ",",
  csv_decimal_separator_out: ".",
  csv_text_quote_out:        "none",

  // default false; when true rows whose $date is outside the date range encoded
  // in the filename (YYYY-MM-DD_YYYY-MM-DD) are silently skipped. Requires $date.
  date_filter_from_filename: false,

  // default false; when true all input files also write to a merged
  // 1-{template_id}-combined{file_pattern_out} file in data_dir
  // combined_output:              false,

  // optional; either a name from top-level ticker_maps, or an inline object
  ticker_map:                { /* "BROKER-SYM": "YAHOO-SYM" */ },

  // optional; xlsx sheet extraction — omit for plain CSV input
  // xlsx_sheet: { name: "CLOSED POSITION", header_row: 13, output_suffix: "_closed" },

  // optional; first-pass lookup table for cross-row joins (e.g. paired trade rows)
  // pre_pass: {
  //   when:   "[Type] = 'trade payment'",    // which rows to collect
  //   key:    "[Order ID]",                  // expression used as lookup key
  //   values: {                              // plain field names (no $ prefix)
  //     amount:   "ABS([Amount])",
  //     currency: "[Currency]",
  //   },
  // },

  // required; $variable definitions evaluated once per input row.
  // [Column Name] = raw CSV field by header; [n] = field by 1-based index.
  input_schema: {
    $date:           "DATE_CONVERT([Date], 'DD/MM/YYYY hh:mm:ss', 'YYYY-MM-DD hh:mm:ss')",
    $ticker:         "TICKER([Symbol])",
    $quantity:       "[Quantity]",
    $unitprice:      "[Price]",
    $currency:       "[Currency]",
    $fee:            "[Fee]",
    $amount:         "[Total]",
    $account:        "",      // optional; e.g. "'MyBroker'", "[Account]"
    $fxRate:         "",      // optional
    $subtype:        "",      // optional
    $instrumentType: "",      // optional; e.g. "'Cryptocurrency'"
    $comment:        "",      // optional
  },

  // default false; unmatched rows are printed with --debug when true
  row_rules_debug_missing: true,

  // ordered list — first match wins. rows: [] = silent skip.
  // $action MUST be set here, never in input_schema.
  row_rules: [
    { when: "[Action] = 'Buy'",      rows: [ { $action: "'BUY'"  } ] },
    { when: "[Action] = 'Sell'",     rows: [ { $action: "'SELL'" } ] },
    { when: "[Action] = 'Deposit'",  rows: [ { $action: "'DEPOSIT'"  } ] },
    { when: "[Action] = 'Withdraw'", rows: [ { $action: "'WITHDRAWAL'" } ] },
    // ignored row types go here with rows: []
  ],

  // required; output CSV header → $variable. Controls columns and their order.
  output_schema: {
    date:           "$date",
    symbol:         "$ticker",
    quantity:       "$quantity",
    activityType:   "$action",
    unitPrice:      "$unitprice",
    currency:       "$currency",
    fee:            "$fee",
    amount:         "$amount",
    account:        "$account",
    fxRate:         "$fxRate",
    subtype:        "$subtype",
    instrumentType: "$instrumentType",
    comment:        "$comment",
  },
},
```

### Template field reference

| Field | Type | Required | Default | Purpose |
| --- | --- | --- | --- | --- |
| `data_dir` | string | yes | — | Directory with input files; relative to `bxp-cli.json` |
| `file_type_in` | string | no | `"csv"` | `"csv"` or `"json"` (array-of-objects) |
| `file_type_out` | string | no | `"csv"` | `"csv"` or `"json"` |
| `file_pattern_in` | string | yes | — | Suffix filter, e.g. `".csv"`, `"_closed.csv"` |
| `file_pattern_out` | string | no | append `x` | Replaces `file_pattern_in` in output filename |
| `csv_delimiter_in` | string | no | `","` | Field separator of input CSV |
| `csv_delimiter_out` | string | no | `","` | Field separator of output CSV |
| `csv_decimal_separator_in` | string | no | `"."` | Decimal separator in numeric fields (input) |
| `csv_decimal_separator_out` | string | no | `"."` | Decimal separator in numeric fields (output) |
| `csv_text_quote_in` | string | no | `"double"` | `"none"`, `"single"` (`'`), or `"double"` (`"`) |
| `csv_text_quote_out` | string | no | `"none"` | Same values as `csv_text_quote_in` |
| `csv_header_line` | number | no | `1` | 1-based line of the CSV header. `0` = headerless (first line is data, columns reachable only by `FIELDS(n)`); `N>1` skips `N-1` preamble lines. CSV input only |
| `date_filter_from_filename` | bool | no | `false` | Filter rows by `YYYY-MM-DD_YYYY-MM-DD` range in filename |
| `ticker_map` | string \| object | no | `{}` | Name from `ticker_maps`, or inline `{ "SYM": "YAHOO" }` |
| `xlsx_sheet` | object | no | — | `{ name, header_row, output_suffix }` — convert xlsx before CSV |
| `pre_pass` | object | no | — | `{ when, key, values }` — first-pass lookup table |
| `input_schema` | object | yes | — | `$variable` → expression, evaluated per row |
| `row_rules_debug_missing` | bool | no | `false` | Print unmatched rows with `--debug` |
| `row_rules` | array | yes | — | Ordered routing rules; first match wins |
| `output_schema` | object | yes | — | Output CSV header → `$variable`; defines column order |
| `combined_output` | bool | no | `false` | When `true`, all input files additionally write rows to one merged file `1-{template_id}-combined{file_pattern_out}` in `data_dir`, alongside the normal per-file outputs |

### Standard `$variable` reference

Output `$variable`s that bxp-cli's Wealthfolio templates set. The first
eight map 1:1 to Wealthfolio's import columns; the rest are optional.

| Variable | Meaning |
| --- | --- |
| `$date` | Transaction datetime, format `YYYY-MM-DD hh:mm:ss` |
| `$ticker` | Yahoo Finance ticker (after `TICKER()` mapping) |
| `$quantity` | Number of units |
| `$unitprice` | Price per unit |
| `$currency` | Currency code (`USD`, `EUR`, `CZK`, …) |
| `$fee` | Fee amount (empty if broker does not report one) |
| `$amount` | Total transaction value |
| `$action` | Activity type — **set only in `row_rules`**, never in `input_schema` |
| `$account` | Account tag (optional) |
| `$fxRate` | FX rate (optional) |
| `$subtype` | Wealthfolio subtype (optional) |
| `$instrumentType` | e.g. `'Cryptocurrency'` (optional) |
| `$comment` | Free-form comment (optional) |

Typical `$action` values for Wealthfolio: `'BUY'`, `'SELL'`, `'DEPOSIT'`,
`'WITHDRAWAL'`, `'DIVIDEND'`, `'TAX'`, `'INTEREST'`, `'FEE'`. An empty
`""` expression omits the variable from output.

### Expression language — full reference

Expressions are strings evaluated once per row. Operator precedence,
high → low:

```text
unary -    →    * /    →    & (concat)    →    + -    →    = != < > <= >=    →    NOT    →    AND    →    OR
```

#### Column and literal syntax

| Syntax | Description |
| --- | --- |
| `[ColumnName]` | Raw CSV field by header name (leading/trailing spaces trimmed) |
| `[n]` | Raw CSV field by 1-based column index |
| `'text'` | String literal |
| `123`, `-0.5` | Numeric literal |
| `&` | String concatenation (`'$CASH-' & [Currency]`) |
| `$variable` | Reference to a variable set earlier in `input_schema` |

Column header names may contain spaces, parentheses, currency symbols,
and other punctuation — `[Price ($)]`, `[Run Date]`, and
`[Stamp duty reserve tax]` are all valid references. The bracket
syntax preserves the header verbatim; only the closing `]` itself is
reserved.

**Built-in functions** (all names are case-insensitive)

| Function | Returns | Description |
| --- | --- | --- |
| `IF(cond, yes, no)` | any | Short-circuit conditional; only the selected branch is evaluated |
| `ABS(x)` | number | Absolute numeric value |
| `ROUND(x, n)` | number | Round `x` to `n` decimal places (negative `n` rounds tens/hundreds) |
| `FLOOR(x)` | number | Largest integer ≤ `x` |
| `CEILING(x)` | number | Smallest integer ≥ `x` |
| `TRIM(s)` | string | Strip leading/trailing whitespace |
| `REPLACE(s, old, new)` | string | Replace all occurrences of `old` with `new`; if `old` is empty, returns `s` |
| `SPLIT_PART(s, delim, n)` | string | Split `s` by `delim`, return 1-based nth part; `""` if out of range |
| `CONTAINS(s, sub)` | bool | `true` when `sub` is found inside `s` |
| `PRICE_VALUE(s)` | string | Strip currency symbol/code: `"24.00 CZK"` → `"24.00"`, `"$100"` → `"100"` |
| `PRICE_CURRENCY(s)` | string | Extract ISO currency: `"24.00 CZK"` → `"CZK"`, `"$100"` → `"USD"` |
| `TICKER(s)` | string | Map `s` through the template's `ticker_map`; pass through if not found |
| `DATE_CONVERT(s, from, to)` | string | Parse `s` using `from` format, emit using `to` format (tokens below) |
| `LOOKUP(key, 'field')` | string | Retrieve a value stored by `pre_pass` under `key` / `field` |
| `FIELDS(n)` | string | Same as `[n]` — raw field by 1-based index |
| `NOW()` | string | Current UTC datetime, format `YYYY-MM-DDTHH:MM:SSZ` |
| `RAND(n)` | string | `n` random digits (first 1–9, rest 0–9); `n` clamped to 1–65 |
| `COALESCE(a, b, ...)` | any | First non-empty argument (empty = whitespace-only string); falls back to last arg verbatim if all empty |
| `LEFT(s, n)` | string | First `n` bytes of `s` (`n` clamped to `[0, len]`; negative / non-finite → `""`) |
| `RIGHT(s, n)` | string | Last `n` bytes of `s` (same clamping) |
| `SUBSTR(s, start, len)` | string | `len` bytes from 1-based `start`; non-positive / non-finite `start` or `len` → `""` |
| `UPPER(s)` / `LOWER(s)` | string | Full-Unicode case conversion (`café`→`CAFÉ`, `ß`→`SS`, `я`→`Я`); unicameral scripts (CJK/Arabic/Hebrew) and invalid UTF-8 bytes pass through unchanged |
| `LEN(s)` | number | Byte length of `s` (UTF-8 byte count, not codepoints); empty → `0` |
| `STARTS_WITH(s, prefix)` | bool | `true` when `s` begins with `prefix` (case-sensitive); empty `prefix` always matches |
| `ENDS_WITH(s, suffix)` | bool | `true` when `s` ends with `suffix` (case-sensitive); empty `suffix` always matches |
| `IN(value, v1, v2, ...)` | bool | `true` when `value` equals any of `v1, v2, …` — variadic equality OR-chain |
| `NULLIF(value, sentinel)` | any | `""` when `value` = `sentinel`, else `value`; collapses sentinels (`-9999`, `\N`, `N/A`) |
| `GREATEST(a, b, ...)` | number | Largest numeric value among args — per-row maximum, not cross-row aggregation |
| `LEAST(a, b, ...)` | number | Smallest numeric value among args — per-row minimum |

**Date arithmetic functions** — all take/return ISO `YYYY-MM-DD` strings; an empty date arg yields `""`, a malformed one errors. Pre-1970 dates fully supported.

| Function | Returns | Description |
| --- | --- | --- |
| `DATEADD(d, n)` | string | Add `n` calendar days to `d` (negative subtracts) |
| `DATEDIFF(d1, d2)` | number | Calendar days from `d2` to `d1` (positive when `d1` is later) |
| `WORKDAY(d, n)` | string | Add `n` business days to `d`, skipping Sat/Sun (negative subtracts); `n=0` returns `d`. No exchange-holiday awareness |
| `YEAR(d)` / `MONTH(d)` / `DAY(d)` | number | Year / month (1–12) / day-of-month (1–31) component of `d` |
| `WEEKDAY(d)` | number | ISO day-of-week (Mon=1 … Sun=7); weekend trade = `WEEKDAY([Date]) > 5` |
| `EOMONTH(d)` | string | Last calendar day of `d`'s month (month-end snapping) |
| `NTH_DOW(year, month, weekday, n)` | string | Date of the `n`-th `weekday` (Mon=1 … Sun=7) in `year`/`month`; negative `n` counts from month end (`-1` = last); `""` if it doesn't exist. EU DST = `NTH_DOW(YEAR(d), 3, 7, -1)` … `NTH_DOW(YEAR(d), 10, 7, -1)` |

#### Function semantics — common gotchas

- **`CONTAINS(s, sub)` is a substring match, not a prefix match.** It
  returns `true` whenever `sub` appears *anywhere* inside `s`, which
  means `CONTAINS('Sell to Buy', 'Buy')` is `true`. Brokers with
  prefix-based action codes (Schwab `MKT BUY` / `LMT BUY`, IBKR
  multi-word actions) need an exact or word-boundary check: prefer
  exact comparison (`[Action] = 'Buy'`), `SPLIT_PART([Action], ' ', 1) = 'Buy'`
  for the first word, or stack `CONTAINS` checks to exclude false
  matches (`CONTAINS([Action], 'Buy') AND NOT CONTAINS([Action], 'Sell')`
  is not yet expressible — use a more specific positive match instead).
- **`SPLIT_PART(s, delim, n)` is 1-based and returns `""` on out-of-range.**
  Out-of-range never errors — silent empty makes it safe to chain but
  hides off-by-one bugs. Trace the variable in `bxp-gui` if the output
  is empty unexpectedly.

#### Type coercions

- Empty string → `0` in a numeric context.
- Any non-empty string → `true` in a boolean context; empty string → `false`.
- Numeric strings are parsed on demand; `csv_decimal_separator_in` controls which decimal separator is accepted.
- American thousands-separated numbers (`1,234.56`, `-1,234,567`) are automatically parsed in arithmetic contexts; the original string is preserved when the field is passed through as-is to output.

#### Minimal examples

```text
'$CASH-' & [Currency]                                          → string concat
IF([Type] = 'Buy', 'BUY', IF([Type] = 'Sell', 'SELL', ''))     → nested conditional
[Action] = 'Buy' OR CONTAINS([Action], 'Buy to')               → match action variants
ROUND(ABS([Total]) / [Quantity], 4)                            → derived unit price
DATE_CONVERT([Date], 'DD/MM/YYYY hh:mm:ss', 'YYYY-MM-DD hh:mm:ss')
LOOKUP([Order ID], 'amount') / [Amount]                        → cross-row join via pre_pass
PRICE_VALUE([Price])                                           → strip currency symbol
SPLIT_PART([Comment], ' @ ', 2)                                → second part after " @ "
[Commission ($)] + [Fees ($)]                                  → sum two raw numeric columns
```

### Date format tokens

Both the `from` and `to` arguments of `DATE_CONVERT` use the same token
set. Any characters that are not tokens are matched literally.

| Token | Meaning | Example |
| --- | --- | --- |
| `YYYY` | 4-digit year | `2026` |
| `YY` | 2-digit year (00–69 → 2000s, 70–99 → 1970s) | `26` |
| `MM` | 2-digit month (01–12) | `03` |
| `M` | 1–2 digit month | `3` |
| `MMMM` | Full month name | `March` |
| `MMM` | 3-char month abbreviation | `Mar` |
| `DD` | 2-digit day | `07` |
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
| `e` | Day of week as number (1 = Mon … 7 = Sun) | `1` |
| `[text]` | Literal text (escaped inside format string) | `[T]` → `T` |
| `[*]` | Wildcard — skip until the next token | skips `Z`, timezone suffix, etc. |

#### Gotchas

- `mm` is minute; `MM` is month — easy to mix up.
- `MMM` expects exactly 3 characters; 4-character variants like `Sept`
  and `June` are pre-normalized automatically.
- Dates before 1970 are fully supported — birthdates, census, and
  archival dates convert losslessly.
- Components not present in the `from` format default to `1970-01-01 00:00:00`.

#### Worked date examples

```text
"26 Jun 2022, 16:02:36"       →  'DD MMM YYYY, hh:mm:ss'
"2024-02-23T06:20:20.182Z"    →  'YYYY-MM-DDThh:mm:ss[*]'   (skips .182Z)
"07/03/2026 14:05:00"         →  'DD/MM/YYYY hh:mm:ss'
"2026-01-05 05:20:18"         →  'YYYY-MM-DD hh:mm:ss'      (canonical output)
```

### `pre_pass` — cross-row joins

Use `pre_pass` when an input row needs data that lives on **another
row** (for example, Anycoin writes `trade payment` and `trade fill` as
two rows sharing an `Order ID`). bxp-cli makes a first pass over the
file, collects rows matching `when`, and stores `values` under `key`.
Then `input_schema` can read them via `LOOKUP(key, 'field')`.

```json5
pre_pass: {
  when:   "[Type] = 'trade payment'",      // which rows to collect
  key:    "[Order ID]",                    // expression used as the lookup key
  values: {
    amount:   "ABS([Amount])",             // accessed as LOOKUP(..., 'amount')
    currency: "[Currency]",                // accessed as LOOKUP(..., 'currency')
  },
},

input_schema: {
  $unitprice: "LOOKUP([Order ID], 'amount') / [Amount]",
  $currency:  "LOOKUP([Order ID], 'currency')",
},
```

Note: keys inside `values` are **plain field names**, not `$variables`,
and they are not visible to `row_rules` or `output_schema` directly —
only through `LOOKUP()`.

### Wealthfolio target spec

The output `.csvx` is consumed by Wealthfolio. The conventions below
are enforced by the existing built-in templates and are the canonical
reference for new templates — Wealthfolio itself does not ship a
machine-readable spec, so "what the existing templates do" is the
de-facto contract.

**Sign conventions.** All three numeric variables are always positive;
direction (buy vs sell, deposit vs withdrawal) is encoded in `$action`,
not in the sign of the amount.

| Variable | Convention |
| --- | --- |
| `$amount` | Always positive — wrap raw broker values in `ABS()` if your broker reports signed values. |
| `$quantity` | Always positive — `ABS()` if needed. |
| `$fee` | Always positive (a cost). `ABS()` if needed. |

**Activity-type vocabulary.** `$action` is set inside `row_rules`.
Eight values cover every event the built-in templates emit:

| Action | When |
| --- | --- |
| `'BUY'` | Buy / acquisition |
| `'SELL'` | Sell / disposal |
| `'DEPOSIT'` | Cash deposit into the account |
| `'WITHDRAWAL'` | Cash withdrawal |
| `'DIVIDEND'` | Dividend received |
| `'TAX'` | Tax withheld |
| `'INTEREST'` | Interest paid (e.g. on cash balance) |
| `'FEE'` | Fee charged (e.g. monthly account fee, ADR fee) |

Three additional values handle portfolio bookkeeping events that
Wealthfolio also imports:

| Action | When |
| --- | --- |
| `'TRANSFER_IN'` | Stock moved into the account from elsewhere (zero-cost arrival) |
| `'TRANSFER_OUT'` | Stock moved out of the account to elsewhere |
| `'SPLIT'` | Stock split — `$amount` carries the split ratio (e.g. `2` for 2-for-1) |

If your broker emits an event that doesn't fit any of these, prefer
`'INTEREST'` for income-like cash, `'FEE'` for cost-like cash, and skip
the row (`rows: []`) if you can't classify it cleanly.

**Non-trade row patterns.** Cash events (DEPOSIT, WITHDRAWAL, INTEREST,
FEE, and DIVIDEND on a balance without a ticker) don't have a
meaningful symbol or unit price. The existing templates demonstrate
two valid patterns — pick the one that matches your broker, do not
invent a third:

- **Centralised in `input_schema`** (Anycoin, Revolut X, XTB cash) —
  `IF([type] = 'cash', '$CASH-XXX', TICKER([Symbol]))` style branching
  at variable definition time. `row_rules` then only sets `$action`.
  Compact when most cash events take the same shape and the input has a
  single column that distinguishes cash from stock rows.
- **Per-rule overrides** (Trading 212) — `input_schema` defines
  defaults that work for the trade rows, then individual
  `row_rules[].rows[]` entries clear or override `$variables` per
  event type (e.g. `$quantity: ""`, `$unitprice: ""` for a deposit;
  three different `rows` for a currency conversion). Verbose but
  flexible when different cash events need different shapes or when
  one input row must produce multiple output rows.

**Required vs optional output columns.**

| Required | Optional |
| --- | --- |
| `date`, `symbol`, `quantity`, `activityType`, `unitPrice`, `currency`, `fee`, `amount` | `account`, `fxRate`, `subtype`, `instrumentType`, `comment` |

**Date format.** `$date` should be `YYYY-MM-DD hh:mm:ss`. Brokers that
report date-only (no time) result in `... 00:00:00` — that's accepted.

### Locale-aware number parsing (European brokers)

European brokers (Comdirect, DKB, Flatex, BoursoBank, Fineco, …)
typically export numbers with `.` as thousands separator and `,` as
decimal: `5.000,00` means five thousand. Setting
`csv_decimal_separator_in: ","` opts the template into EU parsing,
and field access converts both shapes automatically:

| Raw field value      | Converted     | Reason                                  |
| -------------------- | ------------- | --------------------------------------- |
| `75,00`              | `75.00`       | Plain decimal, comma swapped            |
| `1234,56`            | `1234.56`     | Plain decimal, comma swapped            |
| `1.234,56`           | `1234.56`     | EU thousands group + decimal            |
| `-1.234.567,89`      | `-1234567.89` | Multiple thousands groups               |
| `1.234`              | `1234`        | EU thousands without decimal            |
| `1.5`                | `1.5`         | `.` not followed by 3 digits → left raw |
| `N/A`, `hello,world` | unchanged     | Non-numeric, left raw                   |

Expressions receive numeric fields ready to feed into arithmetic; no
defensive `IF(CONTAINS(...), REPLACE(...), ...)` wrapper needed.

US-style brokers (Schwab, Fidelity, Trading 212) use `.` decimal +
optional `,` thousands — that path is handled automatically (see
"American thousands-separated numbers" in the type-coercion notes).

### Rules for an AI assistant adding a new broker

If you are an AI assistant reading this section to generate a new
template, follow these rules strictly:

1. **`bxp-cli.examples.json` is required context.** It contains twelve
   working templates with rich inline comments. **If you don't have it
   in your context, ask the user to provide it before generating any
   template — do not guess at non-trade row patterns, action vocabulary,
   or broker quirks.** Pattern-match against the closest existing
   template (simple stock broker → Revolut X; paired rows → Anycoin;
   xlsx source → XTB; brycht.app tracker-mode → trading212_to_brychtapp).
2. **Add, do not modify.** Insert a new entry under
   `conversion_templates` in the user's `bxp-cli.json`. Never rewrite
   existing templates unless the user explicitly asks.
3. **Match the real CSV format.** Look at the sample header and first
   data row the user provided. Set `csv_delimiter_in`,
   `csv_decimal_separator_in`, and `csv_text_quote_in` to match what
   the broker actually exports — do not guess.
4. **Put activity-type logic in `row_rules`, not `input_schema`.**
   `$action` must be assigned inside a `row_rules[].rows[]` entry
   (e.g. `$action: "'BUY'"`). The `input_schema` only extracts and
   transforms neutral values.
5. **Use `pre_pass` only for cross-row joins.** If one input row needs
   a value from another row (paired transaction legs, fee refunds,
   order/fill pairs), use `pre_pass` and `LOOKUP`. Otherwise omit it
   entirely.
6. **Prefer named `ticker_map`s.** If the broker's symbols overlap an
   existing named map (e.g. `xtb`, `trading212`), reference it by name.
   Otherwise define a small inline map.
7. **One-to-many rows.** When one input row must produce multiple
   output rows (currency conversion = FEE + WITHDRAWAL + DEPOSIT;
   dividend with tax; split fees), return multiple objects in the same
   `row_rules[].rows` array. Each object can override `$variables` for
   that specific output row.
8. **Match the broker's exact date shape.** Use `DATE_CONVERT` with
   date-format tokens that correspond to the input literally,
   character-by-character; use `[*]` to skip fractional seconds,
   trailing `Z`, or timezone suffixes.
9. **Prices with embedded currency.** For fields like `"$100.00"` or
   `"24.00 CZK"`, use `PRICE_VALUE()` for the number and
   `PRICE_CURRENCY()` for the ISO code.
10. **Empty values.** Set a `$variable` to `""` to leave that output
    column blank. Drop a column from `output_schema` entirely to
    remove it.
11. **Enable debug during development.** Set `row_rules_debug_missing:
    true` and run with `--debug` (CLI) or `dry-run` (GUI) so any
    unmatched rows surface.
12. **Self-test before returning.** See the **Self-testing the
    generated template** section below — predict each sample row's
    outcome, then verify with `bxp-fmt --config` (validation),
    `bxp-fmt --expr-trace` (per-expression values), and `bxp-cli
    --debug` (problems). Only return the template once `--debug` is
    silent and the generated `.csvx` matches every prediction.

13. **Return a commented JSON5, not bare JSON.** JSON5 supports `//`
    comments — use them to explain non-obvious decisions: why a
    particular date-format token was chosen, why a `pre_pass` was
    needed, why a row type is skipped, why a workaround like the
    European number-parsing branch is present. The user reads your
    output as documentation; future-you (or another AI) reads it to
    extend the template later.

14. **Hand off the unfinished business in plain language.** When you
    leave gaps the user must verify or finish in the GUI (the
    template generation isn't always complete on the first pass —
    Wealthfolio import quirks, exotic rows you couldn't classify,
    broker-specific edge cases), end your reply with a numbered
    "things to check in bxp-gui" list. See **Handing off to the
    user** below for what each instruction should contain.

### Handing off to the user (GUI-driven debug)

The user is non-technical and is following your natural-language
instructions. After you return the JSON, append a section like this
when there's anything left to verify:

```text
## Things to check in bxp-gui

1. **Open** your `bxp-cli.json` (Ctrl+O), select the new template
   `<id>` in the toolbar dropdown, click **dry-run**.

2. **DIVIDEND rows** (3 in your sample): the right-hand trace will
   show `quantity = 0`, `unitPrice = (empty)`. Wealthfolio may or
   may not accept this — try importing the resulting `.csvx` and tell
   me if Wealthfolio rejects DIVIDEND rows. If yes, I'll switch the
   template to set `$quantity = 1` and `$unitprice = $amount` for
   DIVIDEND rows specifically.

3. **Cash event description** (FEE, DEPOSIT rows): the `comment`
   column reads `' ()'` (empty broker columns). If you'd prefer
   blank, click any FEE row → expression panel → change `$comment`
   to `IF([Wertpapier] = '', '', [Wertpapier] & ' (' & [WKN] & ')')`.

4. **Splits / mergers / transfers** (skipped per readme): I added
   `rows: []` for direction `in` / `out`. If your account had any
   splits in the sample period, those rows produce no output — open
   `--debug` (the Settings inspector → Last debug section) and tell
   me which lines were skipped. I'll add explicit `'SPLIT'` handling
   if Wealthfolio supports it.
```

Each instruction must be:

- **Action-led** ("Open …", "Click …", "Tell me …") — the user
  doesn't infer what to do from a description.
- **Targeted** — name the specific GUI control (Ctrl+O, dropdown,
  expression panel, Settings inspector). The desktop readme's
  "Keyboard shortcuts" and "Advanced GUI features" sections list
  every concrete location.
- **Round-trip** — end with what the user should report back so you
  can finish the template. Avoid open-ended "let me know if anything
  looks wrong"; ask for specific cell values, exit codes, or `.csvx`
  rows.

If everything is verifiably correct (every sample row predicted
exactly, no Wealthfolio-import gotchas you're aware of), say so
explicitly: *"This template should be complete. Run a dry-run and
import the `.csvx` into Wealthfolio; nothing else needs your
attention."*

### Self-testing the generated template

After producing the JSON5 entry, validate it works as intended before
returning to the user. Treat the steps like unit tests — predict the
expected result before running, then compare against actual output.
This is the same loop you would write in pytest or bash to assert
behaviour didn't drift after a code change.

**1. Schema + JSON5 syntax check.**

```bash
./bxp-fmt --config bxp-cli.json
```

- Expect exit `0` and no `$err_*` / `$warn_*` keys for the new
  template's path in the output JSON.
- If `$err_*` appears, fix the indicated error before going further.
- For a stricter check that also verifies `data_dir` exists and
  contains files, append `--check-fs=2` (2-second deadline).

**2. Predict, then verify in three steps.**

For each sample row the user provided, write down beforehand:

- which `row_rules` entry should match (and therefore `$action`)
- what each `$variable` should evaluate to (`$date`, `$ticker`,
  `$amount`, …)
- how many output rows the input row should produce (0 / 1 / N)

**Step A — per-expression check (`bxp-fmt --expr-trace`).** Before
wiring an expression into the template, evaluate it on its own against
one sample row and confirm the value matches your prediction — the
fastest authoring loop, no full run needed:

```bash
./bxp-fmt --expr-trace "DATE_CONVERT([Time], 'YYYY-MM-DD hh:mm:ss', 'YYYY-MM-DD')" \
  --row-headers '["Action","Time","Ticker"]' \
  --row-fields  '["Market buy","2024-04-25 07:00:35","RIO"]'
```

It streams NDJSON; the `{"t":"final","value":...}` line is the computed
result. Use `--expr-batch` (reads a JSON request on stdin) to evaluate
several `$variable` expressions against the same row in one call.

**Step B — find problems (`bxp-cli --debug`).** Run the whole template
and surface unmatched rows + runtime expression errors:

```bash
./bxp-cli --config bxp-cli.json --template <new_id> --debug
```

Output: human-readable summary + `[expr error] $var = "expr": NotANumber (...)`
lines for any expression that failed at runtime + JSON dumps of
unmatched rows when `row_rules_debug_missing: true` is set. This is the
fastest way to spot typos and locale-format bugs.

**Step C — confirm the final output.** Run the template without
`--debug` and read the generated `.csvx` directly — it is the exact
result the user will import, so compare each row against your
prediction:

```bash
./bxp-cli --config bxp-cli.json --template <new_id>
cat <data_dir>/<sample>.csvx
```

(`--trace` is a separate, binary BXTB frame stream meant for the GUI's
drill-down view — not human-readable in a terminal and not needed for
self-testing.)

Iterate until step B is silent (zero `[expr error]`, zero unmatched
rows) and the `.csvx` from step C matches every prediction.

**3. Inspect the `.csvx` output.**

```bash
head -n 6 ../data/<new_id>/*.csvx
```

- Header row matches `output_schema` keys, in order.
- Spot-check at least one row of each `$action` type the template emits.

**4. If a prediction fails, diagnose by category.**

| Symptom | Likely cause |
| --- | --- |
| `$date` empty or wrong | Date format token mismatch (`MM` vs `mm`, missing `[*]` for timezone, etc.) |
| `[ColumnName]` resolves to empty | Column name typo / case mismatch / extra whitespace in source header |
| `$amount` differs by sign | Missed `ABS()` — see Wealthfolio target spec |
| `--debug` lists unmatched rows | Missing or wrong `row_rules` `when` condition |
| `$ticker` empty for cash event | Non-trade row pattern not applied — see Wealthfolio target spec |

Re-run from step 1 after each fix. Only return the template to the
user once every prediction matches and `--debug` output is empty.

### Output format

Wealthfolio-compatible CSV. Columns are controlled by `output_schema`;
the default Wealthfolio set is:

| Column | Value | Notes |
| --- | --- | --- |
| `date` | `$date` | `YYYY-MM-DD hh:mm:ss` |
| `symbol` | `$ticker` | Yahoo Finance ticker |
| `quantity` | `$quantity` | Number of units |
| `activityType` | `$action` | `BUY`, `SELL`, `DEPOSIT`, `DIVIDEND`, … |
| `unitPrice` | `$unitprice` | Price per unit |
| `currency` | `$currency` | ISO currency code |
| `fee` | `$fee` | Blank if not reported |
| `amount` | `$amount` | Total value |
| `account` | `$account` | Optional |
| `fxRate` | `$fxRate` | Optional |
| `subtype` | `$subtype` | Optional |
| `instrumentType` | `$instrumentType` | Optional |
| `comment` | `$comment` | Optional |

Output is RFC 4180–compliant with basic protection against spreadsheet
formula injection.

### brycht.app target

The shipping brycht.app templates (`trading212_to_brychtapp`,
`xtb2_cash_to_brychtapp`, `xtb2_closed_to_brychtapp`) target a different
column set than Wealthfolio: `date, type, ticker, quantity, price,
currency, fees, notes` (8 columns) instead of Wealthfolio's 13. Templates
default to `combined_output: true` so the tracker imports a single merged
file per template. brycht.app does not publish a separate machine-readable
spec — treat the existing brycht.app entries in `bxp-cli.examples.json`
as the canonical reference: each one carries inline JSON5 comments
documenting what each `$variable` represents and how `$type` maps to the
broker's source action.

When authoring a new `*_to_brychtapp` template, pattern-match against
`trading212_to_brychtapp` (simple stock broker) or `xtb2_cash_to_brychtapp`
(xlsx-sourced, paired cash/closed shape) rather than against the
Wealthfolio templates above — the `output_schema` shape and `$action`
vocabulary differ.

---

## Contributing and newer templates

The project is open-source. For the newest built-in templates,
community contributions, and issue tracking see the BXP GitHub
repository: <https://github.com/zaxified/bxp>.

Apache-2.0 licensed. See `LICENSE.md` in the source tree.
