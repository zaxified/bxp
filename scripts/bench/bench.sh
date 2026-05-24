#!/usr/bin/env bash
#
# BXP stress-test matrix runner.
#
# For each (sweep, N, C, cell_width, expr, trace) point:
#   1. gen.py emits a synthetic input.in.csv + bxp-cli.json under $WORK/<key>/
#   2. bxp-cli runs under `/usr/bin/time -f '%e %M'` + per-run timeout
#   3. wall_s, RSS, output bytes, trace event count/bytes go to the per-run
#      sidecar result file; a final sweep collects them in matrix order.
#
# Output: scripts/bench/results/results-<UTC-timestamp>.csv
#
# Env overrides:
#   BENCH_WORK        work dir for per-run inputs/outputs
#                     (default scripts/bench/work — same FS as repo, not tmpfs)
#   BENCH_TIMEOUT     per-run wall-time cap in seconds (default 120)
#   BENCH_PARALLEL    number of run_one workers to dispatch concurrently
#                     (default 1 — serial)
#                     NOTE: RSS is per-process and unaffected by parallelism;
#                     wall_s may inflate under CPU contention but the relative
#                     order across sweep points remains usable. Recommended
#                     <= number of physical cores.
#   BENCH_SKIP_BUILD  set to 1 to skip the ReleaseFast rebuild at start
#                     (default off — every run begins with a fresh build to
#                     prevent stale or accidental Debug binaries from
#                     skewing numbers)
#
# Sweep points are dispatched in ascending order of predicted duration so a
# total-time cap (set externally via `timeout`) cuts only the longest tail
# rather than the middle of the matrix.
#
# Per-run dirs under $WORK are wiped immediately after measurement so disk
# usage stays bounded. Trace output is piped through `wc -lc` and never
# written to disk; only the event count + byte total are kept.
#
# Exit-code conventions for failed runs (written into wall_s column):
#   TIMEOUT        rc=124 (timeout fired)
#   KILLED-<rc>    rc>=128 (SIGKILL e.g. OOM)
#   ERR-<rc>       any other non-zero
#
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BXP_CLI="$REPO_ROOT/bxp-cli/zig-out/bin/bxp-cli"
GEN="$SCRIPT_DIR/gen.py"
WORK="${BENCH_WORK:-$SCRIPT_DIR/work}"
RESULTS_DIR="$SCRIPT_DIR/results"
TIMEOUT_SEC="${BENCH_TIMEOUT:-120}"
PARALLEL="${BENCH_PARALLEL:-1}"

# Always (re)build ReleaseFast unless explicitly skipped — protects against
# a stale Debug binary lingering from interactive dev (a Debug build is
# 10-50× slower in Zig and silently torpedoes every wall-time number).
if [ "${BENCH_SKIP_BUILD:-0}" != "1" ]; then
  echo "building bxp-cli ReleaseFast …"
  ( cd "$REPO_ROOT/bxp-cli" && zig build -Doptimize=ReleaseFast ) || {
    echo "build failed — aborting" >&2; exit 1;
  }
fi

if [ ! -x "$BXP_CLI" ]; then
  echo "bxp-cli binary missing at $BXP_CLI" >&2
  echo "build manually with: (cd bxp-cli && zig build -Doptimize=ReleaseFast)" >&2
  exit 1
fi

# Sanity guard: a ReleaseFast bxp-cli is ~5 MB; a Debug build is ~20+ MB.
# Refuse to run on anything that looks like Debug — silent perf regression
# is the failure mode this whole script exists to detect.
BIN_BYTES=$(stat -c '%s' "$BXP_CLI")
if [ "$BIN_BYTES" -gt 10485760 ]; then
  bin_mb=$(awk -v b="$BIN_BYTES" 'BEGIN { printf "%.1f", b/1048576 }')
  echo "binary too large ($bin_mb MB > 10 MB) — likely a Debug build" >&2
  echo "rebuild: (cd bxp-cli && zig build -Doptimize=ReleaseFast)" >&2
  exit 1
fi

mkdir -p "$RESULTS_DIR" "$WORK"
TS="$(date -u +%Y%m%d-%H%M%S)"
OUT="$RESULTS_DIR/results-$TS.csv"
LINES_DIR="$WORK/lines-$TS"
mkdir -p "$LINES_DIR"

CACHE_ROOT="$WORK/cache"
mkdir -p "$CACHE_ROOT"

echo "writing → $OUT (parallel=$PARALLEL, timeout=${TIMEOUT_SEC}s/run)"

