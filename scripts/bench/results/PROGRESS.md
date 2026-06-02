# Bench progress — wall (s) per session

Run on the same machine. Per-cell value = wall-time seconds (BENCH_PARALLEL=1 for
S05+; earlier sessions may have used parallel scheduling, so absolute S01-S04
numbers are noisier — but the trend across S05 → S13 is the meaningful arc).

## Session legend

| #   | When       | What                             |
| --- | ---------- | -------------------------------- |
| S01 | 17/05-1652 | M0: bench harness landed         |
| S02 | 17/05-1945 | post-refactor (verify-output)    |
| S03 | 17/05-2109 | ChunkReader right-size buffer    |
| S04 | 17/05-2252 | sort+parallel+atomic input cache |
| S05 | 17/05-2307 | M9: row_buf fix (RowIterator)    |
| S06 | 18/05-1644 | pre fast-path baseline (HEAD~4)  |
| S07 | 18/05-1714 | Phase A — row_start Safe fields  |
| S08 | 18/05-1718 | comptime monomorph splitFields   |
| S09 | 18/05-1722 | Phase A+B+C                      |
| S10 | 18/05-1729 | rule_match refactor              |
| S11 | 18/05-2344 | M12: --trace=bin opt-in via env  |
| S12 | 22/05-0100 | schema-v3: detail emit gated off |
| S13 | 24/05-0245 | NDJSON rip: --trace = BIN only   |
| S14 | 24/05-1958 | per-block parallel CSV pipeline  |
| S15 | 24/05-2110 | sunrise vendor: DATE_CONVERT FBA |
| S16 | 02/06-0643 | sunrise removed → in-house datefmt.zig |

## Wall time (seconds)

