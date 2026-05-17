#!/usr/bin/env bash
#
# BXP stress-test matrix runner.
#
# For each (sweep, N, C, cell_width, expr, trace) point:
#   1. gen.py emits a synthetic input.in.csv + bxp-cli.json in /tmp/bxp-bench/...
#   2. bxp-cli runs under `/usr/bin/time -f '%e %M'` + 120s timeout
#   3. wall-time, peak RSS, output bytes, trace bytes are appended to results CSV
#
# Output: scripts/bench/results/results-<UTC-timestamp>.csv
#
# Env overrides:
#   BENCH_WORK     work dir for per-run inputs/outputs (default /tmp/bxp-bench)
#   BENCH_TIMEOUT  per-run wall-time cap in seconds (default 120)
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
WORK="${BENCH_WORK:-/tmp/bxp-bench}"
RESULTS_DIR="$SCRIPT_DIR/results"
TIMEOUT_SEC="${BENCH_TIMEOUT:-120}"

if [ ! -x "$BXP_CLI" ]; then
  echo "bxp-cli binary missing — build with: (cd bxp-cli && zig build -Doptimize=ReleaseFast)" >&2
  exit 1
fi

mkdir -p "$RESULTS_DIR" "$WORK"
TS="$(date -u +%Y%m%d-%H%M%S)"
OUT="$RESULTS_DIR/results-$TS.csv"
echo "sweep,n_rows,n_cols,cell_w,expr,trace,wall_s,rss_mb,out_bytes,trace_bytes" > "$OUT"
echo "writing → $OUT"

run_one() {
  local sweep="$1" n="$2" c="$3" w="$4" expr="$5" trace="$6"
  local run_dir="$WORK/$sweep-n${n}-c${c}-w${w}-${expr}-tr${trace}"
  rm -rf "$run_dir"; mkdir -p "$run_dir"

  local gen_args=( --rows "$n" --cols "$c" --cell-width "$w" --out-dir "$run_dir" )
  [ "$expr" = "passthrough" ] && gen_args+=( --passthrough-only )
  python3 "$GEN" "${gen_args[@]}"

  local cli_args=( --config "$run_dir/bxp-cli.json" )
  if [ "$trace" = "on" ]; then
    cli_args+=( --trace )
  else
    cli_args+=( --quiet )
  fi
  local trace_file="$run_dir/trace.ndjson"
  local time_file="$run_dir/time.txt"
  local rc=0

  if [ "$trace" = "on" ]; then
    /usr/bin/time -f '%e %M' -o "$time_file" \
      timeout "$TIMEOUT_SEC" "$BXP_CLI" "${cli_args[@]}" > "$trace_file" 2>/dev/null || rc=$?
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

  local trace_bytes=0
  [ -f "$trace_file" ] && trace_bytes=$(stat -c '%s' "$trace_file")

  if [ "$rc" -eq 124 ]; then
    wall="TIMEOUT"
  elif [ "$rc" -ge 128 ]; then
    wall="KILLED-$rc"
  elif [ "$rc" -ne 0 ]; then
    wall="ERR-$rc"
  fi

  local line="$sweep,$n,$c,$w,$expr,$trace,$wall,$rss_mb,$out_bytes,$trace_bytes"
  echo "$line" | tee -a "$OUT"
}

# --- Matrix (baseline N=100k, C=16, cell_w=20, expr=3expr) ---

# S1: rows sweep, trace off
for n in 5000 25000 100000 500000 2000000; do
  run_one S1 "$n" 16 20 3expr off
done

# S2: rows sweep + trace
for n in 5000 25000 100000 500000; do
  run_one S2 "$n" 16 20 3expr on
done

# S3: cols sweep, trace off
for c in 4 16 64 256 1024; do
  run_one S3 100000 "$c" 20 3expr off
done

# S4: cols sweep + trace
for c in 4 16 64 256; do
  run_one S4 100000 "$c" 20 3expr on
done

# S5: cell-width sweep — N reduced to 25k so cell_w=1000 stays under ~300 MB CSV
for w in 10 100 1000; do
  run_one S5 25000 16 "$w" 3expr off
done

# S6: expr overhead — passthrough vs 3-expr at baseline (off + on)
run_one S6 100000 16 20 passthrough off
run_one S6 100000 16 20 3expr       off
run_one S6 100000 16 20 passthrough on
run_one S6 100000 16 20 3expr       on

echo
echo "Done. Results: $OUT"
