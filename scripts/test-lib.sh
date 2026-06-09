# Shared helpers for test-NN-*.sh phase scripts and the test.sh wrapper.
# Sourced; not executable on its own.

# Sub-second timing via bash 5+ EPOCHREALTIME; fall back to whole seconds.
# EPOCHREALTIME honours the locale's decimal point (e.g. "1.234,56" in cs_CZ),
# which awk would parse as an integer. Normalise comma → period.
if [[ -n "${EPOCHREALTIME-}" ]]; then
    _now() { local v="$EPOCHREALTIME"; printf '%s\n' "${v//,/.}"; }
else
    _now() { date +%s; }
fi

# Set by the wrapper before invoking phases. Unset when a phase runs
# standalone, in which case `summary` is a no-op.
: "${BXP_TEST_T0:=}"

_BXP_LINE_W=60
_BXP_OK_COL=51   # column where the "O" of OK lands

# section "Console"  →  "\nConsole suite ──────────────────────────────"
section() {
    local title="$1"
    local head="$title suite "
    local pad=$(( _BXP_LINE_W - ${#head} ))
    (( pad < 3 )) && pad=3
    echo
    printf '%s' "$head"
    printf '─%.0s' $(seq 1 $pad)
    echo
}

# Two-column label helper: 12-char first column + free-form second.
#   _lab bxp-core 'unit tests'   →  "bxp-core    unit tests"
_lab() { printf '%-12s%s' "$1" "$2"; }

# step "label" cmd args...
# Runs cmd silently, captures stdout+stderr; on success prints
#   "  <label> .... OK   X.Xs"
# On failure replays captured output to stderr and exits with cmd's rc.
step() {
    local label="$1"; shift
    local out
    out=$(mktemp)
    local t0 t1 dur rc=0
    t0=$(_now)
    "$@" >"$out" 2>&1 || rc=$?
    t1=$(_now)
    dur=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')

    local dots_n=$(( _BXP_OK_COL - 5 - ${#label} ))
    (( dots_n < 3 )) && dots_n=3
    local dots
    dots=$(printf '.%.0s' $(seq 1 $dots_n))

    if [[ $rc -eq 0 ]]; then
        # %6s (OK) / %4s (FAIL): right-align the time so its trailing "s"
        # lands on the report's right margin (_BXP_LINE_W), flush with the
        # section rules and the summary's total — "FAIL" is 2 chars wider
        # than "OK", so its number field is 2 narrower to keep the same edge.
        printf '  %s %s OK %6ss\n' "$label" "$dots" "$dur"
        rm -f "$out"
    else
        printf '  %s %s FAIL %4ss\n' "$label" "$dots" "$dur"
        echo
        cat "$out" >&2
        rm -f "$out"
        exit "$rc"
    fi
}

# Wrapper-only: bottom rule + total time. No-op if BXP_TEST_T0 unset.
summary() {
    [[ -z "$BXP_TEST_T0" ]] && return 0
    local t1 total
    t1=$(_now)
    total=$(awk -v a="$BXP_TEST_T0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')
    echo
    printf '─%.0s' $(seq 1 $_BXP_LINE_W)
    echo
    local left='  All passed'
    local right="${total}s"
    local pad=$(( _BXP_LINE_W - ${#left} - ${#right} ))
    (( pad < 1 )) && pad=1
    printf '%s%*s%s\n' "$left" $pad '' "$right"
}
