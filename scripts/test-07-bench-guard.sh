#!/usr/bin/env bash
# Performance regression guard.
#
# A *coarse* perf gate meant to catch order-of-magnitude regressions before a
# push — NOT a benchmark. The full benchmark lives in scripts/bench/bench.sh
# and records absolute numbers; this phase asserts only two machine-independent
# invariants that have historically broken (and that absolute wall-time
# thresholds would flake on across machines/CI):
#
#   1. RSS ceiling — peak resident memory must stay bounded regardless of row
#      count. The pre-2026-05-17 pipeline grew RSS O(N) (10 GB on 2M rows);
#      the streaming rewrite holds it to a small constant. A hard ceiling
#      catches any regression back to O(N) buffering.
#
#   2. Scaling ratio — wall(large N) / wall(small N) must stay near the row
#      ratio (linear). A super-linear blow-up (e.g. an accidental O(n^2) path)
#      pushes this far past the row ratio. The RATIO is machine-independent
#      even though the absolute seconds are not, so this gate does not flake.
#
# Build mode: test.sh's other phases build Debug (`zig build`, default
# optimize). A Debug binary is 10-50x slower and its RSS profile differs, so
# this phase builds its OWN ReleaseFast binary into a gitignored work prefix
# and measures that — never the Debug artifact from test-01.
#
# Env overrides:
#   GUARD_SMALL_ROWS   small-N row count   (default 25000)
#   GUARD_LARGE_ROWS   large-N row count   (default 250000)
#   GUARD_RSS_MB       RSS ceiling in MB   (default 64)
#   GUARD_RATIO_SLACK  allowed multiple of the row ratio before failing
#                      (default 4 — row ratio 10x tolerates up to 40x;
#                       a quadratic path would be ~100x and trip it)
#   GUARD_SKIP_BUILD   set to 1 to reuse an existing guard binary
#
# Usage (from any directory):
#   bash scripts/test-07-bench-guard.sh   — this phase alone
#   bash scripts/test.sh                  — wrapper runs every phase

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test-lib.sh"

GEN="$SCRIPT_DIR/bench/gen.py"
WORK="$SCRIPT_DIR/bench/work/guard"
BUILD_PREFIX="$WORK/build"
BXP="$BUILD_PREFIX/bin/bxp-cli"

SMALL_ROWS="${GUARD_SMALL_ROWS:-25000}"
LARGE_ROWS="${GUARD_LARGE_ROWS:-250000}"
RSS_MB="${GUARD_RSS_MB:-64}"
RATIO_SLACK="${GUARD_RATIO_SLACK:-4}"
COLS=16
CELL_W=20

section "Bench guard"

