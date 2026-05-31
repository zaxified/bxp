# HubSpot Contacts → Salesforce Lead

[← all examples](../../README.md)

**What.** Convert a HubSpot Contacts CSV export into a Salesforce Lead Import CSV.

**Synthetic / teaching example.** Unlike `examples/real-world/`, the data here
is **constructed**, not sourced — `sample.csv` is hand-written rows (fictional
companies) engineered to plant one of each failure mode below. CRM exports are
private customer data with no public dataset, so this lives in the teaching tier
rather than real-world. The *failure modes* it exercises are real and
documented; the rows are not.

**Why interesting.** Real CRM migrations take 2–8 weeks because picklist mismatches, mixed date formats and trailing whitespace fail _silently_ — the import succeeds row by row, then Salesforce rejects half of them after the fact.

**Failure modes documented in.** (sources for the problem class — not for the data)

- <https://splitforge.app/blog/crm-import-failures-complete-guide/> — picklist
  enforcement, timestamp overwrites, read-only silent drops
- <https://clonepartner.com/blog/pipedrive-to-hubspot-migration-data-mapping-apis-rate-limits>
  — multi-object association loss, type coercion

**The tricks** (see inline comments in `sample.json`):

1. **Long picklist** (Industry) → `TICKER()` + `ticker_map` repurposed as
   string lookup table.
2. **Short picklists** (Status, LeadSource) → `IF` chain with `TRIM` at the
   leaf to absorb trailing whitespace.
3. **Required-but-empty field** (Company) → `COALESCE(..., '<missing>')`
   sentinel so the failure is visible, not silent.
4. **Mixed date formats** → `IF(CONTAINS('/'), DATE_CONVERT US, DATE_CONVERT ISO)`
   sniffs the separator per row.

**Run it.**

```bash
bxp-cli --config ./sample.json --template hubspot_to_sfdc_lead
```

**Smoking gun.** Open `sample.csv` row 7 (Lisa Brown / Cyberdyne) in the GUI.
Industry value `"Foo Bar Industry"` is not in the lookup map — `TICKER()`
passes it through unchanged. CLI says `errors:0`, but Salesforce would reject
the row. Click the Industry cell: the trace pane shows
`TICKER("Foo Bar Industry") → "Foo Bar Industry"` — input equals output, the
smoking gun. Add the missing key and watch the cell go green live.
