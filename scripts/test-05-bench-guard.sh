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
#      catches any regression back to O(N) buffering. Asserted for both the
#      CSV pipeline and (v0.4.0 streaming .xlsx ingest) a synthetic .xlsx
#      worksheet — the .xlsx point checks the RSS ceiling only, since flat RSS
#      is the whole point of the streaming rewrite.
#
#   2. Scaling ratio — wall(large N) / wall(small N) must stay near the row
#      ratio (linear). A super-linear blow-up (e.g. an accidental O(n^2) path)
#      pushes this far past the row ratio. The RATIO is machine-independent
#      even though the absolute seconds are not, so this gate does not flake.
#
# Build mode: ReleaseSafe — the single mode the whole `scripts/test.sh` suite
# uses, so the perf guard recycles the bxp-cli binary the Console phase already
# built (same package + cache → a no-op rebuild here, just the measured runs).
# This gate checks an RSS ceiling + a scaling RATIO (not absolute wall), so it
# does not need the fastest binary; ReleaseSafe is plenty. (The shipped archive
# is ReleaseSmall, built only by release-01; the guard measures the test-mode
# binary, which catches the same O(N)/O(n^2) regressions.)
#
# Env overrides:
#   GUARD_SMALL_ROWS   small-N row count   (default 25000)
#   GUARD_LARGE_ROWS   large-N row count   (default 250000)
#   GUARD_XLSX_ROWS    .xlsx worksheet row count (default 500000) — sized so an
#                      O(N)-buffering regression would blow the RSS ceiling
#   GUARD_RSS_MB       RSS ceiling in MB   (default 64)
#   GUARD_RATIO_SLACK  allowed multiple of the row ratio before failing
#                      (default 4 — row ratio 10x tolerates up to 40x;
#                       a quadratic path would be ~100x and trip it)
#   GUARD_SKIP_BUILD   set to 1 to reuse an existing guard binary
#
# Usage (from any directory):
#   bash scripts/test-05-bench-guard.sh   — this phase alone
#   bash scripts/test.sh                  — wrapper runs every phase

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test-lib.sh"

GEN="$SCRIPT_DIR/bench/gen.py"
XLSX_GEN="$SCRIPT_DIR/bench/gen-xlsx.py"
XLSX_CFG="$SCRIPT_DIR/bench/xlsx-bench.json"
XLSX_FANOUT_CFG="$SCRIPT_DIR/bench/xlsx-fanout-bench.json"
WORK="$SCRIPT_DIR/bench/work/guard"
# Recycle the shared bxp-cli build: same package zig-out + cache as the Console
# phase (test-01), both ReleaseSafe, so the build below is a cache hit when the
# suite ran first — no second compilation, just the measured runs. The whole
# suite is one mode, so there's no Debug binary here to thrash.
BXP="$MONO_ROOT/bxp-cli/zig-out/bin/bxp-cli"

SMALL_ROWS="${GUARD_SMALL_ROWS:-25000}"
LARGE_ROWS="${GUARD_LARGE_ROWS:-250000}"
XLSX_ROWS="${GUARD_XLSX_ROWS:-500000}"
FANOUT_SHEETS=8  # fixed: xlsx-fanout-bench.json declares 8 templates (DATA1..DATA8)
FANOUT_ROWS="${GUARD_FANOUT_ROWS:-300000}"
WIDE_COLS="${GUARD_WIDE_COLS:-900}"
WIDE_ROWS="${GUARD_WIDE_ROWS:-20000}"
RSS_MB="${GUARD_RSS_MB:-64}"
RATIO_SLACK="${GUARD_RATIO_SLACK:-4}"
COLS=16
CELL_W=20

section "Bench guard"

_fail() {
    status_line "$1" FAIL "$2"
    echo
    shift 2
    for line in "$@"; do echo "    - $line"; done
    echo
    exit 1
}

# Graceful skip: the phase can't run on this host (the synthetic-input
# generator needs python3), but that's not a regression. Emit a SKIP line
# and exit 0 so the test.sh wrapper (set -e) keeps the suite green. Wall +
# peak RSS are measured by bxp-cli itself (BXP_METRICS), so the guard runs
# on every platform that has python3 — Linux, macOS, and Windows alike.
_skip() {
    local label="$1" reason="$2"
    status_line "$label" SKIP
    echo "    - $reason"
    exit 0
}

t0=$(_now)

