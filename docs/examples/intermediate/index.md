# Teaching — intermediate

Synthetic examples combining a few features.

<div class="grid cards" markdown>

-   **[Accounting Negatives → Signed Decimals](accounting-negatives/index.md)**

    Normalise an accounting/bank/ERP export where negative amounts are written in **parentheses** — `"(2,500.00)"` means `-2500` — and thousands are comma-grouped, into a clean signed-decimal column.

-   **[Boolean Variants → Canonical true/false](boolean-variants/index.md)**

    Fold boolean columns written every which way — `Yes`/`No`, `Y`/`N`, `1`/`0`, `true`/`false`, `TRUE`/`T`/`F`, mixed case — into a canonical `true`/`false`, with blanks and unrecognised junk left empty.

-   **[Fan-In Many Files → One Table (`combined_output`)](fan-in-files/index.md)**

    Stack a folder of same-shape exports — one CSV per day/month — into a single combined table, in deterministic order, with no manual `cat` and no repeated header rows.

-   **[HubSpot Contacts → Salesforce Lead](hubspot-to-salesforce/index.md)**

    Convert a HubSpot Contacts CSV export into a Salesforce Lead Import CSV.

-   **[JSON Union → One CSV (heterogeneous keys)](json-union/index.md)**

    Merge several JSON exports whose objects carry **different key sets** into a single CSV with every column, where a key a record never had collapses to an empty cell.

-   **[Percent / Basis Points → Decimal Fraction](percent-to-fraction/index.md)**

    Normalise a `Rate` column that mixes percent (`2.5%`), basis points (`25 bps`) and the odd already-decimal legacy value (`0.03`) into one consistent decimal fraction.

-   **[Price + Currency Split](price-currency-split/index.md)**

    Split a single mixed-notation `Price` column — `$12.99`, `50.00 EUR`, `€3.50`, `1,234.00 USD` — into a clean numeric `price` and a separate `currency` code, using bxp's `PRICE_VALUE` / `PRICE_CURRENCY` builtins.

</div>