| sweep point                                    | S01  | S02  | S03  | S04  | S05  | S06  | S07  | S08  | S09  | S10  | S11  | S12  | S13  |  S14 |   S15 |
| ---------------------------------------------- | ---- | ---- | ---- | ---- | ---- | ---- | ---- | ---- | ---- | ---- | ---- | ---- | ---- | ---: | ----: |
| `S1 n= 100000 c=  16 w=  20 3expr       t=off` | 2.44 | 2.20 | 2.65 | 4.18 | 4.34 | 4.62 | 4.94 | 4.23 | 4.83 | 3.70 | 4.41 | 2.96 | 2.27 | 1.36 |  0.35 |
| `S1 n=2000000 c=  16 w=  20 3expr       t=off` | 44.1 | 38.3 | 46.2 | 54.1 | 67.4 | 68.7 | 69.3 | 64.3 | 64.9 | 66.6 | 60.5 | 59.4 | 42.1 | 26.7 |  6.52 |
| `S1 n=  25000 c=  16 w=  20 3expr       t=off` | 0.56 | 0.58 | 0.74 | 1.38 | 0.92 | 1.41 | 1.18 | 1.59 | 1.59 | 1.30 | 1.48 | 0.94 | 0.63 | 0.36 |  0.10 |
| `S1 n=   5000 c=  16 w=  20 3expr       t=off` | 0.11 | 0.11 | 0.16 | 0.19 | 0.32 | 0.27 | 0.34 | 0.27 | 0.24 | 0.32 | 0.26 | 0.21 | 0.12 | 0.09 |  0.02 |
| `S1 n= 500000 c=  16 w=  20 3expr       t=off` | 11.1 | 9.56 | 11.1 | 21.7 | 21.3 | 19.1 | 23.7 | 21.6 | 20.3 | 23.9 | 21.1 | 16.2 | 10.8 | 6.94 |  1.70 |
| `S2 n= 100000 c=  16 w=  20 3expr       t=on`  | 6.23 | 6.12 | 7.77 | 17.7 | 19.2 | 18.3 | 16.4 | 17.2 | 15.6 | 16.6 | 4.42 | 8.18 | 2.26 | 1.33 |  0.39 |
| `S2 n=  25000 c=  16 w=  20 3expr       t=on`  | 1.43 | 1.59 | 2.15 | 4.30 | 5.25 | 6.13 | 4.29 | 4.63 | 4.43 | 4.64 | 1.31 | 1.80 | 0.63 | 0.38 |  0.10 |
| `S2 n=   5000 c=  16 w=  20 3expr       t=on`  | 0.28 | 0.33 | 0.39 | 1.08 | 1.03 | 0.85 | 0.79 | 0.79 | 0.76 | 0.81 | 0.20 | 0.45 | 0.15 | 0.08 |  0.02 |
| `S2 n= 500000 c=  16 w=  20 3expr       t=on`  | 29.9 | 29.9 | 35.8 | 54.3 | 59.1 | 62.0 | 55.6 | 50.7 | 50.6 | 53.4 | 20.0 | 40.9 | 10.5 | 6.63 |  1.64 |
| `S3 n= 100000 c=1024 w=  20 3expr       t=off` | —    | 48.4 | —    | 65.0 | 81.3 | 86.9 | 88.2 | 80.5 | 81.9 | 88.5 | 77.7 | 78.5 | 65.4 | 18.0 | 18.32 |
| `S3 n= 100000 c=  16 w=  20 3expr       t=off` | 2.18 | 2.19 | 2.65 | 4.59 | 5.03 | 4.56 | 4.70 | 4.37 | 4.21 | 4.36 | 4.77 | 2.81 | 2.23 | 1.50 |  0.33 |
| `S3 n= 100000 c= 256 w=  20 3expr       t=off` | 12.8 | 12.7 | 16.5 | 20.8 | 26.8 | 28.5 | 27.9 | 26.5 | 27.0 | 30.6 | 27.7 | 23.9 | 16.9 | 4.76 |  4.60 |
| `S3 n= 100000 c=   4 w=  20 3expr       t=off` | 1.79 | 1.88 | 1.89 | 2.61 | 2.92 | 3.08 | 4.09 | 2.92 | 2.74 | 3.41 | 3.45 | 2.04 | 1.36 | 1.31 |  0.15 |
| `S3 n= 100000 c=  64 w=  20 3expr       t=off` | 4.27 | 3.91 | 5.29 | 9.37 | 10.2 | 10.8 | 9.14 | 8.58 | 8.99 | 8.97 | 9.95 | 7.19 | 4.96 | 1.96 |  1.24 |
| `S4 n= 100000 c=  16 w=  20 3expr       t=on`  | 6.39 | 6.14 | —    | 19.2 | 18.9 | 18.2 | 16.1 | 16.2 | 15.9 | 16.9 | 4.97 | 7.96 | 2.15 | 1.33 |  0.38 |
| `S4 n= 100000 c= 256 w=  20 3expr       t=on`  | 66.5 | —    | —    | 87.9 | 98.8 | 106  | 89.2 | 82.1 | 82.0 | 86.2 | 27.9 | 72.9 | 17.5 | 4.95 |  4.61 |
| `S4 n= 100000 c=   4 w=  20 3expr       t=on`  | 3.60 | 3.79 | —    | 9.82 | 9.65 | 10.5 | 8.08 | 9.40 | 9.68 | 9.52 | 2.81 | 4.39 | 1.57 | 1.19 |  0.17 |
| `S4 n= 100000 c=  64 w=  20 3expr       t=on`  | 17.9 | 17.1 | —    | 38.7 | 42.4 | 44.8 | 36.5 | 36.1 | 35.6 | 37.6 | 10.6 | 22.9 | 5.00 | 1.74 |  1.24 |
| `S5 n=  25000 c=  16 w=  10 3expr       t=off` | 0.63 | 0.57 | —    | 1.09 | 1.43 | 1.12 | 1.22 | 0.91 | 1.32 | 0.99 | 1.34 | 0.81 | 0.58 | 0.39 |  0.11 |
| `S5 n=  25000 c=  16 w= 100 3expr       t=off` | 0.71 | 0.68 | —    | 1.26 | 1.58 | 1.55 | 1.50 | 1.10 | 2.08 | 1.52 | 1.48 | 0.93 | 0.98 | 0.48 |  0.24 |
| `S5 n=  25000 c=  16 w=1000 3expr       t=off` | 2.35 | 1.91 | —    | 4.93 | 5.45 | 5.80 | 6.33 | 6.21 | 6.96 | 5.65 | 6.75 | 5.25 | 3.48 | 1.53 |  1.51 |
| `S6 n= 100000 c=  16 w=  20 3expr       t=off` | 2.47 | 2.23 | —    | 4.58 | 4.58 | 4.73 | 4.71 | 4.27 | 3.42 | 4.34 | 5.38 | 3.13 | 2.32 | 1.45 |  0.41 |
| `S6 n= 100000 c=  16 w=  20 3expr       t=on`  | 6.19 | 6.27 | —    | 18.6 | 18.4 | 18.5 | 15.9 | 15.9 | 16.0 | 16.5 | 5.18 | 8.29 | 2.31 | 1.31 |  0.43 |
| `S6 n= 100000 c=  16 w=  20 passthrough t=off` | 1.04 | 0.98 | —    | 1.73 | 1.43 | 1.94 | 1.65 | 1.84 | 1.64 | 1.52 | 1.71 | 1.38 | 0.88 | 0.34 |  0.33 |
| `S6 n= 100000 c=  16 w=  20 passthrough t=on`  | 4.47 | 4.26 | —    | 12.5 | 12.0 | 13.6 | 10.4 | 10.5 | 10.0 | 11.9 | 1.54 | 5.04 | 0.91 | 0.30 |  0.28 |

