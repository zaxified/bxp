# Bench comparison — NDJSON `--trace` → BIN BXTB `--trace`

Producer change: bxp-cli `--trace` previously emitted line-by-line
NDJSON; now emits a binary BXTB frame stream (metadata-only by default,
drill-down is recomputed on demand by `bxp-fmt --expr-batch`).

- **Old baseline**: `results-20260522-010048.csv` (pre-rip, NDJSON producer)
- **New numbers**: `results-20260524-024521.csv` (post-rip, BIN producer)
- Hardware: same machine, BENCH_PARALLEL=1 both runs (serial, no contention)

## Trace=ON points (where NDJSON → BIN matters)

| Point                             | Wall old → new             | Events old → new               | Bytes old → new                  |
| --------------------------------- | -------------------------- | ------------------------------ | -------------------------------- |
| S2 n=100000 c=16 w=20 3expr       | 8.18s → **2.26s** (-72%)   | 2.3M → **2.1K** (1071× fewer)  | 291.0M → **3.1M** (94× smaller)  |
| S2 n=25000 c=16 w=20 3expr        | 1.80s → **0.63s** (-65%)   | 575.0K → **786** (732× fewer)  | 72.7M → **775.3K** (94× smaller) |
| S2 n=5000 c=16 w=20 3expr         | 0.45s → **0.15s** (-67%)   | 115.0K → **540** (213× fewer)  | 14.5M → **155.3K** (93× smaller) |
| S2 n=500000 c=16 w=20 3expr       | 40.92s → **10.53s** (-74%) | 11.5M → **9.9K** (1160× fewer) | 1.46G → **15.5M** (94× smaller)  |
| S4 n=100000 c=16 w=20 3expr       | 7.96s → **2.15s** (-73%)   | 2.3M → **2.1K** (1071× fewer)  | 291.0M → **3.1M** (94× smaller)  |
| S4 n=100000 c=256 w=20 3expr      | 72.87s → **17.50s** (-76%) | 26.3M → **5.2K** (5010× fewer) | 4.04G → **3.1M** (1303× smaller) |
| S4 n=100000 c=4 w=20 3expr        | 4.39s → **1.57s** (-64%)   | 1.1M → **3.6K** (303× fewer)   | 106.2M → **3.1M** (34× smaller)  |
| S4 n=100000 c=64 w=20 3expr       | 22.93s → **5.00s** (-78%)  | 7.1M → **2.1K** (3378× fewer)  | 1.04G → **3.1M** (334× smaller)  |
| S6 n=100000 c=16 w=20 3expr       | 8.29s → **2.31s** (-72%)   | 2.3M → **2.1K** (1071× fewer)  | 291.0M → **3.1M** (94× smaller)  |
| S6 n=100000 c=16 w=20 passthrough | 5.04s → **0.91s** (-82%)   | 2.0M → **2.1K** (932× fewer)   | 246.2M → **3.1M** (79× smaller)  |

### Trace=ON totals

- **Wall**: 172.8s → **43.0s** (-75%, ~4.0× faster)
- **Events**: 55.6M → **30.8K** (1805× fewer)
- **Bytes**: 7.85G → **38.1M** (206× smaller)

## Trace=OFF points (no trace produced — measures baseline CLI speed)

Producer rip also removed pre-emit work that ran even when trace was off
(SymbolPools build, per-row out_values/out_safe lists, bin emit call sites).

| Point                             | Wall old → new             |
| --------------------------------- | -------------------------- |
| S1 n=100000 c=16 w=20 3expr       | 2.96s → **2.27s** (-23%)   |
| S1 n=2000000 c=16 w=20 3expr      | 59.37s → **42.14s** (-29%) |
| S1 n=25000 c=16 w=20 3expr        | 0.94s → **0.63s** (-33%)   |
| S1 n=5000 c=16 w=20 3expr         | 0.21s → **0.12s** (-43%)   |
| S1 n=500000 c=16 w=20 3expr       | 16.17s → **10.77s** (-33%) |
| S3 n=100000 c=1024 w=20 3expr     | 78.49s → **65.38s** (-17%) |
| S3 n=100000 c=16 w=20 3expr       | 2.81s → **2.23s** (-21%)   |
| S3 n=100000 c=256 w=20 3expr      | 23.89s → **16.91s** (-29%) |
| S3 n=100000 c=4 w=20 3expr        | 2.04s → **1.36s** (-33%)   |
| S3 n=100000 c=64 w=20 3expr       | 7.19s → **4.96s** (-31%)   |
| S5 n=25000 c=16 w=10 3expr        | 0.81s → **0.58s** (-28%)   |
| S5 n=25000 c=16 w=100 3expr       | 0.93s → **0.98s** (+5%)    |
| S5 n=25000 c=16 w=1000 3expr      | 5.25s → **3.48s** (-34%)   |
| S6 n=100000 c=16 w=20 3expr       | 3.13s → **2.32s** (-26%)   |
| S6 n=100000 c=16 w=20 passthrough | 1.38s → **0.88s** (-36%)   |

- **Off wall total**: 205.6s → **155.0s** (-25%)
