# Two-File Keyed JOIN (concat + pre_pass + LOOKUP)

[← all examples](../../README.md)

**What.** Enrich a fact table that carries only a foreign key (orders →
`customer_id`) with the human details from a separate dimension table
(customers → `name`, `city`) — a real relational JOIN across two sources.

**Synthetic / teaching example.** The data here is **constructed**, not sourced.
`joined_input.csv` is the two tables already stacked into one file with a `_type`
marker (`customer` rows + `order` rows). The _problem class_ — facts keyed to a
separate lookup table — is universal; the rows are not.

**Why interesting.** bxp reads **one file per pass**, so a cross-file join needs
the two sources brought together first. Once they share a file with a row-type
marker, a keyed join is just a `pre_pass` over the dimension rows plus a `LOOKUP`
on the fact rows — no database, no `JOIN` SQL. This generalises the single-file
`real-world/gtfs-stops-selfjoin` (a _self_-join) to **two distinct sources**.

**Problem class documented in.** (sources for the problem class — not for the data)

- The star-schema fact/dimension split is the foundational pattern of every
  relational and analytics database (Kimball dimensional modelling); resolving a
  foreign key to its row is the single most common data-prep step.

**The trick** (see inline comments in `sample.json`):

1. **Stack the two files with a `_type` marker.** Here it ships ready-made; to
   produce it from two separate files _inside bxp_, see
   [../multi-stage-etl](../multi-stage-etl/00-readme.md), which builds the same
   shape with `combined_output`.
2. **`pre_pass` over `_type = 'customer'`** — index `name`/`city` by
   `customer_id` (the dimension side).
3. **`LOOKUP([customer_id], …)` on the order rows** — resolve the foreign key.
   `row_rules` emits only `_type = 'order'`; the dimension rows were just the
   lookup source.

**Run it.**

```bash
bxp-cli --config ./sample.json --template two_file_join
```

**Smoking gun.** Each order gains its customer's name and city. An order whose
key is **not** in the dimension (`C-9`) keeps empty details — unmatched rows stay
**visible**, not silently dropped:

```text
order_id,customer_id,customer_name,customer_city,amount
1001,C-1,Acme s.r.o.,Praha,1250.5
1002,C-2,Globex a.s.,Brno,980
1003,C-1,Acme s.r.o.,Praha,540
1004,C-9,,,75
```