## RSS peak (MB)

| sweep point                                    | S01   | S02  | S03  | S04  | S05  | S06  | S07  | S08  | S09  | S10  | S11  | S12  | S13  |
| ---------------------------------------------- | ----- | ---- | ---- | ---- | ---- | ---- | ---- | ---- | ---- | ---- | ---- | ---- | ---- |
| `S1 n= 100000 c=  16 w=  20 3expr       t=off` | 488   | 258  | 258  | 13.1 | 13.1 | 13.0 | 13.0 | 13.1 | 13.1 | 13.0 | 12.1 | 13.2 | 13.0 |
| `S1 n=2000000 c=  16 w=  20 3expr       t=off` | 10067 | 178  | 178  | 13.0 | 13.0 | 13.1 | 13.0 | 13.0 | 13.1 | 13.0 | 13.2 | 13.2 | 13.1 |
| `S1 n=  25000 c=  16 w=  20 3expr       t=off` | 125   | 107  | 107  | 9.10 | 9.10 | 9.10 | 9.10 | 9.10 | 9.10 | 9.10 | 9.20 | 9.10 | 9.00 |
| `S1 n=   5000 c=  16 w=  20 3expr       t=off` | 26.5  | 22.0 | 22.0 | 2.50 | 2.50 | 2.40 | 2.50 | 2.50 | 2.50 | 2.50 | 2.60 | 2.60 | 2.50 |
| `S1 n= 500000 c=  16 w=  20 3expr       t=off` | 2439  | 255  | 255  | 13.1 | 13.1 | 13.0 | 13.1 | 13.0 | 13.0 | 13.1 | 13.1 | 13.2 | 13.1 |
| `S2 n= 100000 c=  16 w=  20 3expr       t=on`  | 488   | 258  | 258  | 13.1 | 13.1 | 12.0 | 13.1 | 13.0 | 13.1 | 13.0 | 13.1 | 13.2 | 13.1 |
| `S2 n=  25000 c=  16 w=  20 3expr       t=on`  | 126   | 107  | 106  | 9.10 | 9.10 | 9.10 | 9.10 | 9.10 | 9.10 | 9.10 | 9.20 | 9.20 | 9.10 |
| `S2 n=   5000 c=  16 w=  20 3expr       t=on`  | 26.5  | 22.0 | 21.9 | 2.50 | 2.50 | 2.50 | 2.50 | 2.50 | 2.50 | 2.50 | 2.60 | 2.60 | 2.50 |
| `S2 n= 500000 c=  16 w=  20 3expr       t=on`  | 2439  | 255  | 255  | 12.9 | 13.1 | 13.0 | 13.0 | 13.1 | 13.0 | 13.1 | 13.1 | 13.1 | 13.1 |
| `S3 n= 100000 c=1024 w=  20 3expr       t=off` | 0.00  | 19.3 | —    | 11.7 | 11.7 | 11.6 | 11.6 | 11.6 | 11.7 | 11.7 | 11.8 | 11.9 | 11.6 |
| `S3 n= 100000 c=  16 w=  20 3expr       t=off` | 488   | 258  | 258  | 13.1 | 13.0 | 13.0 | 13.1 | 13.1 | 13.1 | 13.0 | 13.2 | 13.1 | 13.1 |
| `S3 n= 100000 c= 256 w=  20 3expr       t=off` | 1519  | 26.6 | 26.6 | 11.2 | 11.1 | 11.2 | 11.2 | 11.2 | 11.2 | 11.2 | 11.2 | 11.5 | 11.1 |
| `S3 n= 100000 c=   4 w=  20 3expr       t=off` | 412   | 400  | 400  | 9.20 | 9.20 | 9.20 | 9.10 | 9.20 | 9.20 | 9.00 | 7.50 | 9.40 | 9.10 |
| `S3 n= 100000 c=  64 w=  20 3expr       t=off` | 1029  | 53.4 | 53.3 | 11.4 | 11.4 | 11.4 | 11.4 | 11.4 | 11.4 | 11.4 | 11.4 | 11.5 | 11.4 |
| `S4 n= 100000 c=  16 w=  20 3expr       t=on`  | 488   | 258  | —    | 13.1 | 13.0 | 13.0 | 13.1 | 13.1 | 13.0 | 13.0 | 13.2 | 13.1 | 13.1 |
| `S4 n= 100000 c= 256 w=  20 3expr       t=on`  | 1519  | 0.00 | —    | 11.2 | 11.3 | 11.2 | 11.2 | 11.2 | 11.1 | 11.2 | 11.3 | 11.3 | 11.2 |
| `S4 n= 100000 c=   4 w=  20 3expr       t=on`  | 412   | 400  | —    | 9.20 | 9.10 | 9.20 | 9.20 | 9.20 | 9.20 | 9.10 | 9.40 | 9.40 | 9.20 |
| `S4 n= 100000 c=  64 w=  20 3expr       t=on`  | 1029  | 53.2 | —    | 11.4 | 11.4 | 11.4 | 11.4 | 11.2 | 11.4 | 11.2 | 11.5 | 11.5 | 11.4 |
| `S5 n=  25000 c=  16 w=  10 3expr       t=off` | 113   | 104  | —    | 6.20 | 6.20 | 6.10 | 6.20 | 6.20 | 6.20 | 6.20 | 6.40 | 6.40 | 6.20 |
| `S5 n=  25000 c=  16 w= 100 3expr       t=off` | 192   | 44.2 | —    | 11.4 | 11.4 | 11.4 | 11.2 | 11.4 | 11.4 | 11.4 | 11.5 | 11.4 | 11.4 |
| `S5 n=  25000 c=  16 w=1000 3expr       t=off` | 1090  | 14.4 | —    | 11.0 | 10.9 | 11.0 | 11.0 | 11.0 | 10.9 | 11.0 | 11.1 | 11.1 | 11.0 |
| `S6 n= 100000 c=  16 w=  20 3expr       t=off` | 488   | 258  | —    | 13.0 | 13.1 | 13.0 | 13.0 | 13.0 | 13.0 | 13.1 | 13.2 | 13.2 | 13.1 |
| `S6 n= 100000 c=  16 w=  20 3expr       t=on`  | 488   | 258  | —    | 12.9 | 13.0 | 13.1 | 13.0 | 12.0 | 13.1 | 13.0 | 13.1 | 13.1 | 13.1 |
| `S6 n= 100000 c=  16 w=  20 passthrough t=off` | 488   | 258  | —    | 13.0 | 13.1 | 13.0 | 13.1 | 13.0 | 13.0 | 13.0 | 13.1 | 13.1 | 13.0 |
| `S6 n= 100000 c=  16 w=  20 passthrough t=on`  | 488   | 258  | —    | 13.0 | 13.0 | 13.0 | 13.0 | 13.0 | 13.0 | 13.0 | 13.1 | 13.2 | 13.0 |

