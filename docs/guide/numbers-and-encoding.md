---
description: "Exact fixed-point arithmetic, European decimal and thousands separators, and legacy CSV character encodings."
---

# Numbers and encoding

## Locale-aware number parsing (European brokers)

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

!!! note

    The decimal separator must differ from `csv_delimiter_in`, so a template
    that sets `csv_decimal_separator_in: ","` must also move the field
    separator off the default comma (`csv_delimiter_in: ";"` — which is what
    these exports use anyway). Otherwise the config is rejected at load.

Numeric output is **canonical, not verbatim**: a plain `[Column]` reference
whose value the fixed-point core represents exactly drops redundant trailing
zeros, so `75,00` reaches the output file as `75` and `1,50` as `1.5`. Values
the core does not canonicalise — a leading-zero form like `0012`, or more than
12 fractional digits — pass through byte-for-byte, as does anything used in a
string context (`'' & [Column]`).

US-style brokers (Schwab, Fidelity, Trading 212) use `.` decimal +
optional `,` thousands — that path is handled automatically (see the
"American thousands-separated numbers" note under
[Expressions → Type coercions](expressions.md#type-coercions)).

## Character encoding (legacy CSV)

By default BXP reads and writes UTF-8. For legacy non-UTF-8 exports
(e.g. Czech Excel `windows-1250`), set `csv_input_encoding` /
`csv_output_encoding` on the template. Field values and header names are
transcoded to UTF-8 on read and back on write.

Both default to `"utf-8"` and accept the same code pages:

--8<-- "includes/csv-encodings.md:values"

On output, a character with no equivalent in the target code page becomes `?`.
The full field reference, defaults included, is in the generated
[config schema](../reference/config-schema.md).

Encoding applies to **CSV only** — JSON (always UTF-8 by RFC 8259) and
xlsx (XML-in-ZIP, always UTF-8 in practice) never reach the transcoder.
