# Target specs

A template's `output_schema` decides which tracker it targets. BXP ships
templates for two: Wealthfolio and brycht.app. Neither publishes a
machine-readable spec, so the existing built-in templates are the
de-facto contract.

## Wealthfolio

The output `.csvx` is consumed by Wealthfolio. The conventions below are
enforced by the existing built-in templates and are the canonical
reference for new templates.

### Sign conventions

All three numeric variables are always positive; direction (buy vs sell,
deposit vs withdrawal) is encoded in `$action`, not in the sign of the
amount.

| Variable    | Convention                                                                                |
| ----------- | ----------------------------------------------------------------------------------------- |
| `$amount`   | Always positive — wrap raw broker values in `ABS()` if your broker reports signed values. |
| `$quantity` | Always positive — `ABS()` if needed.                                                      |
| `$fee`      | Always positive (a cost). `ABS()` if needed.                                              |

### Activity-type vocabulary

`$action` is set inside `row_rules`. Eight values cover every event the
built-in templates emit:

| Action         | When                                            |
| -------------- | ----------------------------------------------- |
| `'BUY'`        | Buy / acquisition                               |
| `'SELL'`       | Sell / disposal                                 |
| `'DEPOSIT'`    | Cash deposit into the account                   |
| `'WITHDRAWAL'` | Cash withdrawal                                 |
| `'DIVIDEND'`   | Dividend received                               |
| `'TAX'`        | Tax withheld                                    |
| `'INTEREST'`   | Interest paid (e.g. on cash balance)            |
| `'FEE'`        | Fee charged (e.g. monthly account fee, ADR fee) |

Three additional values handle portfolio bookkeeping events that
Wealthfolio also imports:

| Action           | When                                                                   |
| ---------------- | ---------------------------------------------------------------------- |
| `'TRANSFER_IN'`  | Stock moved into the account from elsewhere (zero-cost arrival)        |
| `'TRANSFER_OUT'` | Stock moved out of the account to elsewhere                            |
| `'SPLIT'`        | Stock split — `$amount` carries the split ratio (e.g. `2` for 2-for-1) |

If your broker emits an event that doesn't fit any of these, prefer
`'INTEREST'` for income-like cash, `'FEE'` for cost-like cash, and skip
the row (`rows: []`) if you can't classify it cleanly.

### Non-trade row patterns

Cash events (DEPOSIT, WITHDRAWAL, INTEREST, FEE, and DIVIDEND on a
balance without a ticker) don't have a meaningful symbol or unit price.
The existing templates demonstrate two valid patterns — pick the one
that matches your broker, do not invent a third:

- **Centralised in `input_schema`** (Anycoin, Revolut X, XTB cash) —
  `IF([type] = 'cash', '$CASH-XXX', REMAP([Symbol], 'mymap'))` style
  branching at variable definition time. `row_rules` then only sets
  `$action`. Compact when most cash events take the same shape and the
  input has a single column that distinguishes cash from stock rows.
- **Per-rule overrides** (Trading 212) — `input_schema` defines defaults
  that work for the trade rows, then individual `row_rules[].rows[]`
  entries clear or override `$variables` per event type (e.g.
  `$quantity: ""`, `$unitprice: ""` for a deposit; three different
  `rows` for a currency conversion). Verbose but flexible when different
  cash events need different shapes or when one input row must produce
  multiple output rows.

### Output columns

| Required                                                                               | Optional                                                    |
| -------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| `date`, `symbol`, `quantity`, `activityType`, `unitPrice`, `currency`, `fee`, `amount` | `account`, `fxRate`, `subtype`, `instrumentType`, `comment` |

`$date` should be `YYYY-MM-DD hh:mm:ss`. Brokers that report date-only
(no time) result in `... 00:00:00` — that's accepted. Output is RFC
4180–compliant with basic protection against spreadsheet formula
injection.

The default Wealthfolio column mapping:

| Column           | Value             | Notes                                   |
| ---------------- | ----------------- | --------------------------------------- |
| `date`           | `$date`           | `YYYY-MM-DD hh:mm:ss`                   |
| `symbol`         | `$ticker`         | Yahoo Finance ticker                    |
| `quantity`       | `$quantity`       | Number of units                         |
| `activityType`   | `$action`         | `BUY`, `SELL`, `DEPOSIT`, `DIVIDEND`, … |
| `unitPrice`      | `$unitprice`      | Price per unit                          |
| `currency`       | `$currency`       | ISO currency code                       |
| `fee`            | `$fee`            | Blank if not reported                   |
| `amount`         | `$amount`         | Total value                             |
| `account`        | `$account`        | Optional                                |
| `fxRate`         | `$fxRate`         | Optional                                |
| `subtype`        | `$subtype`        | Optional                                |
| `instrumentType` | `$instrumentType` | Optional                                |
| `comment`        | `$comment`        | Optional                                |

## brycht.app

The shipping brycht.app templates (`trading212_to_brychtapp`,
`xtb2_cash_to_brychtapp`, `xtb2_closed_to_brychtapp`) target a different
column set than Wealthfolio: `date, type, ticker, quantity, price,
currency, fees, notes` (8 columns) instead of Wealthfolio's 13. Templates
default to `combined_output: true` so the tracker imports a single merged
file per template.

brycht.app does not publish a separate machine-readable spec — treat the
existing brycht.app entries in `bxp-cli.examples.json` as the canonical
reference: each carries inline JSON5 comments documenting what each
`$variable` represents and how `$type` maps to the broker's source
action.

When authoring a new `*_to_brychtapp` template, pattern-match against
`trading212_to_brychtapp` (simple stock broker) or
`xtb2_cash_to_brychtapp` (xlsx-sourced, paired cash/closed shape) rather
than against the Wealthfolio templates above — the `output_schema` shape
and `$action` vocabulary differ.
