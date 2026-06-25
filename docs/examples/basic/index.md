# Teaching — basic

Synthetic, minimal inputs that isolate one engine feature at a time.

<div class="grid cards" markdown>

-   **[Null Variants → Empty](null-variants/index.md)**

    Fold every "no value" spelling — `NULL`, `NA`, `N/A`, `n/a`, `None`, `"-"` — into a single genuine empty cell, while leaving real values untouched.

-   **[Space-Grouped Thousands → Number](space-thousands/index.md)**

    Parse the continental-European number format — space-grouped thousands with a **comma** decimal, `"1 234 567,89"` = `1234567.89` — into a clean numeric value.

-   **[Units-in-Cell → Number + Unit](units-in-cell/index.md)**

    Split a measurement column that glues a number to its unit — `5.0 kg`, `250 g`, `1.5 L`, `12 pcs` — into a clean numeric `amount` and a separate `unit` column.

</div>
