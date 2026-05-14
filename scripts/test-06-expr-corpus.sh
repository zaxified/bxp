#!/usr/bin/env bash
# Expression corpus regression gate.
#
# Walks scripts/test-06-expr-corpus.txt line by line, invokes
# bxp-fmt --expr per case, and asserts:
#   expected=ok  → exit 0
#   expected=err → exit 1 AND stderr JSON .error == reason field
#
# Output mirrors test-lib.sh step() format with an extra "(N/N passed)"
# footer. Exit code = number of failed cases (0 = green).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test-lib.sh"

BXP_FMT="$MONO_ROOT/bxp-fmt/zig-out/bin/bxp-fmt"
CORPUS="$SCRIPT_DIR/test-06-expr-corpus.txt"

if [[ ! -x "$BXP_FMT" ]]; then
    echo "ERROR: bxp-fmt not built. Run: cd bxp-fmt && zig build" >&2
    exit 2
fi
if [[ ! -f "$CORPUS" ]]; then
    echo "ERROR: corpus file not found: $CORPUS" >&2
    exit 2
fi

section "Expression corpus"

passed=0
failed=0
total=0
failures=()

t0=$(_now)

# IFS=$'\t' splits on TABs; trailing IFS=$'\t' means missing 4th column is empty.
while IFS=$'\t' read -r kind expected expr_text reason || [[ -n "${kind:-}" ]]; do
    # Skip blank and comment lines.
    [[ -z "${kind// }" ]] && continue
    [[ "${kind:0:1}" == "#" ]] && continue
    [[ "$kind" != "expr" ]] && continue

    total=$((total + 1))

    out=$("$BXP_FMT" --expr "$expr_text" 2>&1)
    rc=$?

    case "$expected" in
    ok)
        if [[ $rc -eq 0 ]]; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
            failures+=("ok-expected: '$expr_text' → exit=$rc out=$out")
        fi
        ;;
    err)
        if [[ $rc -ne 1 ]]; then
            failed=$((failed + 1))
            failures+=("err-expected: '$expr_text' → exit=$rc (want 1) out=$out")
        elif [[ -n "${reason:-}" ]]; then
            actual_err=$(printf '%s' "$out" | python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d.get("error", ""))
except Exception:
    pass' 2>/dev/null)
            if [[ "$actual_err" == "$reason" ]]; then
                passed=$((passed + 1))
            else
                failed=$((failed + 1))
                failures+=("err-mismatch: '$expr_text' → .error='$actual_err' want '$reason'")
            fi
        else
            passed=$((passed + 1))
        fi
        ;;
    *)
        failed=$((failed + 1))
        failures+=("bad-kind: '$expected' for '$expr_text' (expected ok|err)")
        ;;
    esac
done < "$CORPUS"

t1=$(_now)
dur=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')

# step()-style line + (N/N passed) footer.
label="corpus"
dots_n=$(( 51 - 5 - ${#label} ))
(( dots_n < 3 )) && dots_n=3
dots=$(printf '.%.0s' $(seq 1 $dots_n))

if (( failed == 0 )); then
    printf '  %s %s OK %5ss   (%d/%d passed)\n' "$label" "$dots" "$dur" "$passed" "$total"
    exit 0
fi

printf '  %s %s FAIL %3ss  (%d/%d passed)\n' "$label" "$dots" "$dur" "$passed" "$total"
echo
echo "  Failures:"
for f in "${failures[@]}"; do
    echo "    - $f"
done
echo
exit "$failed"
