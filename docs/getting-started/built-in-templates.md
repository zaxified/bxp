# Built-in templates

BXP ships working templates for several brokers, targeting both
Wealthfolio and brycht.app. Use one directly, or pattern-match against
the closest one when [authoring a new
broker](../ai/authoring-a-broker.md).

| Template ID                  | Broker                                              |
| ---------------------------- | --------------------------------------------------- |
| `revolutx_to_wealthfolio`    | Revolut X (crypto)                                  |
| `trading212_to_wealthfolio`  | Trading 212                                         |
| `anycoin_to_wealthfolio`     | Anycoin (crypto)                                    |
| `xtb1_closed_to_wealthfolio` | XTB — closed positions (old)                        |
| `xtb1_cash_to_wealthfolio`   | XTB — cash operations (old)                         |
| `xtb2_closed_to_wealthfolio` | XTB — closed positions (new)                        |
| `xtb2_cash_to_wealthfolio`   | XTB — cash operations (new)                         |
| `revolutx_to_brychtapp`      | Revolut X (crypto) → brycht.app (tracker)           |
| `anycoin_to_brychtapp`       | Anycoin (crypto) → brycht.app (tracker)             |
| `trading212_to_brychtapp`    | Trading 212 → brycht.app (tracker)                  |
| `xtb2_cash_to_brychtapp`     | XTB — cash operations (new) → brycht.app (tracker)  |
| `xtb2_closed_to_brychtapp`   | XTB — closed positions (new) → brycht.app (tracker) |

The shipping templates live in `bxp-cli.examples.json` (in the console
archive and in the GitHub repository). Each carries inline JSON5 comments
documenting what every `$variable` represents and how the broker's source
actions map — they are the canonical reference for new templates.