# Generate (input.in.csv + bxp-cli.json) once per (N, C, cell_w, expr) combo
# under $CACHE_ROOT/<key>/. Concurrent callers serialise via flock per key
# so a 670 MB CSV is generated exactly once even with 8 parallel workers.
# Inputs are independent of `trace` (config differs only in the --trace
# runtime flag, not the JSON), so trace on/off share the same cache entry.
ensure_cache() {
  local n="$1" c="$2" w="$3" expr="$4"
  local cache_key="gen-n${n}-c${c}-w${w}-${expr}"
  local cache_dir="$CACHE_ROOT/$cache_key"
  local tmp_dir="${cache_dir}.partial"
  mkdir -p "$cache_dir"
  (
    flock 200
    if [ ! -f "$cache_dir/input.in.csv" ] || [ ! -f "$cache_dir/bxp-cli.json" ]; then
      # Generate to a sidecar .partial dir, then atomically move into
      # cache_dir. If killed mid-gen, no partial file ever appears in
      # cache_dir, so the next run repeats from scratch instead of
      # consuming a truncated input.
      rm -f "$tmp_dir"/input.in.csv "$tmp_dir"/bxp-cli.json 2>/dev/null
      mkdir -p "$tmp_dir"
      local gen_args=( --rows "$n" --cols "$c" --cell-width "$w" --out-dir "$tmp_dir" )
      [ "$expr" = "passthrough" ] && gen_args+=( --passthrough-only )
      python3 "$GEN" "${gen_args[@]}"
      mv "$tmp_dir/input.in.csv" "$cache_dir/input.in.csv"
      mv "$tmp_dir/bxp-cli.json" "$cache_dir/bxp-cli.json"
      rmdir "$tmp_dir" 2>/dev/null
    fi
  ) 200>"$cache_dir/.lock"
  printf '%s' "$cache_dir"
}
export -f ensure_cache
export CACHE_ROOT