# step()-style single line: label, dots to the OK column, then OK/FAIL + time.
_emit() {
    local label="$1" status="$2" dur="$3"
    local dots_n=$(( _BXP_OK_COL - 5 - ${#label} ))
    (( dots_n < 3 )) && dots_n=3
    local dots
    dots=$(printf '.%.0s' $(seq 1 "$dots_n"))
    if [[ "$status" == OK ]]; then
        printf '  %s %s OK %5ss\n' "$label" "$dots" "$dur"
    else
        printf '  %s %s FAIL %3ss\n' "$label" "$dots" "$dur"
    fi
}

_fail() {
    _emit "$1" FAIL "$2"
    echo
    shift 2
    for line in "$@"; do echo "    - $line"; done
    echo
    exit 1
}

t0=$(_now)

if [[ ! -f "$GEN" ]]; then
    _fail "guard" 0 "generator missing: $GEN"
fi
if ! command -v /usr/bin/time >/dev/null 2>&1; then
    _fail "guard" 0 "/usr/bin/time not found (GNU time required for %e/%M)"
fi

# --- 1. Build ReleaseFast into the gitignored guard prefix -------------------
if [[ "${GUARD_SKIP_BUILD:-0}" != "1" || ! -x "$BXP" ]]; then
    mkdir -p "$BUILD_PREFIX"
    if ! ( cd "$MONO_ROOT/bxp-cli" && zig build -Doptimize=ReleaseFast -p "$BUILD_PREFIX" ) 2>"$WORK/build.log"; then
        _fail "guard" 0 "ReleaseFast build failed (see $WORK/build.log)"
    fi
fi
if [[ ! -x "$BXP" ]]; then
    _fail "guard" 0 "guard binary missing after build: $BXP"
fi

# Debug-build sanity: a ReleaseFast bxp-cli is ~5 MB; Debug is 20+ MB. A Debug
# binary here would silently invalidate the scaling check.
bin_bytes=$(stat -c '%s' "$BXP")
if (( bin_bytes > 10485760 )); then
    bin_mb=$(awk -v b="$bin_bytes" 'BEGIN{printf "%.1f", b/1048576}')
    _fail "guard" 0 "guard binary too large (${bin_mb} MB > 10 MB) — not ReleaseFast?"
fi

# Run one (rows) → echoes "wall rss_kb" or aborts the phase on a bad exit.
_run_point() {
    local rows="$1"
    local dir="$WORK/n${rows}"
    mkdir -p "$dir"
    # Regenerate only if the input is absent — gen.py is deterministic.
    if [[ ! -f "$dir/input.in.csv" || ! -f "$dir/bxp-cli.json" ]]; then
        python3 "$GEN" --rows "$rows" --cols "$COLS" --cell-width "$CELL_W" \
            --out-dir "$dir" >/dev/null 2>&1 || return 1
    fi
    local tf="$dir/time.txt"
    /usr/bin/time -f '%e %M' -o "$tf" \
        "$BXP" --config "$dir/bxp-cli.json" --quiet >/dev/null 2>/dev/null || return 1
    [[ -s "$tf" ]] || return 1
    cat "$tf"
}

small_out=$(_run_point "$SMALL_ROWS") || _fail "guard" 0 "small-N run failed (N=$SMALL_ROWS)"
large_out=$(_run_point "$LARGE_ROWS") || _fail "guard" 0 "large-N run failed (N=$LARGE_ROWS)"

read -r small_wall small_rss <<<"$small_out"
read -r large_wall large_rss <<<"$large_out"

t1=$(_now)
dur=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')

# --- 2. Assert RSS ceiling ---------------------------------------------------
rss_ceil_kb=$(( RSS_MB * 1024 ))
small_rss_mb=$(awk -v k="$small_rss" 'BEGIN{printf "%.1f", k/1024}')
large_rss_mb=$(awk -v k="$large_rss" 'BEGIN{printf "%.1f", k/1024}')
if (( small_rss > rss_ceil_kb || large_rss > rss_ceil_kb )); then
    _fail "guard (rss)" "$dur" \
        "RSS ceiling ${RSS_MB} MB exceeded — possible return to O(N) buffering" \
        "N=${SMALL_ROWS}: ${small_rss_mb} MB" \
        "N=${LARGE_ROWS}: ${large_rss_mb} MB"
fi

# --- 3. Assert scaling ratio -------------------------------------------------
# wall ratio should track the row ratio (linear). Fail if it exceeds
# row_ratio * RATIO_SLACK. Guard against a ~0 small_wall (timing noise on a
# fast machine) by flooring it before the division.
verdict=$(awk \
    -v sw="$small_wall" -v lw="$large_wall" \
    -v sr="$SMALL_ROWS" -v lr="$LARGE_ROWS" -v slack="$RATIO_SLACK" '
BEGIN {
    floor = 0.01;
    if (sw < floor) sw = floor;
    row_ratio  = lr / sr;
    wall_ratio = lw / sw;
    limit = row_ratio * slack;
    printf "%.1f %.1f %.1f", wall_ratio, row_ratio, limit;
    if (wall_ratio > limit) exit 1;
    exit 0;
}')
ratio_rc=$?
read -r wall_ratio row_ratio ratio_limit <<<"$verdict"
if (( ratio_rc != 0 )); then
    _fail "guard (scaling)" "$dur" \
        "wall scaling ${wall_ratio}x for a ${row_ratio}x row increase (limit ${ratio_limit}x)" \
        "super-linear — suspect an O(n^2) regression in the row pipeline" \
        "N=${SMALL_ROWS}: ${small_wall}s   N=${LARGE_ROWS}: ${large_wall}s"
fi

_emit "guard (rss<=${RSS_MB}MB, scale ${wall_ratio}x/${row_ratio}x)" OK "$dur"
exit 0
