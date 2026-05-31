# Fan-In Many Files → One Table (`combined_output`)

[← all examples](../../README.md)

**What.** Stack a folder of same-shape exports — one CSV per day/month — into a
single combined table, in deterministic order, with no manual `cat` and no
repeated header rows.

**Synthetic / teaching example.** The data here is **constructed**, not sourced
— three daily files (`2024-01-01.csv` … `2024-01-03.csv`) with identical columns
and continental numbers (`"1 250,50"`). The *problem class* — periodic exports
you have to glue back together — is universal; the rows are not.

**Why interesting.** Almost every operational system emits one file per period
(daily sales, monthly statements, per-run logs). Re-assembling them with
`cat *.csv` duplicates the header on every file boundary and the order depends
on the shell glob; doing it in a spreadsheet is manual and error-prone. One
flag turns the whole folder into one clean table.

**Problem class documented in.** (sources for the problem class — not for the data)

- The classic `cat *.csv > all.csv` foot-gun (a header row per input) is one of
  the most-asked CSV questions on Stack Overflow and the reason tools like
  `csvstack` (csvkit) exist.

**The trick** (see inline comments in `sample.json`):

`combined_output: true`. Every file matched by `file_pattern_in` in `data_dir`
is run through the one template and the output rows are written to a single file,
`1-fan_in_daily-combined.csvx`, in **alphabetical filename order** — so naming
files by date gives a chronological stack. The per-row cleanup (`REPLACE` the
space thousands + comma decimal, `* 1`) is applied uniformly to every file.

> Note: bxp still also writes a per-file `<stem>.csvx` for each input; the
> combined file is the fan-in result. Pass `--fresh` on a re-run to suppress the
> per-file copies once they exist.

**Run it.**

```bash
bxp-cli --config ./sample.json --template fan_in_daily
```

**Smoking gun.** Three two-row files become one six-row table, in date order,
amounts already numeric:

```text
date,store,amount
2024-01-01,Praha,1250.5
2024-01-01,Brno,980
2024-01-02,Praha,1100
...
2024-01-03,Brno,1320
```