if [[ ! -f "$GEN" ]]; then
    _fail "guard" 0 "generator missing: $GEN"
fi
if [[ ! -f "$XLSX_GEN" || ! -f "$XLSX_CFG" ]]; then
    _fail "guard" 0 "xlsx generator/config missing: $XLSX_GEN / $XLSX_CFG"
fi
# Wall + peak RSS come from bxp-cli's own BXP_METRICS line (no GNU
# /usr/bin/time, which is absent on Windows and BSD-incompatible on macOS;
# and the stdout time summary is suppressed under the --quiet we run with).
# The only external dependency left is python3 for the synthetic-input
# generator; skip gracefully where it is absent.
if ! command -v python3 >/dev/null 2>&1; then
    _skip "guard" "python3 not available on this host — generator (bench/gen.py) needs it"
fi

# --- 1. Build ReleaseSafe into the shared bxp-cli zig-out --------------------
# Same package + mode as the Console phase, so this is a cache hit when the
# suite ran first (no second compile). GUARD_SKIP_BUILD=1 reuses it outright.
built=0
mkdir -p "$WORK"
if [[ "${GUARD_SKIP_BUILD:-0}" != "1" || ! -x "$BXP" ]]; then
    if ! ( cd "$MONO_ROOT/bxp-cli" && zig build -Doptimize=ReleaseSafe -Dcpu=baseline ) 2>"$WORK/build.log"; then
        _fail "guard" 0 "ReleaseSafe build failed (see $WORK/build.log)"
    fi
    built=1
fi
t_build=$(_now)
build_dur=$(awk -v a="$t0" -v b="$t_build" 'BEGIN{printf "%.1f", b-a}')
if [[ ! -x "$BXP" ]]; then
    _fail "guard" 0 "guard binary missing after build: $BXP"
fi

# Optimized-build sanity: a ReleaseSafe bxp-cli is ~6 MB. A fat debug-info
# build (20+ MB) would signal an unoptimized binary that invalidates the
# scaling check. `wc -c` is portable (GNU `stat -c` / BSD `stat -f` differ
# across Linux/macOS).
bin_bytes=$(wc -c < "$BXP" | tr -d '[:space:]')
if (( bin_bytes > 10485760 )); then
    bin_mb=$(awk -v b="$bin_bytes" 'BEGIN{printf "%.1f", b/1048576}')
    _fail "guard" 0 "guard binary too large (${bin_mb} MB > 10 MB) — not optimized?"
fi

# Run one (rows) → echoes "wall_s rss_kb" or aborts the phase on a bad exit.
# bxp-cli self-reports wall + peak RSS on stderr when BXP_METRICS is set, so
# no external timer is needed (works identically on Linux/macOS/Windows).
_run_point() {
    local rows="$1"
    local dir="$WORK/n${rows}"
    mkdir -p "$dir"
    # Regenerate only if the input is absent — gen.py is deterministic.
    if [[ ! -f "$dir/input.in.csv" || ! -f "$dir/bxp-cli.json" ]]; then
        python3 "$GEN" --rows "$rows" --cols "$COLS" --cell-width "$CELL_W" \
            --out-dir "$dir" >/dev/null 2>&1 || return 1
    fi
    # Capture stderr (the metrics line); discard stdout. --quiet keeps stderr
    # to just the `bxp-metrics wall_ms=<N> peak_rss_kb=<N>` line.
    local metrics
    metrics=$(BXP_METRICS=1 "$BXP" --config "$dir/bxp-cli.json" --quiet 2>&1 >/dev/null) || return 1
    local wall_ms rss_kb
    wall_ms=$(printf '%s\n' "$metrics" | sed -n 's/.*wall_ms=\([0-9][0-9]*\).*/\1/p')
    rss_kb=$(printf '%s\n' "$metrics" | sed -n 's/.*peak_rss_kb=\([0-9][0-9]*\).*/\1/p')
    [[ -n "$wall_ms" && -n "$rss_kb" ]] || return 1
    awk -v ms="$wall_ms" -v r="$rss_kb" 'BEGIN{printf "%.2f %s", ms/1000, r}'
}

