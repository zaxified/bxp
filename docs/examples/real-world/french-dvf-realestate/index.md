# French DVF Real-Estate → Analytics Schema

[:material-github: View on GitHub](https://github.com/zaxified/bxp/tree/master/docs/examples/real-world/french-dvf-realestate){ .md-button }

!!! abstract "What"
    Reshape France's official "Demandes de valeurs foncières" (DVF) raw
    real-estate transaction export into a clean analytics CSV with ISO dates,
    proper euro amounts, and a repaired postal code.

## Why interesting

DVF is the canonical open dataset for French property
prices (every registered sale, published by the tax authority DGFiP), and the
raw file is a textbook example of a European-government CSV that quietly breaks
US-centric tooling: (1) it is **pipe-delimited** (`|`), not comma-delimited, so
a default `read_csv` sees one giant column; (2) monetary values use a **comma
decimal** — `346,50` means 346.50 €, but a parser that assumes `,` is a
thousands separator reads it as `34650` (a **100× overvaluation**) or splits
the field; (3) dates are **DD/MM/YYYY**, so `02/01/2024` is 2 January, not
1 February; (4) the **`Code postal` column was stored as a number** by the
producer, so Ain's `01230` already arrives as `1230` — its leading zero is
gone before you even open the file.

**Edge cases sourced from.**

- [DGFiP — "Notice descriptive du fichier DVF"](https://static.data.gouv.fr/resources/demandes-de-valeurs-foncieres/20221017-153319/notice-descriptive-du-fichier-dvf-20221017.pdf)
  — the official field/format description (pipe delimiter, comma decimals,
  column meanings)
- French postal codes are five digits with a leading zero for départements
  01–09; storing them numerically (a recurring open-data defect) drops it

**Data source.** [DGFiP — Demandes de valeurs foncières (data.gouv.fr)](https://www.data.gouv.fr/fr/datasets/demandes-de-valeurs-foncieres/)
(this slice: first 250 transactions of the 2024 file, département 01 / Ain).
Licence Ouverte / Etalab (CC-BY-compatible).

## At full scale

The committed `sample.csv` is a 250-row slice; the
real 2024 file is every property transaction registered in France that year.
Pull it and run the same template against the whole thing:

```bash
bash fetch-full.sh          # downloads + extracts ./full/ValeursFoncieres-2024.txt (~446 MB)
bxp-cli --config full.json  # processes all ~3.5M transactions
```

Measured on the reference machine (ReleaseFast, 8 cores):

| metric    | value                                       |
| --------- | ------------------------------------------- |
| input     | 3,499,931 rows / 446 MB (pipe-delimited)    |
| output    | 3,499,931 rows / 213 MB (1:1)               |
| wall time | ~4.9 s                                      |
| peak RSS  | ~22 MB (flat — does not grow with the file) |

## The tricks

(see inline comments in `sample.json`):

0. **Pipe delimiter** — `csv_delimiter_in: "|"`.
1. **Comma decimal** — `csv_decimal_separator_in: ","` so `346,50` arrives as
   `346.5` instead of `34650` or a split field.
2. **DD/MM/YYYY → ISO** — `DATE_CONVERT([Date mutation], 'DD/MM/YYYY', 'YYYY-MM-DD')`.
3. **Leading-zero département preserved** — `[Code departement]` is stored as
   text (`01`) and passes through verbatim.
4. **Damaged postal code repaired** — `[Code postal]` already lost its zero in
   the source (`1230`); `RIGHT('00000' & [Code postal], 5)` re-pads it back to
   `01230`. (This idiom only emits the correct value since the bxp leading-zero
   fix — previously the padded result was re-canonicalised straight back to
   `1230`.)

## Run it

```bash
bxp-cli --config ./sample.json --template dvf_realestate_to_analytics
```

## Final result

Open `sample.csvx` row 1 (`CHALEY`, 02/01/2024):

- `price_eur = 346.5` — the raw `346,50`. A naive importer would log this sale
  at **€34,650**, a 100× error that silently corrupts every price aggregate.
- `postal_raw = 1230` vs `postal_fixed = 01230` — the column as-shipped vs
  repaired. Join the raw value against a postal-code reference table and every
  département-01 through 09 row misses.

Click the `price_eur` cell in the GUI: the trace pane shows `[Valeur fonciere]`
resolving the comma-decimal field to `346.5`. Click `postal_fixed` to watch the
`RIGHT('00000' & …, 5)` re-pad chain rebuild the leading zero the source threw
away.

## Sample data

=== "sample.json (config)"

    ```js
    --8<-- "examples/real-world/french-dvf-realestate/sample.json"
    ```

=== "sample.csv"

    ```csv
    --8<-- "examples/real-world/french-dvf-realestate/sample.csv"
    ```

**Full-scale &amp; binary files** (run it on the complete dataset): [`fetch-full.sh`](https://github.com/zaxified/bxp/tree/master/docs/examples/real-world/french-dvf-realestate/fetch-full.sh) · [`full.json`](https://github.com/zaxified/bxp/tree/master/docs/examples/real-world/french-dvf-realestate/full.json).