## Per-session totals (sum of wall_s across all 25 points)

| Session | Note                             | Total wall (s) | Δ vs S01 |
| ------- | -------------------------------- | -------------: | -------: |
| S01     | M0: bench harness landed         |          229.4 |      +0% |
| S02     | post-refactor (verify-output)    |          201.6 |     -12% |
| S03     | ChunkReader right-size buffer    |          133.3 |     -42% |
| S04     | sort+parallel+atomic input cache |          461.6 |    +101% |
| S05     | M9: row_buf fix (RowIterator)    |          519.7 |    +127% |
| S06     | pre fast-path baseline (HEAD~4)  |          541.7 |    +136% |
| S07     | Phase A — row_start Safe fields  |          502.2 |    +119% |
| S08     | comptime monomorph splitFields   |          472.8 |    +106% |
| S09     | Phase A+B+C                      |          472.7 |    +106% |
| S10     | rule_match refactor              |          499.9 |    +118% |
| S11     | M12: --trace=bin opt-in via env  |          306.9 |     +34% |
| S12     | schema-v3: detail emit gated off |          378.4 |     +65% |
| S13     | NDJSON rip: --trace = BIN only   |          198.0 |     -14% |
| S14     | per-block parallel CSV pipeline  |           86.5 |     -62% |
| S15     | sunrise vendor: DATE_CONVERT FBA |           45.2 |     -80% |

## S15 notes — sunrise vendor + FixedBufferAllocator for DATE_CONVERT

S14 left S1 row-heavy workloads (narrow columns, 1.58× speedup) on the
table. Profiling traced 2 million `mmap`+`munmap` pairs — one pair per
source row — to `sunrise.parse.parseWithFormat`, where the FormatToken
`ArrayList` allocator was hardcoded to `std.heap.page_allocator`.
Every `DATE_CONVERT` call (one per row in every real broker config) hit
the kernel twice.

