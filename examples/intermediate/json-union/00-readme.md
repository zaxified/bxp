# JSON Union → One CSV (heterogeneous keys)

[← all examples](../../README.md)

**What.** Merge several JSON exports whose objects carry **different key sets**
into a single CSV with every column, where a key a record never had collapses to
an empty cell.

**Synthetic / teaching example.** The data here is **constructed**, not sourced
— two CRM dumps (`crm_alpha.in.json` with `vat`+`email`, `crm_beta.in.json` with
`phone`). The _problem class_ — JSON omits empty keys, so two dumps of "the same
thing" are structurally different — is universal; the rows are not.

**Why interesting.** Unlike CSV, JSON has no fixed column list: every object only
contains the keys it has a value for. Concatenate two API dumps and you get
ragged objects — `vat` in one, `phone` in the other, `email` in some of both.
Loading them into one table normally means a jq/pandas script to align the
columns. bxp does the alignment from the `output_schema` alone.

**Problem class documented in.** (sources for the problem class — not for the data)

- The JSON object model has no schema; missing-vs-null is a perennial pain when
  flattening arrays of objects (the reason `pandas.json_normalize` and `jq -s`
  exist).

**The trick** (see inline comments in `sample.json`):

Two mechanisms together — `file_type_in: "json"` (bxp takes the **union of keys**
per file as that file's columns; an absent key reads as `""`) and
`combined_output: true` (both files run through the one template into a single
`1-json_union-combined.csvx`). The `output_schema` lists every target column;
each input normalises to it automatically.

> Note: bxp also writes a per-file `<stem>.csvx`; the combined file is the union
> result.

**Run it.**

```bash
bxp-cli --config ./sample.json --template json_union
```

**Smoking gun.** Two ragged JSON files become one rectangular CSV — `vat` filled
only for alpha rows, `phone` only for beta, `email` wherever it existed:

```text
company,vat,email,phone
Acme s.r.o.,CZ12345678,sales@acme.cz,
Globex a.s.,CZ99887766,info@globex.cz,
Beta Ltd,,,555-0101
Initech,,hi@initech.io,555-0102
```
