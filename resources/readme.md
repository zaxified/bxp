# Broker eXchange Parser (BXP)

A converter for broker export statements (CSV, XLSX, JSON) into
portfolio-tracker CSV formats using declarative JSON5 templates.
[Wealthfolio](https://wealthfolio.app/) and
[brycht.app](https://brycht.app/) are the two trackers with shipping
templates today; any other tracker is reachable by writing an
`output_schema` for it — no code changes. Everything runs locally; your
data never leaves the machine.

BXP ships in two packages. The **console** package is two command-line
binaries; the **desktop** package bundles a graphical editor and dry-run
debugger on top of them.

- **`bxp-cli`** — the conversion engine. Produces the actual `.csvx`
  files from your broker exports and the JSON5 templates. In the desktop
  app the GUI runs it (proxied through the bundled bridge library); you
  can also run it directly from a terminal.
- **`bxp-mcp`** — an MCP server (JSON-RPC over stdio) that exposes bxp's
  stateless surface to an AI agent — validate a config or expression,
  evaluate, list templates, read the docs — and runs a full conversion
  end-to-end via its `bxp_simulate` tool. Lets an assistant author and
  self-test a template without driving the GUI.
- **`bxp-gui`** *(desktop only)* — the Flutter desktop application: a
  tree editor for the JSON5 templates plus a dry-run debugger that
  previews their behaviour against your real broker exports. Drives
  `bxp-cli` and `bxp-mcp` under the hood.

Sections marked *(desktop only)* describe the desktop app; skip them if
you have the console package.

This file has two halves. The first is for you: installing, running a
conversion, and working the desktop app. The second, **Reference for AI
assistants**, is the material an AI needs to write a template for your
broker and check its own work — hand it the whole file and it will find
its half.

---


# Reference for AI assistants

Everything above is written for you, the user. Everything below is the
material an AI assistant needs in order to author a template, drive the
tools, and check its own work — the expression language, the config
schema, the agent-callable surfaces of `bxp-mcp` and the desktop app, and
the rules it is expected to follow. It doubles as the exhaustive human
reference for the same things.

## Template authoring reference

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
  maps: {
    // optional; named, reusable key→value tables
    // map_name → { key: value, ... }
    // referenced from expressions by name: REMAP([Symbol], 'anycoin')
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

  // required; literal suffix filter (endsWith, NOT a glob), e.g. ".csv" / "_closed.csv"
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

  // optional; template-local named maps, merged over the top-level `maps`
  // registry (this template wins on a name clash)
  maps:                      { /* my_map: { "KEY": "VALUE" } */ },

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
  // [Column Name] = raw CSV field by header name; FIELDS(n) = field by position.
  input_schema: {
    $date:           "DATE_CONVERT([Date], 'DD/MM/YYYY hh:mm:ss', 'YYYY-MM-DD hh:mm:ss')",
    $ticker:         "REMAP([Symbol], 'anycoin')",
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
| `file_pattern_out` | string | yes | — | Replaces `file_pattern_in` in output filename. Must be non-empty — there is no derived default |
| `csv_delimiter_in` | string | no | `","` | Field separator of input CSV |
| `csv_delimiter_out` | string | no | `","` | Field separator of output CSV |
| `csv_decimal_separator_in` | string | no | `"."` | Decimal separator in numeric fields (input) |
| `csv_decimal_separator_out` | string | no | `"."` | Decimal separator in numeric fields (output) |
| `csv_text_quote_in` | string | no | `"double"` | `"none"`, `"single"` (`'`), or `"double"` (`"`) |
| `csv_text_quote_out` | string | no | `"none"` | Same values as `csv_text_quote_in` |
| `csv_input_encoding` | string | no | `"utf-8"` | Encoding of the input CSV, transcoded to UTF-8 on read. `"utf-8"`, `"windows-1250"`, `"windows-1252"`, `"iso-8859-1"`, `"iso-8859-2"`, `"iso-8859-15"`. Use for legacy non-UTF-8 exports (e.g. Czech Excel `"windows-1250"`). CSV only |
| `csv_output_encoding` | string | no | `"utf-8"` | Encoding of the output CSV. Same values as `csv_input_encoding`; characters with no equivalent become `?`. CSV only |
| `csv_header_line` | number | no | `1` | 1-based line of the CSV header. `0` = headerless (first line is data, columns reachable only by `FIELDS(n)`); `N>1` skips `N-1` preamble lines. CSV input only |
| `date_filter_from_filename` | bool | no | `false` | Filter rows by `YYYY-MM-DD_YYYY-MM-DD` range in filename |
| `maps` | object | no | `{}` | Template-local named maps `{ name: { key: value } }`, merged over the top-level `maps` registry. Referenced by `REMAP`/`REPLACE` |
| `xlsx_sheet` | object | no | — | `{ name, header_row, output_suffix }` — convert xlsx before CSV |
| `zip_input` | object | no | — | `{ entry_pattern, … }` — stream every matching member of each `*.zip` in `data_dir` out to a flat intermediate CSV before the normal CSV loop. For zipped CSV exports |
| `pre_pass` | object | no | — | `{ when, key, values }` — first-pass lookup table |
| `input_schema` | object | yes | — | `$variable` → expression, evaluated per row |
| `row_rules_debug_missing` | bool | no | `false` | Print unmatched rows with `--debug` |
| `row_rules` | array | no | — | Ordered routing rules; first match wins. Omitting it is accepted by the loader, but then no row produces output |
| `output_schema` | object | yes | — | Output CSV header → `$variable`; defines column order |
| `combined_output` | bool | no | `false` | When `true`, all input files additionally write rows to one merged file `1-{template_id}-combined{file_pattern_out}` in `data_dir`, alongside the normal per-file outputs |

#### Nested object schemas

The four object-valued template fields have their own required keys.

**`row_rules[]` entry**

| Field | Type | Required | Purpose |
| --- | --- | --- | --- |
| `when` | expression | yes | Rule applies when this is truthy (non-empty, non-zero, not `"false"`) |
| `rows` | array | yes | Output rows produced on a match. Each entry overrides `$variables`; `rows: []` skips the row silently, `rows: [{}]` emits one row using `input_schema` verbatim |

**`pre_pass` block** (either the object itself, or each named block inside it)

| Field | Type | Required | Purpose |
| --- | --- | --- | --- |
| `when` | expression | yes | Only rows matching this are added to the table |
| `key` | expression | yes | Evaluated per row to produce the lookup key |
| `values` | object | yes | `field_name` → expression, retrieved via `LOOKUP` |

**`xlsx_sheet`** — extract one sheet to an intermediate CSV before the CSV loop

| Field | Type | Required | Purpose |
| --- | --- | --- | --- |
| `name` | string | yes | Sheet name exactly as it appears in the workbook, e.g. `"CASH OPERATION"` |
| `header_row` | number | yes | 1-based row within the sheet that holds the column headers |
| `output_suffix` | string | yes | Appended before `.csv` in the intermediate filename, e.g. `"_cash"`. Use `""` for none |

**`zip_input`** — stream matching members of each `*.zip` in `data_dir` out to flat CSVs first

| Field | Type | Required | Default | Purpose |
| --- | --- | --- | --- | --- |
| `entry_pattern` | string | no | `".csv"` | Literal suffix filter for zip members — not a glob |
| `dir_mode` | string | no | `"basename"` | `"basename"` keeps only the last path segment; `"keep_path"` flattens the whole in-zip path. Use `keep_path` when members in different sub-directories share a filename — `basename` would have them overwrite each other |
| `path_separator` | string | no | `"_"` | What `/` becomes under `keep_path` (`CSV/x.csv` → `CSV_x.csv`). Ignored for `basename` |

### Standard `$variable` reference

The `$variable`s bxp-cli's Wealthfolio templates set, and the output column
each one feeds. This is the canonical list — the `output_schema` in the
skeleton above is exactly this mapping written out.

| `$variable` | Output column | Required | Meaning |
| --- | --- | --- | --- |
| `$date` | `date` | yes | Transaction datetime, format `YYYY-MM-DD hh:mm:ss` |
| `$ticker` | `symbol` | yes | Yahoo Finance ticker (after `REMAP()` mapping) |
| `$quantity` | `quantity` | yes | Number of units |
| `$action` | `activityType` | yes | Activity type — **set only in `row_rules`**, never in `input_schema` |
| `$unitprice` | `unitPrice` | yes | Price per unit |
| `$currency` | `currency` | yes | ISO currency code (`USD`, `EUR`, `CZK`, …) |
| `$fee` | `fee` | yes | Fee amount; blank if the broker does not report one |
| `$amount` | `amount` | yes | Total transaction value |
| `$account` | `account` | no | Account tag |
| `$fxRate` | `fxRate` | no | FX rate |
| `$subtype` | `subtype` | no | Wealthfolio subtype |
| `$instrumentType` | `instrumentType` | no | e.g. `'Cryptocurrency'` |
| `$comment` | `comment` | no | Free-form comment |

Setting a `$variable` to `""` leaves its column blank; dropping the column
from `output_schema` removes it entirely. Column order is whatever
`output_schema` declares. For the values `$action` may take, see
*Wealthfolio target spec* below; `*_to_brychtapp` templates use a different
column set and vocabulary altogether.

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
| `[2]` | **Not positional.** Brackets always look a column up *by header name*, so this reads a column literally headed `2` — and yields `""` if none exists. Use `FIELDS(2)` for the second field |
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
| `CASE(expr, m1, r1, …, default)` | any | Multi-branch mapping: first `r` whose `m` equals `expr`, else trailing `default` (or `""`); only the chosen result is evaluated. Collapses nested `IF` chains |
| `IFERROR(expr, fallback)` | any | `expr`'s value, or `fallback` on a data error (bad number/date, overflow). Template errors (unknown function, arity, syntax) still surface — it guards messy data, not template mistakes |
| `ABS(x)` | number | Absolute numeric value |
| `ROUND(x, n)` | number | Round `x` to `n` decimal places (negative `n` rounds tens/hundreds) |
| `FLOOR(x)` | number | Largest integer ≤ `x` |
| `CEILING(x)` | number | Smallest integer ≥ `x` |
| `MOD(a, b)` | number | Remainder of `a / b` with the sign of `a` (like SQL/C `%`); `MOD(a, 0)` → `""` |
| `TRIM(s)` | string | Strip leading/trailing whitespace |
| `REPLACE(s, old, new, ...)` | string | Replace every `old` with `new` (substring, UTF-8 safe). Variadic `REPLACE(s, o1, n1, o2, n2, ...)` applies the pairs in one left-to-right pass (first match per position wins, output not re-scanned) instead of nesting; empty `old` matches nothing |
| `SPLIT_PART(s, delim, n)` | string | Split `s` by `delim`, return 1-based nth part; `""` if out of range |
| `CONTAINS(s, sub)` | bool | `true` when `sub` is found inside `s` |
| `REGEX_MATCH(s, pattern)` | bool | `true` when regex `pattern` matches anywhere in `s`. Linear-time engine (anchors, classes, quantifiers, groups, alternation; no backreferences/lookaround). Unicode-scalar, but `\d`/`\w`/`\s` stay ASCII — match accented letters with an explicit class like `[A-ZÁ-Ž]`. Use only when a literal `CONTAINS`/`IN` won't do |
| `REGEX_EXTRACT(s, pattern)` | string | First part of `s` matched by regex `pattern` (the first capture group `(...)` if present, else the whole match), or `""` if no match. Pulls a ticker/code/token a literal `REPLACE`/`SPLIT_PART` can't isolate |
| `PRICE_VALUE(s)` | string | Strip currency symbol/code: `"24.00 CZK"` → `"24.00"`, `"$100"` → `"100"` |
| `PRICE_CURRENCY(s)` | string | Extract ISO currency: `"24.00 CZK"` → `"CZK"`, `"$100"` → `"USD"` |
| `REMAP(s, 'name' \| k, v, ...)` | string | Whole-value lookup: if `s` exactly equals a map key, return its value, else `s` unchanged. Named form resolves a `maps` entry; inline `REMAP(s, k1,v1, ...)` gives pairs directly |
| `DATE_CONVERT(s, from, to)` | string | Parse `s` using `from` format, emit using `to` format (tokens below) |
| `LOOKUP([name,] key, 'field')` | string | Retrieve a value stored by a `pre_pass` table. `LOOKUP('name', key, 'field')` selects a named block; the 2-arg `LOOKUP(key, 'field')` works only when exactly one block is defined |
| `FIELDS(n)` | string | Raw field by 1-based position. The only positional accessor — `[n]` is a header-name lookup, not an index. Required for headerless input (`csv_header_line: 0`) |
| `NOW()` | string | Current UTC datetime, format `YYYY-MM-DDTHH:MM:SSZ` |
| `RAND(n)` | string | `n` random digits (first 1–9, rest 0–9); `n` clamped to 1–65 |
| `FILENAME()` | string | Input file stem (directory + matched `file_pattern_in` suffix removed); e.g. `SPLIT_PART(FILENAME(), '_', 3)` reads a field from the name |
| `RECORD_NUM()` | number | 1-based input record number of the current row within the file |
| `SHEET_NAME()` | string | Source `xlsx_sheet.name` for xlsx-derived input; `""` for CSV/JSON |
| `COALESCE(a, b, ...)` | any | First non-empty argument (empty = whitespace-only string); falls back to last arg verbatim if all empty |
| `LEFT(s, n)` | string | First `n` bytes of `s` (`n` clamped to `[0, len]`; negative / non-finite → `""`) |
| `RIGHT(s, n)` | string | Last `n` bytes of `s` (same clamping) |
| `SUBSTR(s, start, len)` | string | `len` bytes from 1-based `start`; non-positive / non-finite `start` or `len` → `""` |
| `LPAD(s, len, pad)` / `RPAD(s, len, pad)` | string | Pad `s` (left / right) with `pad` to `len` bytes; truncates if longer; empty `pad` → `s`. `len` clamped to `[0, 65535]` |
| `POSITION(needle, haystack)` | number | 1-based byte position of first `needle` in `haystack`, `0` if absent; empty `needle` → `1` |
| `PROPER(s)` | string | Title-case: upper-case the first letter of each word, lower-case the rest (`apple inc` → `Apple Inc`); words break on any non-letter |
| `UPPER(s)` / `LOWER(s)` | string | Full-Unicode case conversion (`café`→`CAFÉ`, `ß`→`SS`, `я`→`Я`); unicameral scripts (CJK/Arabic/Hebrew) and invalid UTF-8 bytes pass through unchanged |
| `UNACCENT(s)` | string | Strip Latin diacritics (`café`→`cafe`, `ÀÉ`→`AE`, `ß`→`ss`, `ø`→`o`); Latin-scope like Postgres — non-Latin keeps its base script (`Ά`→`Α`), CJK/Arabic pass through, ligatures not folded |
| `LEN(s)` | number | Byte length of `s` (UTF-8 byte count, not codepoints); empty → `0` |
| `STARTS_WITH(s, prefix)` | bool | `true` when `s` begins with `prefix` (case-sensitive); empty `prefix` always matches |
| `ENDS_WITH(s, suffix)` | bool | `true` when `s` ends with `suffix` (case-sensitive); empty `suffix` always matches |
| `IN(value, v1, v2, ...)` | bool | `true` when `value` equals any of `v1, v2, …` — variadic equality OR-chain |
| `NULLIF(value, sentinel)` | any | `""` when `value` = `sentinel`, else `value`; collapses sentinels (`-9999`, `\N`, `N/A`) |
| `ISEMPTY(x)` | bool | `true` when `x` is empty or whitespace-only — the safe emptiness test (`x = ''` wrongly matches `'0'`) |
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

**Timezone functions** — full DST-aware IANA support, backed by a bundled
snapshot of the tz database (no network, no system dependency). Zone ids are
IANA names (`Europe/Prague`, `America/New_York`, `UTC`) or, where a function
accepts a zone, a fixed offset (`+02:00`). An unknown zone yields `""` (or
`false`). Within the one-hour DST-transition window the wall-clock input is
read as local time, so a result can be off by the offset.

| Function | Returns | Description |
| --- | --- | --- |
| `TO_UTC(ts, from)` | string | Normalise an offset-bearing timestamp to UTC. `from` is a date format containing the `ZZ` offset token (or a literal `Z`); the parsed offset is subtracted → `YYYY-MM-DD hh:mm:ss` in UTC. Needs no zone database — the offset is in the string. `TO_UTC('2024-03-15T14:23:01+02:00', 'YYYY-MM-DD[T]hh:mm:ssZZ')` → `2024-03-15 12:23:01` |
| `TZ_OFFSET(datetime, zone)` | string | DST-aware UTC offset (`+HH:MM`/`-HH:MM`) of IANA `zone` at local wall-clock `datetime`. Concatenate onto a naive local timestamp to make it ISO-8601 tz-aware: `[Date] & 'T' & [Time] & TZ_OFFSET([Date] & ' ' & [Time], 'Europe/Prague')` |
| `TZ_CONVERT(ts, from_zone, to_zone)` | string | Convert wall-clock `ts` from `from_zone` to `to_zone` → `YYYY-MM-DD hh:mm:ss`. `TZ_CONVERT('2024-07-15 12:00:00', 'America/New_York', 'Europe/Prague')` → `2024-07-15 18:00:00` |
| `IS_DST(datetime, zone)` | bool | `true` when daylight-saving time is in effect in IANA `zone` at local `datetime`, else `false` |

Datetime arguments to `TZ_OFFSET` / `TZ_CONVERT` / `IS_DST` are `YYYY-MM-DD`
with an optional ` hh:mm:ss` (or `T`-separated) time.

#### Function semantics — common gotchas

- **`CONTAINS(s, sub)` is a substring match, not a prefix match.** It
  returns `true` whenever `sub` appears *anywhere* inside `s`, which
  means `CONTAINS('Sell to Buy', 'Buy')` is `true`. Brokers with
  prefix-based action codes (Schwab `MKT BUY` / `LMT BUY`, IBKR
  multi-word actions) need an exact or word-boundary check: prefer
  exact comparison (`[Action] = 'Buy'`), `SPLIT_PART([Action], ' ', 1) = 'Buy'`
  for the first word, or exclude the false matches explicitly —
  `CONTAINS([Action], 'Buy') AND NOT CONTAINS([Action], 'Sell')` is a valid
  expression (`NOT` binds tighter than `AND`, see the precedence line above)
  and is `false` for `Sell to Buy`.
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

#### Extracting a ticker from a free-text description

Some brokers leave the `Symbol` column empty and only name the
instrument inside a free-text field — a dividend row might read
`Description: "Qualified Dividend APPLE INC 100"` with no ticker column
at all. Two composable tools cover this without a new builtin:

1. **`REGEX_EXTRACT`** isolates the company-name token. The company name
   is a run of ALL-CAPS words, so a pattern matching one-or-more upper-case
   words skips the Title-case prefix (`Qualified Dividend`) and the trailing
   count on its own:
   `REGEX_EXTRACT([Description], '[A-Z]{2,}(?: [A-Z]{2,})*')` → `APPLE INC`
   (also `TESLA` → `TESLA`, `BERKSHIRE HATHAWAY INC` → the full name). The
   group is **non-capturing** `(?:…)` on purpose — a capturing `(…)` would
   make `REGEX_EXTRACT` return only its last word, not the whole match.
2. **`REMAP`** maps that name to a Yahoo ticker via a named `maps` entry
   keyed on the company name — maps can key on *anything*, not just an
   existing symbol:

   ```json5
   maps: { company_names: { "APPLE INC": "AAPL", "TESLA INC": "TSLA" } },
   ```

Combined into one `$ticker` expression:

```text
REMAP(REGEX_EXTRACT([Description], '[A-Z]{2,}(?: [A-Z]{2,})*'), 'company_names')
```

If the field is *only* the company name (no surrounding words), skip the
regex and `REMAP([Description], 'company_names')` directly — `REMAP` is a
whole-value match, so the field must equal a key exactly.

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
| `ZZ` | UTC offset `±HH:MM` (parses a literal `Z` as `+00:00`) | `+02:00` |
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

**More than one lookup table.** The shape above is the single-block form.
When a row needs values from two *different* kinds of other row, declare
named blocks instead — each is its own namespace, and `LOOKUP` takes the
name as a first argument:

```json5
pre_pass: {
  fees:  { when: "[Type] = 'fee'",  key: "[Id]", values: { amt: "[Amount]" } },
  rates: { when: "[Type] = 'rate'", key: "[Id]", values: { amt: "[Amount]" } },
},

input_schema: {
  $fee:  "LOOKUP('fees',  [Id], 'amt')",
  $rate: "LOOKUP('rates', [Id], 'amt')",
},
```

The two forms are distinguished by the presence of a `when` key directly
under `pre_pass`: with it, the object *is* the block (single-block form,
2-arg `LOOKUP`); without it, each key names a block (3-arg `LOOKUP`). The
2-arg form is an error when more than one block exists, so pick named
blocks as soon as you need a second table — converting later means
rewriting every `LOOKUP` call.

Adding blocks does not add passes over the file: the first pass evaluates
every block against each row as it goes, so the cost of a second table is
its `when` / `key` expressions, not another read of the input.

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

**Activity-type vocabulary.** `$action` is set inside `row_rules`, never in
`input_schema`. The first group covers every event the built-in templates
emit; the second handles portfolio bookkeeping events Wealthfolio also
imports.

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
  `IF([type] = 'cash', '$CASH-XXX', REMAP([Symbol], 'mymap'))` style branching
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

**Output columns.** Which columns are required and which are optional is in
the *Standard `$variable` reference* table above.

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

1. **`bxp-cli.examples.json` is required context.** It carries the shipping
   templates with rich inline comments. **If you don't have it in your
   context, ask the user to provide it before generating any template — do
   not guess at non-trade row patterns, action vocabulary, or broker
   quirks.** Read it first, then pattern-match against whichever entry is
   closest in *shape* to the broker at hand: a plain stock broker, a
   paired-row broker needing `pre_pass`, an xlsx-sourced one, or a
   tracker-mode one if the user targets brycht.app rather than Wealthfolio.
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
6. **Prefer named `maps`.** If the broker's symbols overlap an
   existing named map (e.g. `xtb`, `trading212`), reference it by name with
   `REMAP([Symbol], 'xtb')`. Otherwise define a small inline `REMAP(s, k, v, ...)`.
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
    outcome, then verify with the bxp-mcp tools (`bxp_validate` for the
    config, `bxp_eval` / `bxp_eval_trace` for per-expression values,
    `bxp_simulate` to run it end-to-end), or with `bxp-cli --debug` when
    no MCP server is wired. Only return the template once the run is
    clean and the generated `.csvx` matches every prediction.

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

The self-test surface depends on what you have wired:

- **With the bxp-mcp server** (the agent-facing path): use its tools —
  `bxp_validate`, `bxp_validate_expr` / `bxp_eval` / `bxp_eval_trace` /
  `bxp_eval_batch`, and `bxp_simulate` (a full end-to-end run). Each
  takes config / expression *text* as arguments, so you never touch the
  filesystem.
- **With only `bxp-cli`** (no MCP): use `bxp-cli --debug` and a real run.

**1. Schema + JSON5 syntax check.** Call `bxp_validate` with the config
text:

- Expect no `$err_*` / `$warn_*` keys for the new template's path in the
  returned annotated JSON.
- If `$err_*` appears, fix the indicated error before going further.

**2. Predict, then verify.**

For each sample row the user provided, write down beforehand:

- which `row_rules` entry should match (and therefore `$action`)
- what each `$variable` should evaluate to (`$date`, `$ticker`,
  `$amount`, …)
- how many output rows the input row should produce (0 / 1 / N)

**Step A — per-expression check.** Before wiring an expression into the
template, evaluate it on its own against one sample row and confirm the
value matches your prediction — the fastest authoring loop, no full run
needed. Call `bxp_eval_trace` (or `bxp_eval`) with the expression plus
`headers` / `fields` for the row, e.g.

```json
{"expr":"DATE_CONVERT([Time], 'YYYY-MM-DD hh:mm:ss', 'YYYY-MM-DD')",
 "headers":"[\"Action\",\"Time\",\"Ticker\"]",
 "fields":"[\"Market buy\",\"2024-04-25 07:00:35\",\"RIO\"]"}
```

**Watch the argument shape — the two eval families differ.** On `bxp_eval`
and `bxp_eval_trace`, `headers` and `fields` are **JSON encoded into a
string** (as above). On `bxp_eval_batch` they are **native JSON arrays**.
Passing an array to `bxp_eval` does not fail: the row context is silently
dropped and every `[Column]` reference evaluates to `""` with `ok:true`, so
a correct expression looks broken. If a `[Column]` comes back empty
unexpectedly, check this before editing the expression.

`bxp_eval_trace` returns NDJSON; the `{"t":"final","value":...}` line is
the computed result. Use `bxp_validate_expr` to additionally catch
authoring-time mistakes the lenient runtime swallows (e.g. a literal
`SPLIT_PART(…, 0)`), and `bxp_eval_batch` to evaluate several `$variable`
expressions against the same row in one call — it also accepts `maps`,
`lookups` and `single_prepass_name`, which is the only way to exercise a
`pre_pass` / `LOOKUP` expression without a full run.

**Step B — run it end-to-end.** With MCP, call `bxp_simulate` with the
config, the template id, and the sample CSV. It stages and runs the real
`bxp-cli` pipeline and returns the produced output, a record-count diff,
`bxp-cli`'s diagnostics, and a per-row `trace` (which rows were written /
filtered / errored, with input line numbers) — the strongest check,
because it exercises `pre_pass` / `LOOKUP` / `row_rules` for real.

Without MCP, run the template and surface unmatched rows + runtime
expression errors directly:

```bash
./bxp-cli --config bxp-cli.json --template <new_id> --debug
```

Output: human-readable summary + `[expr error] $var = "expr": NotANumber (...)`
lines for any expression that failed at runtime + JSON dumps of
unmatched rows when `row_rules_debug_missing: true` is set. This is the
fastest way to spot typos and locale-format bugs.

**Step C — confirm the final output.** With `bxp_simulate`, read the
returned `outputs[].csv` — it is the exact result the user will import,
so compare each row against your prediction. Without MCP, run the
template without `--debug` and read the generated `.csvx` directly:

```bash
./bxp-cli --config bxp-cli.json --template <new_id>
cat <data_dir>/<sample>.csvx
```

(`bxp-cli --trace` is a separate, binary BXTB frame stream meant for the
GUI's drill-down view — not human-readable in a terminal and not needed
for self-testing.)

In the GUI, the equivalent of Step C is a **dry-run** — its trace panes
show the same per-row outcome interactively, no terminal needed.

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

Wealthfolio-compatible CSV. Which columns appear, and in what order, is
controlled entirely by `output_schema` — the default Wealthfolio set and
the `$variable` behind each column are in the *Standard `$variable`
reference* table above.

Output is RFC 4180–compliant with basic protection against spreadsheet
formula injection.

### brycht.app target

The `*_to_brychtapp` templates target a different column set than
Wealthfolio: `date, type, ticker, quantity, price, currency, fees, notes`
(8 columns) instead of Wealthfolio's 13. They set `combined_output: true`
so the tracker imports a single merged file per template. brycht.app does
not publish a separate machine-readable spec — treat the `*_to_brychtapp`
entries in `bxp-cli.examples.json` as the canonical reference: each one
carries inline JSON5 comments documenting what each `$variable` represents
and how `$type` maps to the broker's source action.

When authoring a new `*_to_brychtapp` template, pattern-match against an
existing `*_to_brychtapp` entry rather than against the Wealthfolio
templates above — the `output_schema` shape and `$action` vocabulary
differ.

---

## Contributing and newer templates

The project is open-source. For the newest built-in templates,
community contributions, and issue tracking see the BXP GitHub
repository: <https://github.com/zaxified/bxp>.

Apache-2.0 licensed. See `LICENSE.md` in the source tree.