Fix: vendor sunrise locally under `bxp-core/sunrise/`, switch
`parseWithFormat` to a stack-resident `FixedBufferAllocator(1 KiB)`.
Format strings never exceed ~20 tokens × 24 bytes per token, so the
1 KiB stack buffer never overflows. Zero syscalls, zero shared
allocator contention. Vendoring is temporary — upstream PR pending;
flip `bxp-core/build.zig.zon` back to the URL dep once it lands.

**Wall-time speedups vs S14:**

- S1 2M rows narrow: 26.7 → 6.52 s = **4.1×**
- S3 4 cols: 1.31 → 0.15 s = **8.7×** (DATE_CONVERT was the dominant cost)
- S2 500k + trace: 6.63 → 1.64 s = **4.0×**
- S6 3expr off: 1.45 → 0.41 s = **3.5×**
- S6 passthrough (no DATE_CONVERT): 0.34 → 0.33 s = **1.0×** (control — confirms the win comes from the date path)
- Total wall across 25 points: 86.5 → 45.2 s = **1.92× vs S14**
- Cumulative vs S13 baseline: 198 → 45.2 s = **4.38×**
- Cumulative vs S01 origin: 229.4 → 45.2 s = **5.08×**

Eval-bound workloads (S3 1024 cols, S5 cell_w=1000) stay flat because
DATE_CONVERT is one of many `input_schema` entries and its share of
the total per-row cost is small at high column counts.

**Verifikace:** `scripts/test.sh` 7/7 datasets byte-identical (the
date parser itself is unchanged — only the allocator behind it is
swapped, so output bytes match the baseline exactly).

## S14 notes — per-block parallel CSV pipeline

8-core bench machine; worker count `K = std.Thread.getCpuCount() = 8`.

**Wall-time speedups vs S13 baseline:**

- S1 2M rows (row-heavy, 16 cols): 42.1 → 26.7 s = **1.58×** (reader serial → moderate)
- S3 1024 cols: 65.4 → 18.0 s = **3.63×** (per-row work heavy → fork-join wins big)
- S4 256 cols + trace: 17.5 → 4.95 s = **3.54×**
- S2 500k + trace: 10.5 → 6.63 s = **1.58×**
- Total wall across all 25 points: 198 → 86.5 s = **2.29×** end-to-end

Column-heavy workloads (S3/S4 ≥ 64 cols) hit 2.5-3.6× because per-row eval
dominates and parallelises cleanly. Row-heavy workloads with narrow columns
(S1, S2) hit ~1.5-1.7× because the chunk reader stays single-threaded;
pipelined double-buffering (reader fills next chunk while workers process
current) is the natural follow-up if those become the new bottleneck.

**RSS impact:** typical per-file peak rose ~13 MB → ~25 MB. The delta is
the per-worker scratch (`line_arena` + `field_arena` + 4 × `Allocating`
buffers × 8 workers ≈ 12 MB amortised). Allocated once per template,
reused across files via `resetForFile`. Acceptable trade for the wall-time
win — peak RSS is still 400× smaller than the pre-2026-05-17 baseline
(10 GB on the same 2M-row sweep point).

**Byte-identity gate:** `scripts/test-02-datasets.sh` (`.csvx` + `.bin`
trace diff against committed `.expected` fixtures) stays green on all 7
shipping templates. The parallel path drains worker buffers in
worker-index order with patched btrace `outputIdx` so the resulting
streams match the serial baseline bit-for-bit.

## S16 notes — sunrise removed, in-house datefmt.zig (new baseline)

The vendored `sunrise` datetime library was replaced by `bxp-core/src/datefmt.zig`
(zero external deps; allocation-free stack tokenizer, same as the sunrise FBA
vendor patch). The 3expr workload's parser-heavy expression is a per-row
`DATE_CONVERT`, so this sweep directly measures the new date core.

Results (`results-20260602-064320.csv`, BENCH_PARALLEL=1, ReleaseFast):

| sweep point          |  S15 |  S16 |
| -------------------- | ---: | ---: |
| S1 2M rows (DATE_CONVERT-heavy) | 6.52 | 6.75 |
| Total wall (25 pts)  | 45.2 | 46.3 |
| Peak RSS             | ~25 MB | ~25 MB |

Flat within run-to-run noise (~2.5%): the in-house tokenizer matches the
vendored+patched sunrise on the hot path, as expected. **This is the new
post-sunrise baseline.** The pending-revert overhead (tracking an upstream PR,
re-vendoring on merge) is gone for good.