# Like _run_point but for the streaming .xlsx path: generate a synthetic
# single-sheet workbook (worksheet stream sized by rows; small fixed vocab so
# the sharedStrings table stays negligible), then convert it through the xlsx
# pre-pass. Echoes "wall_s rss_kb". gen-xlsx.py uses only the Python stdlib
# (zipfile/struct/datetime), so the existing python3 gate already covers it.
_run_xlsx_point() {
    local rows="$1"
    local dir="$WORK/xlsx-n${rows}"
    mkdir -p "$dir"
    # Regenerate only if the workbook is absent — gen-xlsx.py is deterministic.
    if [[ ! -f "$dir/bench.xlsx" ]]; then
        python3 "$XLSX_GEN" "$dir/bench.xlsx" --rows "$rows" --vocab 5000 \
            --symbols 200 --tmp "$dir/parts" >/dev/null 2>&1 || return 1
    fi
    cp "$XLSX_CFG" "$dir/bxp-cli.json"
    # Drop any prior intermediate/output so a stale skip doesn't mask the run.
    rm -f "$dir"/*_data.csv "$dir"/*_data.csvx 2>/dev/null
    # Config uses data_dir "." — run from the workbook's directory.
    local metrics
    metrics=$( cd "$dir" && BXP_METRICS=1 "$BXP" --config bxp-cli.json --quiet 2>&1 >/dev/null ) || return 1
    local wall_ms rss_kb
    wall_ms=$(printf '%s\n' "$metrics" | sed -n 's/.*wall_ms=\([0-9][0-9]*\).*/\1/p')
    rss_kb=$(printf '%s\n' "$metrics" | sed -n 's/.*peak_rss_kb=\([0-9][0-9]*\).*/\1/p')
    [[ -n "$wall_ms" && -n "$rss_kb" ]] || return 1
    awk -v ms="$wall_ms" -v r="$rss_kb" 'BEGIN{printf "%.2f %s", ms/1000, r}'
}

# Like _run_point but wide: many columns, modest rows, full passthrough (every
# source column routed to output via --passthrough-only) so the wide-column
# field/output path is actually exercised. This guard's other points fix
# COLS=16 and vary rows; this one fixes rows and widens to guard the per-row buffer +
# output streaming against a return to O(cols)-buffered RSS. Echoes
# "wall_s rss_kb". (The DEV PlutoGrid fixture was GUI-render stress — not
# headless-runnable; this is the CLI-side wide-column guard.)
_run_wide_point() {
    local rows="$1" cols="$2"
    local dir="$WORK/wide-c${cols}-n${rows}"
    mkdir -p "$dir"
    if [[ ! -f "$dir/input.in.csv" || ! -f "$dir/bxp-cli.json" ]]; then
        python3 "$GEN" --rows "$rows" --cols "$cols" --cell-width "$CELL_W" \
            --passthrough-only --out-dir "$dir" >/dev/null 2>&1 || return 1
    fi
    local metrics
    metrics=$(BXP_METRICS=1 "$BXP" --config "$dir/bxp-cli.json" --quiet 2>&1 >/dev/null) || return 1
    local wall_ms rss_kb
    wall_ms=$(printf '%s\n' "$metrics" | sed -n 's/.*wall_ms=\([0-9][0-9]*\).*/\1/p')
    rss_kb=$(printf '%s\n' "$metrics" | sed -n 's/.*peak_rss_kb=\([0-9][0-9]*\).*/\1/p')
    [[ -n "$wall_ms" && -n "$rss_kb" ]] || return 1
    awk -v ms="$wall_ms" -v r="$rss_kb" 'BEGIN{printf "%.2f %s", ms/1000, r}'
}

# Like _run_xlsx_point but multi-sheet: an 8-sheet workbook converted with the
# fan-out config (one template per sheet). The xlsx pre-pass extracts the sheets
# in parallel; this guards that the fan-out holds RSS flat in its width. A
# regression that hands the worker a non-reclaiming arena re-accumulates a whole
# sheet's cells per worker and trips the ceiling on a multi-core host. Echoes
# "wall_s rss_kb".
_run_fanout_point() {
    local rows="$1" sheets="$2"
    local dir="$WORK/xlsx-fanout-s${sheets}-n${rows}"
    mkdir -p "$dir"
    if [[ ! -f "$dir/bench.xlsx" ]]; then
        python3 "$XLSX_GEN" "$dir/bench.xlsx" --rows "$rows" --sheets "$sheets" \
            --vocab 5000 --symbols 200 --tmp "$dir/parts" >/dev/null 2>&1 || return 1
    fi
    cp "$XLSX_FANOUT_CFG" "$dir/bxp-cli.json"
    rm -f "$dir"/*_data*.csv "$dir"/*_data*.csvx 2>/dev/null
    local metrics
    metrics=$( cd "$dir" && BXP_METRICS=1 "$BXP" --config bxp-cli.json --quiet 2>&1 >/dev/null ) || return 1
    local wall_ms rss_kb
    wall_ms=$(printf '%s\n' "$metrics" | sed -n 's/.*wall_ms=\([0-9][0-9]*\).*/\1/p')
    rss_kb=$(printf '%s\n' "$metrics" | sed -n 's/.*peak_rss_kb=\([0-9][0-9]*\).*/\1/p')
    [[ -n "$wall_ms" && -n "$rss_kb" ]] || return 1
    awk -v ms="$wall_ms" -v r="$rss_kb" 'BEGIN{printf "%.2f %s", ms/1000, r}'
}

