# HubSpot Contacts → Salesforce Lead

[:material-github: View on GitHub](https://github.com/zaxified/bxp/tree/master/docs/examples/intermediate/hubspot-to-salesforce){ .md-button }

!!! abstract "What"
    Convert a HubSpot Contacts CSV export into a Salesforce Lead Import CSV.

!!! note "Synthetic / teaching example"
    Unlike `examples/real-world/`, the data here
    is **constructed**, not sourced — `sample.csv` is hand-written rows (fictional
    companies) engineered to plant one of each failure mode below. CRM exports are
    private customer data with no public dataset, so this lives in the teaching tier
    rather than real-world. The _failure modes_ it exercises are real and
    documented; the rows are not.

## Why interesting

Real CRM migrations take 2–8 weeks because picklist mismatches, mixed date formats and trailing whitespace fail _silently_ — the import succeeds row by row, then Salesforce rejects half of them after the fact.

**Failure modes documented in.** (sources for the problem class — not for the data)

- <https://splitforge.app/blog/crm-import-failures-complete-guide/> — picklist
  enforcement, timestamp overwrites, read-only silent drops
- <https://clonepartner.com/blog/pipedrive-to-hubspot-migration-data-mapping-apis-rate-limits>
  — multi-object association loss, type coercion

## The tricks

See inline comments in `sample.json`:

1. **Long picklist** (Industry) → `REMAP()` over a named map — a reusable
   whole-value string lookup table.
2. **Short picklists** (Status, LeadSource) → `CASE()` over a `TRIM`med
   subject. `TRIM` absorbs trailing whitespace (row 2 has `Open `) and, unlike
   an `IF` chain, it is written once instead of once per branch.
   Run it: `CASE(TRIM([Lead Status]), 'New', 'Open - Not Contacted', 'Open', 'Working - Contacted', 'In Progress', 'Working - Contacted', 'Connected', 'Working - Contacted', 'Open Deal', 'Working - Contacted', 'closed-won', 'Closed - Converted', 'Bad Timing', 'Closed - Not Converted', 'Unqualified', 'Closed - Not Converted', 'Open - Not Contacted')`{.bxp-try}
3. **Required-but-empty field** (Company) → `COALESCE(..., '<missing>')`
   sentinel so the failure is visible, not silent.
   Run it: `COALESCE(TRIM([Company Name]), '<missing>')`{.bxp-try}
4. **Mixed date formats** → `IF(CONTAINS('/'), DATE_CONVERT US, DATE_CONVERT ISO)`
   sniffs the separator per row.
   Run it: `IF(CONTAINS([Create Date], '/'), DATE_CONVERT([Create Date], 'M/D/YYYY hh:mm:ss', 'YYYY-MM-DD[T]hh:mm:ss[Z]'), DATE_CONVERT([Create Date], 'YYYY-MM-DD hh:mm:ss', 'YYYY-MM-DD[T]hh:mm:ss[Z]'))`{.bxp-try}
   — on **show all** both branches fire, on different rows.

## Final result

Every HubSpot vocabulary lands on a Salesforce one, and the two date shapes
converge:

```text
raw HubSpot                          →  Salesforce Lead
"Software"                           →  Technology
"Pharma & Biotech"                   →  Biotechnology
"Open " (trailing space)             →  Working - Contacted
"closed-won"                         →  Closed - Converted
"2024-01-15 09:23:01"                →  2024-01-15T09:23:01Z
"1/12/2024 10:30:00"                 →  2024-01-12T10:30:00Z
"" (company missing)                 →  <missing>
```

**One row deliberately does not convert.** Row 7 (Cyberdyne) has
`Industry = "Foo Bar Industry"`, which is not a key in the map — and `REMAP`
passes an unknown value **through unchanged** rather than blanking it. The run
reports `errors:0`, the CSV looks fine, and Salesforce rejects the row on
import. Input equals output is the only signal, which is exactly why the
`<missing>` sentinel in trick 3 exists for the other failure mode: a gap you
can see beats a gap you cannot.

!!! tip "Trace it in the GUI"
    Click that Industry cell: the trace pane shows
    `REMAP("Foo Bar Industry") → "Foo Bar Industry"` — input equal to output.
    Add the missing key to the map and the cell updates live.

## Sample data

Run it with `bxp-cli --config ./sample.json --template hubspot_to_sfdc_lead`:

=== "sample.json (config)"

    ```js
    --8<-- "examples/intermediate/hubspot-to-salesforce/sample.json"
    ```

=== "sample.csv"

    ```{.csv .bxp-sample}
    --8<-- "examples/intermediate/hubspot-to-salesforce/sample.csv"
    ```

=== "sample.csvx (result)"

    ```csv
    --8<-- "examples/intermediate/hubspot-to-salesforce/sample.csvx"
    ```