# Args: <matrix_idx> <sweep> <n> <c> <w> <expr> <trace>
# Writes one CSV line to $LINES_DIR/<matrix_idx>.csv on completion.
run_one() {
  local matrix_idx="$1" sweep="$2" n="$3" c="$4" w="$5" expr="$6" trace="$7"
  local run_dir="$WORK/run-${matrix_idx}-${sweep}-n${n}-c${c}-w${w}-${expr}-tr${trace}"
  rm -f "$run_dir"/input.in.csv \
        "$run_dir"/bxp-cli.json \
        "$run_dir"/input.out.csv \
        "$run_dir"/time.txt \
        "$run_dir"/trace.stats 2>/dev/null
  mkdir -p "$run_dir"

  local cache_dir
  cache_dir=$(ensure_cache "$n" "$c" "$w" "$expr")
  # Symlink input + config from cache so bxp-cli sees them in run_dir
  # (`data_dir: "."` in the config resolves to the config's parent dir,
  # i.e. the run_dir, so each run gets a clean output namespace).
  ln -sf "$cache_dir/input.in.csv" "$run_dir/input.in.csv"
  ln -sf "$cache_dir/bxp-cli.json" "$run_dir/bxp-cli.json"

  local cli_args=( --config "$run_dir/bxp-cli.json" )
  if [ "$trace" = "on" ]; then
    cli_args+=( --trace )
  else
    cli_args+=( --quiet )
  fi
  local time_file="$run_dir/time.txt"
  local trace_stats="$run_dir/trace.stats"
  local rc=0

  # Experimental knobs (bench-only):
  #   BXP_BENCH_SINK=devnull   — drop trace stream to /dev/null instead of
  #                              piping through `wc -lc`. Lets a matrix
  #                              measure encoding + write cost without the
  #                              wc count overhead. trace_events / trace_bytes
  #                              become 0 in this mode.
  local sink_mode="${BXP_BENCH_SINK:-wc}"

  if [ "$trace" = "on" ]; then
    if [ "$sink_mode" = "devnull" ]; then
      /usr/bin/time -f '%e %M' -o "$time_file" \
        timeout "$TIMEOUT_SEC" "$BXP_CLI" "${cli_args[@]}" >/dev/null 2>/dev/null || rc=$?
    else
      /usr/bin/time -f '%e %M' -o "$time_file" \
        timeout "$TIMEOUT_SEC" "$BXP_CLI" "${cli_args[@]}" 2>/dev/null \
        | wc -lc > "$trace_stats"
      rc="${PIPESTATUS[0]}"
    fi
  else
    /usr/bin/time -f '%e %M' -o "$time_file" \
      timeout "$TIMEOUT_SEC" "$BXP_CLI" "${cli_args[@]}" >/dev/null 2>/dev/null || rc=$?
  fi

  local wall="0" rss="0"
  if [ -s "$time_file" ]; then
    read -r wall rss < "$time_file"
  fi
  local rss_mb
  rss_mb=$(awk -v k="$rss" 'BEGIN { printf "%.1f", k/1024 }')

  local out_bytes=0
  local out_file
  out_file=$(ls "$run_dir"/*.out.csv 2>/dev/null | head -1)
  [ -n "$out_file" ] && out_bytes=$(stat -c '%s' "$out_file")

  local trace_events=0 trace_bytes=0
  if [ -s "$trace_stats" ]; then
    read -r trace_events trace_bytes < "$trace_stats"
  fi

  if [ "$rc" -eq 124 ]; then
    wall="TIMEOUT"
  elif [ "$rc" -ge 128 ]; then
    wall="KILLED-$rc"
  elif [ "$rc" -ne 0 ]; then
    wall="ERR-$rc"
  fi

  local line="$sweep,$n,$c,$w,$expr,$trace,$wall,$rss_mb,$out_bytes,$trace_events,$trace_bytes"
  printf '%s\n' "$line" > "$LINES_DIR/${matrix_idx}.csv"
  printf '[%s] %s\n' "$matrix_idx" "$line"

  rm -f "$run_dir"/input.in.csv \
        "$run_dir"/bxp-cli.json \
        "$run_dir"/input.out.csv \
        "$run_dir"/time.txt \
        "$run_dir"/trace.stats 2>/dev/null
  rmdir "$run_dir" 2>/dev/null
}
export -f run_one
export BXP_CLI GEN LINES_DIR TIMEOUT_SEC WORK

# --- Job table (matrix order + heuristic predicted duration) -----------------
#
# Predictor (very rough): wall ∝ N · max(1, C/16) · (cell_w/20) · trace_factor
# Calibrated against the post-refactor baseline. The exact value does not
# matter for correctness — it is only used to put the longest runs LAST so a
# total-time cap loses tail entries rather than middle ones.
predict() {
  local n="$1" c="$2" w="$3" trace="$4"
  local tf=1; [ "$trace" = "on" ] && tf=3
  local c_eff="$c"
  [ "$c" -lt 16 ] && c_eff=16
  awk -v n="$n" -v c="$c_eff" -v w="$w" -v tf="$tf" \
    'BEGIN { printf "%.3f", (n/100000.0) * (c/16.0) * (w/20.0) * tf * 2.5 }'
}

JOBS_FILE="$WORK/jobs-$TS.txt"
> "$JOBS_FILE"
midx=0
add_job() {
  local sweep="$1" n="$2" c="$3" w="$4" expr="$5" trace="$6"
  midx=$((midx + 1))
  local idx_str
  idx_str=$(printf '%03d' "$midx")
  local pred
  pred=$(predict "$n" "$c" "$w" "$trace")
  # Format: <predicted>\t<idx> <sweep> <n> <c> <w> <expr> <trace>
  printf '%s\t%s %s %s %s %s %s %s\n' "$pred" "$idx_str" "$sweep" "$n" "$c" "$w" "$expr" "$trace" >> "$JOBS_FILE"
}

# S1: rows sweep, trace off
for n in 5000 25000 100000 500000 2000000; do add_job S1 "$n" 16 20 3expr off; done
# S2: rows sweep + trace
for n in 5000 25000 100000 500000; do add_job S2 "$n" 16 20 3expr on; done
# S3: cols sweep, trace off
for c in 4 16 64 256 1024; do add_job S3 100000 "$c" 20 3expr off; done
# S4: cols sweep + trace
for c in 4 16 64 256; do add_job S4 100000 "$c" 20 3expr on; done
# S5: cell-width sweep (N reduced to 25k so cell_w=1000 stays under ~300 MB CSV)
for w in 10 100 1000; do add_job S5 25000 16 "$w" 3expr off; done
# S6: expr overhead — passthrough vs 3-expr at baseline (off + on)
add_job S6 100000 16 20 passthrough off
add_job S6 100000 16 20 3expr       off
add_job S6 100000 16 20 passthrough on
add_job S6 100000 16 20 3expr       on

echo "matrix has $midx points; dispatching in shortest-first order"

# Sort by predicted duration ascending; strip the predictor column; dispatch.
sort -n "$JOBS_FILE" | cut -f2- | \
  xargs -P "$PARALLEL" -L 1 bash -c 'run_one "$@"' --

# --- Stitch result lines in matrix order -------------------------------------
{
  echo "sweep,n_rows,n_cols,cell_w,expr,trace,wall_s,rss_mb,out_bytes,trace_events,trace_bytes"
  # Numeric-sort by the leading idx in each filename so matrix order is preserved.
  for f in $(ls "$LINES_DIR"/*.csv 2>/dev/null | sort -V); do
    cat "$f"
  done
} > "$OUT"

# Per-run sidecars: keep them under $WORK/lines-* for inspection until the next
# bench overwrites them. Bench cleanup is intentionally minimal here.
echo
done_count=$(ls "$LINES_DIR"/*.csv 2>/dev/null | wc -l)
echo "Done. $done_count/$midx points collected. Results: $OUT"