small_out=$(_run_point "$SMALL_ROWS") || _fail "guard" 0 "small-N run failed (N=$SMALL_ROWS)"
large_out=$(_run_point "$LARGE_ROWS") || _fail "guard" 0 "large-N run failed (N=$LARGE_ROWS)"

read -r small_wall small_rss <<<"$small_out"
read -r large_wall large_rss <<<"$large_out"

# --- 2. Assert RSS ceiling ---------------------------------------------------
rss_ceil_kb=$(( RSS_MB * 1024 ))
small_rss_mb=$(awk -v k="$small_rss" 'BEGIN{printf "%.1f", k/1024}')
large_rss_mb=$(awk -v k="$large_rss" 'BEGIN{printf "%.1f", k/1024}')
if (( small_rss > rss_ceil_kb || large_rss > rss_ceil_kb )); then
    _fail "guard rss" "$large_wall" \
        "RSS ceiling ${RSS_MB} MB exceeded — possible return to O(N) buffering" \
        "N=${SMALL_ROWS}: ${small_rss_mb} MB" \
        "N=${LARGE_ROWS}: ${large_rss_mb} MB"
fi

# --- 3. Assert scaling ratio -------------------------------------------------
# wall ratio should track the row ratio (linear). Fail if it exceeds
# row_ratio * RATIO_SLACK. Guard against a ~0 small_wall (timing noise on a
# fast machine) by flooring it before the division.
t_chk0=$(_now)
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
t_chk1=$(_now)
chk_dur=$(awk -v a="$t_chk0" -v b="$t_chk1" 'BEGIN{printf "%.1f", b-a}')
if (( ratio_rc != 0 )); then
    _fail "guard scaling" "$chk_dur" \
        "wall scaling ${wall_ratio}x for a ${row_ratio}x row increase (limit ${ratio_limit}x)" \
        "super-linear — suspect an O(n^2) regression in the row pipeline" \
        "N=${SMALL_ROWS}: ${small_wall}s   N=${LARGE_ROWS}: ${large_wall}s"
fi

# --- 4. Assert .xlsx streaming RSS ceiling -----------------------------------
# The v0.4.0 streaming .xlsx ingest holds RSS flat regardless of worksheet
# size. XLSX_ROWS is sized so the uncompressed worksheet comfortably exceeds
# the ceiling, so a regression to O(N) buffering trips it. Only the RSS ceiling
# is checked (not the scaling ratio) — flat RSS is the invariant the streaming
# rewrite delivers; the wall is reported for context only.
xlsx_out=$(_run_xlsx_point "$XLSX_ROWS") || _fail "guard xlsx" 0 "xlsx-N run failed (N=$XLSX_ROWS)"
read -r xlsx_wall xlsx_rss <<<"$xlsx_out"
xlsx_rss_mb=$(awk -v k="$xlsx_rss" 'BEGIN{printf "%.1f", k/1024}')
if (( xlsx_rss > rss_ceil_kb )); then
    _fail "guard xlsx rss" "$xlsx_wall" \
        "RSS ceiling ${RSS_MB} MB exceeded on .xlsx ingest — possible return to O(N) buffering" \
        "N=${XLSX_ROWS}: ${xlsx_rss_mb} MB"
fi

