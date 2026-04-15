# Broker eXchange Parser (bxp-cli)

A single-binary CLI tool that converts broker export statements (CSV, XLSX, JSON) into
[Wealthfolio](https://wealthfolio.app/) CSV format using declarative JSON5 templates.
No code changes, no runtime dependencies — just the binary and a config file. Everything
runs locally; your data never leaves the machine.

---

## Basic usage

```bash
./bxp-cli --help                                  # print usage
./bxp-cli                                         # process all templates from bxp-cli.json
./bxp-cli --template <id>                         # process a single template
./bxp-cli --template <id> --data ./my-data/       # override data_dir for that template
```

### Three-step recipe

1. Drop the broker's export file into the template's `data_dir`.
2. Run `./bxp-cli --template <id>`.
3. Pick up the generated `*.csvx` file next to the input — ready to import into Wealthfolio.

### Built-in templates

| Template ID                  | Broker                        |
| ---                          | ---                           |
| `revolutx_to_wealthfolio`    | Revolut X (crypto)            |
| `trading212_to_wealthfolio`  | Trading 212                   |
| `anycoin_to_wealthfolio`     | Anycoin (crypto)              |
| `xtb1_closed_to_wealthfolio` | XTB — closed positions (old)  |
| `xtb1_cash_to_wealthfolio`   | XTB — cash operations (old)   |
| `xtb2_closed_to_wealthfolio` | XTB — closed positions (new)  |
| `xtb2_cash_to_wealthfolio`   | XTB — cash operations (new)   |

**CLI flags:** `--template <id>`, `--data <dir>`, `--config <file>`, `--debug`, `--quiet`, `--fresh`. \
**Exit codes:** `0` = success, `1` = error, `2` = completed with warnings.

**Need a broker that isn't listed? Ask your AI assistant.** bxp-cli templates are plain
JSON5 — a capable AI (Claude, ChatGPT, ...) can write one for you. Paste this prompt into
your assistant, attach this readme and `bxp-cli.examples.json`, then drop in 5 rows of
your broker's raw CSV:

> *"I use bxp-cli. Please read the **Advanced usage** section of `readme.md`
> and the comments in `bxp-cli.examples.json`. Here is a sample of my broker's
> export: `<paste 5 rows including the header>`. Add a new entry under
> `conversion_templates` in my `bxp-cli.json` that converts this to Wealthfolio CSV,
> following the same patterns as the existing templates. Follow the rules in the
> 'Rules for an AI assistant' section."*

---

## Advanced usage

This section is written so that a capable AI assistant can produce a working broker
template given only this file and `bxp-cli.examples.json`. It is also useful
as a human reference.

### Architecture in one paragraph

bxp-cli is a two-pass declarative data pipeline. Pass one (optional `pre_pass`) scans
all rows and builds a lookup table for cross-row joins. Pass two iterates rows, evaluates
`input_schema` expressions into per-row `$variable`s, then routes each row through the
ordered `row_rules` list — the first matching rule decides the row's activity type and
whether it produces 0, 1, or N output rows. `output_schema` then projects the final
`$variable`s into CSV columns in a fixed order. Input may be CSV, XLSX, or JSON; output
is RFC 4180–compliant CSV or JSON.

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

All `data_dir` paths are resolved relative to the location of `bxp-cli.json`.

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

| Field                       | Type              | Required | Default    | Purpose                                                         |
| ---                         | ---               | ---      | ---        | ---                                                             |
| `data_dir`                  | string            | yes      | —          | Directory with input files; relative to `bxp-cli.json`          |
| `file_type_in`              | string            | no       | `"csv"`    | `"csv"` or `"json"` (array-of-objects)                          |
| `file_type_out`             | string            | no       | `"csv"`    | `"csv"` or `"json"`                                             |
| `file_pattern_in`           | string            | yes      | —          | Suffix filter, e.g. `".csv"`, `"_closed.csv"`                   |
| `file_pattern_out`          | string            | no       | append `x` | Replaces `file_pattern_in` in output filename                   |
| `csv_delimiter_in`          | string            | no       | `","`      | Field separator of input CSV                                    |
| `csv_delimiter_out`         | string            | no       | `","`      | Field separator of output CSV                                   |
| `csv_decimal_separator_in`  | string            | no       | `"."`      | Decimal separator in numeric fields (input)                     |
| `csv_decimal_separator_out` | string            | no       | `"."`      | Decimal separator in numeric fields (output)                    |
| `csv_text_quote_in`         | string            | no       | `"double"` | `"none"`, `"single"` (`'`), or `"double"` (`"`)                 |
| `csv_text_quote_out`        | string            | no       | `"none"`   | Same values as `csv_text_quote_in`                              |
| `date_filter_from_filename` | bool              | no       | `false`    | Filter rows by `YYYY-MM-DD_YYYY-MM-DD` range in filename        |
| `ticker_map`                | string \| object  | no       | `{}`       | Name from `ticker_maps`, or inline `{ "SYM": "YAHOO" }`         |
| `xlsx_sheet`                | object            | no       | —          | `{ name, header_row, output_suffix }` — convert xlsx before CSV |
| `pre_pass`                  | object            | no       | —          | `{ when, key, values }` — first-pass lookup table               |
| `input_schema`              | object            | yes      | —          | `$variable` → expression, evaluated per row                     |
| `row_rules_debug_missing`   | bool              | no       | `false`    | Print unmatched rows with `--debug`                             |
| `row_rules`                 | array             | yes      | —          | Ordered routing rules; first match wins                         |
| `output_schema`             | object            | yes      | —          | Output CSV header → `$variable`; defines column order           |

### Standard `$variable` reference

Output `$variable`s that bxp-cli's Wealthfolio templates set. The first eight map 1:1 to
Wealthfolio's import columns; the rest are optional.

| Variable          | Meaning                                                            |
| ---               | ---                                                                |
| `$date`           | Transaction datetime, format `YYYY-MM-DD hh:mm:ss`                 |
| `$ticker`         | Yahoo Finance ticker (after `TICKER()` mapping)                    |
| `$quantity`       | Number of units                                                    |
| `$unitprice`      | Price per unit                                                     |
| `$currency`       | Currency code (`USD`, `EUR`, `CZK`, …)                             |
| `$fee`            | Fee amount (empty if broker does not report one)                   |
| `$amount`         | Total transaction value                                            |
| `$action`         | Activity type — **set only in `row_rules`**, never in `input_schema` |
| `$account`        | Account tag (optional)                                             |
| `$fxRate`         | FX rate (optional)                                                 |
| `$subtype`        | Wealthfolio subtype (optional)                                     |
| `$instrumentType` | e.g. `'Cryptocurrency'` (optional)                                 |
| `$comment`        | Free-form comment (optional)                                       |

Typical `$action` values for Wealthfolio: `'BUY'`, `'SELL'`, `'DEPOSIT'`, `'WITHDRAWAL'`,
`'DIVIDEND'`, `'TAX'`, `'INTEREST'`, `'FEE'`. An empty `""` expression omits the variable
from output.

### Expression language — full reference

Expressions are strings evaluated once per row. Operator precedence, high → low:

```text
unary -    →    * /    →    & (concat)    →    + -    →    = != < > <= >=    →    AND    →    OR
```

#### Column and literal syntax

| Syntax         | Description                                              |
| ---            | ---                                                      |
| `[ColumnName]` | Raw CSV field by header name (leading/trailing spaces trimmed) |
| `[n]`          | Raw CSV field by 1-based column index                    |
| `'text'`       | String literal                                           |
| `123`, `-0.5`  | Numeric literal                                          |
| `&`            | String concatenation (`'$CASH-' & [Currency]`)           |
| `$variable`    | Reference to a variable set earlier in `input_schema`    |

**Built-in functions** (all names are case-insensitive)

| Function                     | Returns | Description                                                                 |
| ---                          | ---     | ---                                                                         |
| `IF(cond, yes, no)`          | any     | Short-circuit conditional; only the selected branch is evaluated            |
| `ABS(x)`                     | number  | Absolute numeric value                                                      |
| `ROUND(x, n)`                | number  | Round `x` to `n` decimal places (negative `n` rounds tens/hundreds)         |
| `FLOOR(x)`                   | number  | Largest integer ≤ `x`                                                       |
| `CEILING(x)`                 | number  | Smallest integer ≥ `x`                                                      |
| `TRIM(s)`                    | string  | Strip leading/trailing whitespace                                           |
| `REPLACE(s, old, new)`       | string  | Replace all occurrences of `old` with `new`; if `old` is empty, returns `s` |
| `SPLIT_PART(s, delim, n)`    | string  | Split `s` by `delim`, return 1-based nth part; `""` if out of range         |
| `CONTAINS(s, sub)`           | bool    | `true` when `sub` is found inside `s`                                       |
| `PRICE_VALUE(s)`             | string  | Strip currency symbol/code: `"24.00 CZK"` → `"24.00"`, `"$100"` → `"100"`   |
| `PRICE_CURRENCY(s)`          | string  | Extract ISO currency: `"24.00 CZK"` → `"CZK"`, `"$100"` → `"USD"`           |
| `TICKER(s)`                  | string  | Map `s` through the template's `ticker_map`; pass through if not found      |
| `DATE_CONVERT(s, from, to)`  | string  | Parse `s` using `from` format, emit using `to` format (tokens below)        |
| `LOOKUP(key, 'field')`       | string  | Retrieve a value stored by `pre_pass` under `key` / `field`                 |
| `FIELDS(n)`                  | string  | Same as `[n]` — raw field by 1-based index                                  |
| `NOW()`                      | string  | Current UTC datetime, format `YYYY-MM-DDTHH:MM:SSZ`                         |
| `RAND()`                     | number  | Cryptographically random float in `[0, 1)`                                  |

#### Type coercions

- Empty string → `0` in a numeric context.
- Any non-empty string → `true` in a boolean context; empty string → `false`.
- Numeric strings are parsed on demand; `csv_decimal_separator_in` controls which decimal separator is accepted.
- American thousands-separated numbers (`1,234.56`, `-1,234,567`) are automatically parsed in arithmetic contexts; the original string is preserved when the field is passed through as-is to output.

#### Minimal examples

```text
'$CASH-' & [Currency]                                          → string concat
IF([Type] = 'Buy', 'BUY', IF([Type] = 'Sell', 'SELL', ''))     → nested conditional
ROUND(ABS([Total]) / [Quantity], 4)                            → derived unit price
DATE_CONVERT([Date], 'DD/MM/YYYY hh:mm:ss', 'YYYY-MM-DD hh:mm:ss')
LOOKUP([Order ID], 'amount') / [Amount]                        → cross-row join via pre_pass
PRICE_VALUE([Price])                                           → strip currency symbol
SPLIT_PART([Comment], ' @ ', 2)                                → second part after " @ "
```

### Date format tokens

Both the `from` and `to` arguments of `DATE_CONVERT` use the same token set (from the
`sunrise` library). Any characters that are not tokens are matched literally.

| Token        | Meaning                                           | Example    |
| ---          | ---                                               | ---        |
| `YYYY`       | 4-digit year                                      | `2026`     |
| `YY`         | 2-digit year (00–69 → 2000s, 70–99 → 1970s)       | `26`       |
| `MM`         | 2-digit month (01–12)                             | `03`       |
| `M`          | 1–2 digit month                                   | `3`        |
| `MMMM`       | Full month name                                   | `March`    |
| `MMM`        | 3-char month abbreviation                         | `Mar`      |
| `DD`         | 2-digit day                                       | `07`       |
| `D`          | 1–2 digit day                                     | `7`        |
| `hh`         | 2-digit hour, **24h** (00–23)                     | `14`       |
| `h`          | 1–2 digit hour, 24h                               | `14`       |
| `ii`         | 2-digit hour, **12h** (01–12)                     | `02`       |
| `i`          | 1–2 digit hour, 12h                               | `2`        |
| `mm`         | 2-digit minute                                    | `05`       |
| `m`          | 1–2 digit minute                                  | `5`        |
| `ss`         | 2-digit second                                    | `09`       |
| `s`          | 1–2 digit second                                  | `9`        |
| `A`          | AM/PM uppercase                                   | `PM`       |
| `a`          | am/pm lowercase                                   | `pm`       |
| `EEEE`       | Full day name                                     | `Monday`   |
| `EEE`/`EE`/`E` | Short day name                                  | `Mon`      |
| `e`          | Day of week as number (1 = Mon … 7 = Sun)         | `1`        |
| `[text]`     | Literal text (escaped inside format string)       | `[T]` → `T` |
| `[*]`        | Wildcard — skip until the next token              | skips `Z`, timezone suffix, etc. |

#### Gotchas

- `mm` is minute; `MM` is month — easy to mix up.
- `MMM` expects exactly 3 characters; 4-character variants like `Sept` and `June` are
  pre-normalized automatically.
- Years before 1970 are rejected.
- Components not present in the `from` format default to `1970-01-01 00:00:00`.

#### Worked date examples

```text
"26 Jun 2022, 16:02:36"       →  'DD MMM YYYY, hh:mm:ss'
"2024-02-23T06:20:20.182Z"    →  'YYYY-MM-DDThh:mm:ss[*]'   (skips .182Z)
"07/03/2026 14:05:00"         →  'DD/MM/YYYY hh:mm:ss'
"2026-01-05 05:20:18"         →  'YYYY-MM-DD hh:mm:ss'      (canonical output)
```

### `pre_pass` — cross-row joins

Use `pre_pass` when an input row needs data that lives on **another row** (for example,
Anycoin writes `trade payment` and `trade fill` as two rows sharing an `Order ID`).
bxp-cli makes a first pass over the file, collects rows matching `when`, and stores
`values` under `key`. Then `input_schema` can read them via `LOOKUP(key, 'field')`.

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

Note: keys inside `values` are **plain field names**, not `$variables`, and they are
not visible to `row_rules` or `output_schema` directly — only through `LOOKUP()`.

### Rules for an AI assistant adding a new broker

If you are an AI assistant reading this section to generate a new template, follow these
rules strictly:

1. **Read `bxp-cli.examples.json` first.** It contains seven working templates
   with rich inline comments. Pattern-match against the one closest to the target broker
   (simple stock broker → Revolut X; paired rows → Anycoin; xlsx source → XTB).
2. **Add, do not modify.** Insert a new entry under `conversion_templates` in the user's
   `bxp-cli.json`. Never rewrite existing templates unless the user explicitly asks.
3. **Match the real CSV format.** Look at the sample header and first data row the user
   provided. Set `csv_delimiter_in`, `csv_decimal_separator_in`, and `csv_text_quote_in`
   to match what the broker actually exports — do not guess.
4. **Put activity-type logic in `row_rules`, not `input_schema`.** `$action` must be
   assigned inside a `row_rules[].rows[]` entry (e.g. `$action: "'BUY'"`). The
   `input_schema` only extracts and transforms neutral values.
5. **Use `pre_pass` only for cross-row joins.** If one input row needs a value from
   another row (paired transaction legs, fee refunds, order/fill pairs), use `pre_pass`
   and `LOOKUP`. Otherwise omit it entirely.
6. **Prefer named `ticker_map`s.** If the broker's symbols overlap an existing named
   map (e.g. `xtb`, `trading212`), reference it by name. Otherwise define a small
   inline map.
7. **One-to-many rows.** When one input row must produce multiple output rows (currency
   conversion = FEE + WITHDRAWAL + DEPOSIT; dividend with tax; split fees), return
   multiple objects in the same `row_rules[].rows` array. Each object can override
   `$variables` for that specific output row.
8. **Match the broker's exact date shape.** Use `DATE_CONVERT` with sunrise tokens that
   correspond to the input literally, character-by-character; use `[*]` to skip
   fractional seconds, trailing `Z`, or timezone suffixes.
9. **Prices with embedded currency.** For fields like `"$100.00"` or `"24.00 CZK"`, use
   `PRICE_VALUE()` for the number and `PRICE_CURRENCY()` for the ISO code.
10. **Empty values.** Set a `$variable` to `""` to leave that output column blank.
    Drop a column from `output_schema` entirely to remove it.
11. **Enable debug during development.** Set `row_rules_debug_missing: true` and run
    with `--debug` so any unmatched rows surface on stdout as JSON.
12. **Verify end-to-end.** Run `./bxp-cli --template <new_id> --debug`, confirm exit
    code `0`, then open the `.csvx` output and spot-check at least one row of each
    `$action` type.

### Output format

Wealthfolio-compatible CSV. Columns are controlled by `output_schema`; the default
Wealthfolio set is:

| Column           | Value           | Notes                                   |
| ---              | ---             | ---                                     |
| `date`           | `$date`         | `YYYY-MM-DD hh:mm:ss`                   |
| `symbol`         | `$ticker`       | Yahoo Finance ticker                    |
| `quantity`       | `$quantity`     | Number of units                         |
| `activityType`   | `$action`       | `BUY`, `SELL`, `DEPOSIT`, `DIVIDEND`, … |
| `unitPrice`      | `$unitprice`    | Price per unit                          |
| `currency`       | `$currency`     | ISO currency code                       |
| `fee`            | `$fee`          | Blank if not reported                   |
| `amount`         | `$amount`       | Total value                             |
| `account`        | `$account`      | Optional                                |
| `fxRate`         | `$fxRate`       | Optional                                |
| `subtype`        | `$subtype`      | Optional                                |
| `instrumentType` | `$instrumentType` | Optional                              |
| `comment`        | `$comment`      | Optional                                |

Output is RFC 4180–compliant with basic protection against spreadsheet formula injection.

### Contributing and newer templates

The project is open-source. For the newest built-in templates, community contributions,
and issue tracking see the BXP GitHub repository: <https://github.com/zaxified/bxp>.
