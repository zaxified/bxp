---
description: "How a conversion template is put together — data_dir, file patterns, input_schema, row_rules, output_schema."
---

# Templates

A BXP config (`bxp-cli.json`) is JSON5 — JSON with comments, unquoted
keys, and trailing commas allowed. It declares optional reusable `maps`
and one or more `conversion_templates`.

This page is the human guide to authoring a template. The exhaustive
field-by-field table lives in [Config schema](../reference/config-schema.md).

## `bxp-cli.json` layout

```json5
{
  maps: {
    // optional; named, reusable key→value tables
    // map_name → { key: value, ... }
    // referenced from expressions by name: REMAP([Symbol], 'anycoin')
    anycoin: { BTC: "BTC-EUR" },
    revolutx: { BTC: "BTC-USD" },
  },
  conversion_templates: {
    // required; map of template_id → template config (see skeleton below)
    mysource_to_wealthfolio: {
      /* ... */
    },
  },
}
```

All `data_dir` paths are resolved relative to the location of
`bxp-cli.json`.

## Blank template skeleton

Copy, fill in, run:

```json5
mysource_to_wealthfolio: {

  // required; path to input files, relative to bxp-cli.json
  data_dir:                  "mysource_to_wealthfolio",

  // default "csv"; options: "csv", "json" (array-of-objects)
  file_type_in:              "csv",
  file_type_out:             "csv",

  // required; literal suffix filter (endsWith, NOT a glob), e.g. ".csv" / "_closed.csv"
  file_pattern_in:           ".csv",
  // required; suffix of output filename, replaces file_pattern_in
  file_pattern_out:          ".csvx",

  // input CSV parsing — match the source's actual format
  csv_delimiter_in:          ",",       // ",", ";", "\t", "|", ...
  csv_decimal_separator_in:  ".",       // ".", ","
  csv_text_quote_in:         "double",  // "none" | "single" ' | "double" "

  // output CSV formatting
  csv_delimiter_out:         ",",
  csv_decimal_separator_out: ".",
  csv_text_quote_out:        "none",

  // default 1; 1-based line holding the CSV header. 0 = headerless input
  // (no header row; reach columns by position with FIELDS(n)); N>1 skips
  // N-1 preamble lines before the header (exports with a text banner).
  // csv_header_line:           1,

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

  // optional; unpack every *.zip in data_dir into flat intermediate CSVs
  // before processing (zip → (xlsx) → csv → csvx), e.g. a "zip of one CSV
  // per region" export. entry_pattern picks members by suffix; dir_mode
  // "basename" (default) flattens paths, "keep_path" joins them with
  // path_separator. Runs in parallel.
  // See docs/examples/real-world/ruian-address-points.
  // zip_input: { entry_pattern: ".csv", dir_mode: "basename", path_separator: "_" },

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
  // [Column Name] = raw CSV field by header name; FIELDS(n) = field by
  // 1-based column position ([2] means a column *named* "2", not the 2nd one).
  input_schema: {
    $date:           "DATE_CONVERT([Date], 'DD/MM/YYYY hh:mm:ss', 'YYYY-MM-DD hh:mm:ss')",
    $ticker:         "REMAP([Symbol], 'anycoin')",
    $quantity:       "[Quantity]",
    $unitprice:      "[Price]",
    $currency:       "[Currency]",
    $fee:            "[Fee]",
    $amount:         "[Total]",
    $account:        "",      // optional; e.g. "'MySource'", "[Account]"
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

## Standard `$variable`s

Output `$variable`s that bxp-cli's Wealthfolio templates set. The first
eight map 1:1 to Wealthfolio's import columns; the rest are optional.

| Variable          | Meaning                                                              |
| ----------------- | -------------------------------------------------------------------- |
| `$date`           | Transaction datetime, format `YYYY-MM-DD hh:mm:ss`                   |
| `$ticker`         | Yahoo Finance ticker (after `REMAP()` mapping)                       |
| `$quantity`       | Number of units                                                      |
| `$unitprice`      | Price per unit                                                       |
| `$currency`       | Currency code (`USD`, `EUR`, `CZK`, …)                               |
| `$fee`            | Fee amount (empty if the source does not report one)                 |
| `$amount`         | Total transaction value                                              |
| `$action`         | Activity type — **set only in `row_rules`**, never in `input_schema` |
| `$account`        | Account tag (optional)                                               |
| `$fxRate`         | FX rate (optional)                                                   |
| `$subtype`        | Wealthfolio subtype (optional)                                       |
| `$instrumentType` | e.g. `'Cryptocurrency'` (optional)                                   |
| `$comment`        | Free-form comment (optional)                                         |

An empty `""` expression leaves that variable blank — the column is still
written, because `output_schema` alone decides the column set. The
activity-type vocabulary and sign conventions are described in [Target
specs](targets.md).

## Where each concept is covered

- Expressions in `input_schema` / `row_rules` → [Expressions](expressions.md)
- `DATE_CONVERT` and date arithmetic → [Dates](dates.md)
- European numbers and CSV encodings → [Numbers and encoding](numbers-and-encoding.md)
- `pre_pass` / `LOOKUP` cross-row joins → [Cross-row joins](cross-row-joins.md)
- `row_rules` routing → [Row routing](row-routing.md)
- Output column set and `$action` vocabulary → [Target specs](targets.md)
