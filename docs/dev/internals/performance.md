# Performance

## Performance model

A simplified map of what makes the runtime fast and what slows it down, plus
where the benchmarks live. The whole model rests on one invariant: **every
output row is a pure function of one input row plus the (already-built)
pre_pass lookup table** — no cross-row state in the main loop. That purity is
what unlocks streaming, parallelism, and parse-once below.

**What speeds it up** (roughly in order of impact):

- **Streaming + bounded memory.** `processBroker` reads CSV in
  `CHUNK_SIZE = 10 MiB` blocks (`ChunkReader`) and resets a per-chunk arena
  between blocks; JSON streams through `std.json.Reader` in a two-pass design.
  Peak RSS is `O(longest row + pre_pass table)`, **not** `O(file size)` — a
  non-streaming design would grow RSS `O(N)` (~10 GB on 2M rows); streaming
  holds it to a small constant (~24 MB across the bench matrix).
- **Per-block parallel evaluation.** Rows within a chunk are independent, so
  they fan out across a `std.Thread.Pool` and re-stitch in source order — see
  [architecture/pipeline.md → Parallel Evaluation](../architecture/pipeline.md#parallel-evaluation-per-block-fork-join).
- **Parse-once expression eval.** `input_schema` and `row_rules`
  expressions are tokenized/parsed **once per file** into `compiled_schema` /
  `compiled_rules` `Node` arrays (`pipeline.zig`), then evaluated per row
  without re-parsing.
- **Constant folding.** Row-invariant `input_schema` vars (no column / field
  reference) are evaluated once at file-start and reused for every row
  (`folded_vars`).
- **Skip dead work.** The `date_fast_path` evaluates `$date` first and drops
  an out-of-range row **before** `evalAllVars` when `date_filter_from_filename`
  is on; a var that a matched rule overrides skips its base evaluation (the
  override supplies the value).
- **Free passthrough.** A field copied straight to output never routes through
  the numeric core — it keeps full precision _and_ pays no parse cost. Only
  genuinely _computed_ numbers go through the `decimal` module (fixed-point `i128`,
  exact, float-free).
- **`memchr`-based scanning.** CSV record/field boundaries are found with
  `std.mem.indexOfScalar` / `lastIndexOfScalar` (lazy-quotes parser), 12–41 %
  faster than the prior byte loop on large inputs.

**What slows it down** (cost factors to expect):

- **`--trace`** emits a BXTB metadata frame per output/filtered/error row —
  budget extra IO for dry-runs vs a plain conversion.
- **ReleaseSmall** (the shipped console binary) is ~1.3–1.7× slower than
  `ReleaseFast` on compute-heavy runs — see the table below.
- **Wide columns** cost `O(cols)` per row (field split + `col_index` lookups);
  a 1024-col file is dominated by per-row column work, not codegen.
- **Heavy computed arithmetic** (vs passthrough) routes every value through the
  decimal core; lots of `ROUND` / `*` / `/` per row shows up here.
- **Debug builds** are 10–50× slower with a different RSS profile — never
  perf-measure a `zig build` (Debug) artifact; build `-Doptimize=ReleaseFast`.

**Benchmarking.** Two harnesses, different jobs:

- **`scripts/bench/bench.sh`** — the stress-test matrix. Sweeps rows / columns
  / cell-width / expr-count / trace on/off (`S1`–`S6`); `gen.py` emits a
  synthetic `input.in.csv` + `bxp-cli.json` per point; each run self-measures
  wall + peak RSS via bxp-cli's `BXP_METRICS` env var (opt-in; emits one
  `bxp-metrics wall_ms=… peak_rss_kb=…` line to stderr), so the matrix runs
  cross-platform without GNU `/usr/bin/time`. Output → `scripts/bench/results/results-<UTC>.csv`
  (columns: `wall_s`, RSS, output bytes, trace event count/bytes). It rebuilds
  `ReleaseFast` first; knobs: `BENCH_WORK`, `BENCH_TIMEOUT`, `BENCH_PARALLEL`,
  `BENCH_SKIP_BUILD`. Dev-only — **not** part of `test.sh`.
- **`scripts/test-05-bench-guard.sh`** — the coarse perf gate, a `test.sh`
  phase. Asserts only two **machine-independent** invariants so it can't flake
  on absolute seconds: an **RSS ceiling** (`GUARD_RSS_MB`, default 64 MB —
  catches any regression back to `O(N)` buffering) and a **scaling ratio**
  (`wall(large N) / wall(small N)` must stay near the row ratio — catches an
  accidental `O(n²)` path). Recycles the Console phase's `ReleaseSafe` bxp-cli
  (same package cache → no second build, just the measured runs); the whole
  suite is one mode, so the guard measures the same codegen the tests do.
- **`scripts/bench/verify-output.sh`** — correctness, not speed: runs bxp-cli
  over `datasets/` + `docs/examples/real-world/` into a dir for a before/after
  `diff -r` (use around any optimization to prove output stays byte-identical).

---

## Release optimize mode (Small vs Fast)

`scripts/release-01-console.sh` builds bxp-cli with `-Doptimize=ReleaseSmall`.
The console archive ships the small binary by design — small downloads,
small docker layers, small footprint for users who run bxp-cli once a week
on a few-hundred-row broker export.

For perf-critical local runs (large CSVs, repeated batch processing) you can
rebuild with `zig build -Doptimize=ReleaseFast`. Measured deltas on
representative synthetic workloads (serial, warm cache, NVMe-backed, 3 reps
each, median wall-clock):

| Scenario                                                | Profile          | Small  | Fast   | Speedup |
| ------------------------------------------------------- | ---------------- | ------ | ------ | ------- |
| 100k rows × 1024 cols, w=20 (2.0 GB CSV, per-block ‖)   | wide-cols, ‖ CPU | 22.59s | 17.24s | 1.31×   |
| 2M rows × 16 cols, w=20 (551 MB CSV, reader-bound)      | row-heavy        | 9.82s  | 5.99s  | 1.64×   |
| 100k rows × 16 cols, w=20 (28 MB CSV, passthrough only) | minimal work     | 0.39s  | 0.23s  | 1.70×   |

Binary size cost: 377 KB → 5.5 MB (≈ 15×). RSS in both modes is identical
(within measurement noise; ~24 MB across all three scenarios).

The wide-cols parallel path benefits the **least** from ReleaseFast because
it is dominated by per-block synchronization and IO rather than per-row
codegen quality. The minimal-work passthrough benefits the **most** because
fixed-cost dispatch overhead is where codegen quality shows up cleanest.

Bench artifacts: `scripts/bench/work/rsrf/` (driver + per-run CSV).
Reproduce via `scripts/bench/work/rsrf/run.sh` after generating inputs with
`python3 scripts/bench/gen.py`.
