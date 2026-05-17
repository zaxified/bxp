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
#   BENCH_WORK        work dir for per-run inputs/outputs
#                     (default scripts/bench/work — same FS as repo, not tmpfs)
#   BENCH_TIMEOUT     per-run wall-time cap in seconds (default 120)
#   BENCH_SKIP_BUILD  set to 1 to skip the ReleaseFast rebuild at start
#                     (default off — every run begins with a fresh build to
#                     prevent stale or accidental Debug binaries from
#                     skewing numbers)
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
echo "sweep,n_rows,n_cols,cell_w,expr,trace,wall_s,rss_mb,out_bytes,trace_events,trace_bytes" > "$OUT"
echo "writing → $OUT"

run_one() {
  local sweep="$1" n="$2" c="$3" w="$4" expr="$5" trace="$6"
  local run_dir="$WORK/$sweep-n${n}-c${c}-w${w}-${expr}-tr${trace}"
  # Wipe any stragglers from a previous run by named files only — no `rm -rf`.
  rm -f "$run_dir"/input.in.csv \
        "$run_dir"/bxp-cli.json \
        "$run_dir"/input.out.csv \
        "$run_dir"/time.txt \
        "$run_dir"/trace.stats 2>/dev/null
  mkdir -p "$run_dir"

  local gen_args=( --rows "$n" --cols "$c" --cell-width "$w" --out-dir "$run_dir" )
  [ "$expr" = "passthrough" ] && gen_args+=( --passthrough-only )
  python3 "$GEN" "${gen_args[@]}"

  local cli_args=( --config "$run_dir/bxp-cli.json" )
  if [ "$trace" = "on" ]; then
    cli_args+=( --trace )
  else
    cli_args+=( --quiet )
  fi
  local time_file="$run_dir/time.txt"
  local trace_stats="$run_dir/trace.stats"
  local rc=0

  # Trace output is piped through `wc -lc` so it never touches disk.
  # `wc -lc` writes "<events> <bytes>" to trace_stats — that's all we need.
  # PIPESTATUS preserves bxp-cli's exit code through the pipe.
  if [ "$trace" = "on" ]; then
    /usr/bin/time -f '%e %M' -o "$time_file" \
      timeout "$TIMEOUT_SEC" "$BXP_CLI" "${cli_args[@]}" 2>/dev/null \
      | wc -lc > "$trace_stats"
    rc="${PIPESTATUS[0]}"
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
  echo "$line" | tee -a "$OUT"

  # Drop per-run inputs/outputs immediately so disk stays bounded.
  # Per-filename delete (no `rm -rf`) — safer if $run_dir ever expands wrong.
  rm -f "$run_dir"/input.in.csv \
        "$run_dir"/bxp-cli.json \
        "$run_dir"/input.out.csv \
        "$run_dir"/time.txt \
        "$run_dir"/trace.stats 2>/dev/null
  rmdir "$run_dir" 2>/dev/null
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
