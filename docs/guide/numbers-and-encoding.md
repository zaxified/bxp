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

US-style brokers (Schwab, Fidelity, Trading 212) use `.` decimal +
optional `,` thousands — that path is handled automatically (see the
"American thousands-separated numbers" note under
[Expressions → Type coercions](expressions.md#type-coercions)).

## Character encoding (legacy CSV)

By default BXP reads and writes UTF-8. For legacy non-UTF-8 exports
(e.g. Czech Excel `windows-1250`), set `csv_input_encoding` /
`csv_output_encoding` on the template. Field values and header names are
transcoded to UTF-8 on read and back on write.

| Setting | Default | Values |
| --- | --- | --- |
| `csv_input_encoding` | `"utf-8"` | `"utf-8"`, `"windows-1250"`, `"windows-1252"`, `"iso-8859-1"`, `"iso-8859-2"`, `"iso-8859-15"` |
| `csv_output_encoding` | `"utf-8"` | same values; characters with no equivalent become `?` |

Encoding applies to **CSV only** — JSON (always UTF-8 by RFC 8259) and
xlsx (XML-in-ZIP, always UTF-8 in practice) never reach the transcoder.