# --- 5. Assert wide-column RSS ceiling ---------------------------------------
# Wide passthrough (well below the MAX_COLUMNS=16384 ceiling). RSS must stay
# bounded: the streaming pipeline processes row-by-row, so column count widens the
# per-row buffer but not the resident set. A regression that buffers the whole
# wide output would blow the ceiling. RSS-only (no scaling ratio — this point
# fixes rows and varies width, not rows).
wide_out=$(_run_wide_point "$WIDE_ROWS" "$WIDE_COLS") || _fail "guard wide" 0 "wide run failed (cols=$WIDE_COLS rows=$WIDE_ROWS)"
read -r wide_wall wide_rss <<<"$wide_out"
wide_rss_mb=$(awk -v k="$wide_rss" 'BEGIN{printf "%.1f", k/1024}')
if (( wide_rss > rss_ceil_kb )); then
    _fail "guard wide rss" "$wide_wall" \
        "RSS ceiling ${RSS_MB} MB exceeded on ${WIDE_COLS}-column ingest — possible O(cols) buffering" \
        "cols=${WIDE_COLS} rows=${WIDE_ROWS}: ${wide_rss_mb} MB"
fi

# --- 6. Assert multi-sheet xlsx fan-out RSS ceiling --------------------------
# The xlsx pre-pass extracts a workbook's sheets in parallel (fan-out across the
# worker pool). RSS must stay flat in the fan-out width: the worker uses the
# pipeline's reclaiming allocator, so `parseSheet` frees each row's cells as the
# sheet streams. A regression to a non-reclaiming arena would accumulate a whole
# sheet's cells per worker and, on a multi-core host, blow the ceiling. RSS-only
# (flat-RSS invariant; most sensitive on 6+ core hosts where the fan-out is
# widest — on a 2-core runner only two sheets extract at once).
fanout_out=$(_run_fanout_point "$FANOUT_ROWS" "$FANOUT_SHEETS") || _fail "guard xlsx fan-out" 0 "fan-out run failed (sheets=$FANOUT_SHEETS rows=$FANOUT_ROWS)"
read -r fanout_wall fanout_rss <<<"$fanout_out"
fanout_rss_mb=$(awk -v k="$fanout_rss" 'BEGIN{printf "%.1f", k/1024}')
if (( fanout_rss > rss_ceil_kb )); then
    _fail "guard xlsx fan-out rss" "$fanout_wall" \
        "RSS ceiling ${RSS_MB} MB exceeded on ${FANOUT_SHEETS}-sheet fan-out — worker may be accumulating cells (non-reclaiming allocator)" \
        "sheets=${FANOUT_SHEETS} rows=${FANOUT_ROWS}: ${fanout_rss_mb} MB"
fi

# One column-aligned OK line per check, each with its own real time — the
# build (when it ran), each measured run (bxp-cli's self-reported wall, with
# that point's peak RSS + the ceiling), and the scaling verdict. Cramming all
# the numbers into a single label overflowed _BXP_OK_COL and pushed "OK" out
# of line with every other suite; splitting keeps each line aligned.
# Display the wall on 1 decimal to match every other suite's `step` output
# (the raw %.2f walls stay above for the ratio math, which wants the precision).
small_wall_1=$(awk -v w="$small_wall" 'BEGIN{printf "%.1f", w}')
large_wall_1=$(awk -v w="$large_wall" 'BEGIN{printf "%.1f", w}')
xlsx_wall_1=$(awk -v w="$xlsx_wall" 'BEGIN{printf "%.1f", w}')
wide_wall_1=$(awk -v w="$wide_wall" 'BEGIN{printf "%.1f", w}')
fanout_wall_1=$(awk -v w="$fanout_wall" 'BEGIN{printf "%.1f", w}')
(( built )) && status_line "guard build (ReleaseSafe)" OK "$build_dur"
status_line "guard run N=${SMALL_ROWS} rss=${small_rss_mb}MB (<=${RSS_MB})" OK "$small_wall_1"
status_line "guard run N=${LARGE_ROWS} rss=${large_rss_mb}MB (<=${RSS_MB})" OK "$large_wall_1"
status_line "guard scaling ${wall_ratio}x (<=${ratio_limit}x, ${row_ratio}x rows)" OK "$chk_dur"
status_line "guard xlsx N=${XLSX_ROWS} rss=${xlsx_rss_mb}MB (<=${RSS_MB})" OK "$xlsx_wall_1"
status_line "guard wide cols=${WIDE_COLS} rss=${wide_rss_mb}MB (<=${RSS_MB})" OK "$wide_wall_1"
status_line "guard xlsx fan-out ${FANOUT_SHEETS}sh rss=${fanout_rss_mb}MB (<=${RSS_MB})" OK "$fanout_wall_1"
exit 0
