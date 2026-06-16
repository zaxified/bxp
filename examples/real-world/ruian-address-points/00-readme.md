# RÚIAN address points — a zipped CSV-per-municipality export

[← all examples](../../README.md)

**What.** The Czech state address register (RÚIAN) is published as a single ZIP
holding one Windows-1250, semicolon-delimited CSV per municipality, all under a
`CSV/` folder inside the archive. bxp unpacks every member to a flat
intermediate CSV, transcodes Windows-1250 → UTF-8, keeps the date part of the
`Platí Od` timestamp, and rolls all municipalities into one clean
`1-ruian_adr-combined.csvx` ready for a Postgres `COPY` — from the raw `.zip`,
in one run, no pre-unzip step.

**Why interesting.** Government open-data registers ship as a _zip of many
encoded CSVs_, not one tidy UTF-8 file: a legacy code page, a European
delimiter, an in-archive folder prefix, and hundreds-to-thousands of members.
bxp's `zip_input` pre-pass turns that whole archive into the input — and it
**unpacks the members in parallel**, so on the full national dataset the unzip
step is the opposite of a bottleneck (numbers below).

**Problem class documented in.** RÚIAN (Registr územní identifikace, adres a
nemovitostí) is published by ČÚZK — the Czech Office for Surveying, Mapping and
Cadastre — as open data via the VDP portal
(<https://vdp.cuzk.cz/vdp/ruian/vymennyformat>). The address-points export
`*_OB_ADR_csv.zip` carries one `OB_<obec>_ADR.csv` per municipality under a
`CSV/` directory, in Windows-1250 with `;` separators — the shape reproduced by
`sample.zip` here (5 real municipalities, 338 address points).

**The trick.** Three template keys do the archive handling, no code:

- `zip_input: { entry_pattern: ".csv" }` — before the main loop, unpack every
  `*.zip` in `data_dir`. `dir_mode` defaults to `basename`, which **flattens**
  the in-archive `CSV/20260531_OB_500101_ADR.csv` path to a bare filename
  (`keep_path` would instead join the path with a separator). The unpack is
  parallelised across CPU cores — independent members, one inflate window per
  worker.
- `csv_input_encoding: "windows-1250"` + `csv_delimiter_in: ";"` — decode each
  field to UTF-8 and split on `;`. The output is plain UTF-8 CSV.
- `combined_output: true` — additionally append every file's rows into one
  merged `1-ruian_adr-combined.csvx`.

Plus a date trim — `DATE_CONVERT([Platí Od], 'YYYY-MM-DD[*]', 'YYYY-MM-DD')` —
where `[*]` swallows the `T00:00:00` time suffix, keeping the ISO date.

**Run it.**

```sh
bxp-cli --config ./sample.json --template ruian_adr
```

This unpacks `sample.zip` into per-municipality CSVs, converts each, and writes
the merged `1-ruian_adr-combined.csvx`.

**Smoking gun.** The raw member is Windows-1250 with a `CSV/` prefix and a
timestamp:

```text
CSV/20260531_OB_500101_ADR.csv  (Windows-1250, ';'-delimited)
11915692;500101;Bra\x9eec;…;…;36471;835804.84;1019584.24;2016-01-01T00:00:00
```

becomes one clean UTF-8 row, diacritics and all, date trimmed:

```csv
adm_code,municipality_code,municipality,municipality_part,street,house_number,orientation_number,postcode,coord_y,coord_x,valid_from
11915692,500101,Bražec,Dolní Valov,,1,,36471,835804.84,1019584.24,2016-01-01
```

**Scale (full national export).** The complete `*_OB_ADR_csv.zip` is **6 258
municipalities = 354 MB of CSV** packed into a **63 MB** deflate archive →
**3 017 760 address rows** in the combined output. On an 8-core desktop (shipped
ReleaseSmall build) bxp converts it end-to-end from the single `.zip` — parallel
unpack, Windows-1250 transcode, date trim, and combined roll-up — in **~10 s** at
**flat ~28 MB RSS** (streaming inflate, one window per worker — no whole-archive
or whole-file materialisation). The parallel unpack is where it pulls ahead of a
serial `unzip`: measured on its own on a 4-core / 8-thread laptop (i7-7920HQ) the
unpack step runs in **~0.50 s vs ~2.5 s single-threaded (~5×)** — 6 258
independent members are embarrassingly parallel, and a
work-stealing job queue load-balances the very uneven per-municipality sizes.
The committed `sample.zip` is a 5-municipality slice so the example stays small;
the full set is the public ČÚZK export linked above.
