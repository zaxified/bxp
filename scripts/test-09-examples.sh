#!/usr/bin/env bash
# Example regression: run bxp-cli against every docs/examples/<tier>/<name>/
# sample.json and diff each produced output against its committed *.expected
# golden.
#
# Sibling of test-07-datasets.sh (which gates datasets/) and complementary to
# test-08-docs-examples.sh (which evaluates the *expressions* embedded in the
# example pages, not the runs). Until this phase existed the 32 goldens under
# docs/examples/ were gated by nothing, even though they carry cases the
# datasets do not: JSON-emitting templates, multi-hop pre_pass chains,
# self-joins, wide-to-long unpivots, sexagesimal coordinates, HL7 segments.
#
# Examples are user-facing demonstration material — same contract as datasets:
# they must run clean (exit 0, no warnings). A new warning firing on an example
# is an example-quality bug, not a tolerable corner case; fix the example, do
# not loosen the test.
#
# Two things this needs that test-07 does not:
#
#   1. A scratch work dir instead of running in place. An example dir holds its
#      goldens and committed engine output next to its inputs, and templates use
#      `data_dir: "."` — so an in-place run both re-reads committed artifacts and
#      leaves untracked intermediates behind in docs/examples/. Only the inputs
#      are copied out; the run happens in the copy.
#   2. Output discovery by before/after listing. An `X.expected` golden matches
#      `X.csvx` for CSV templates but `X.json` for `file_type_out: json`
#      (advanced/multi-stage-etl), so the counterpart cannot be named by
#      extension. Whatever the run newly created is the output.
#
# Usage (from any directory):
#   bash scripts/test-09-examples.sh   — this phase alone
#   bash scripts/test.sh               — wrapper runs every phase

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test-lib.sh"

BXP="$MONO_ROOT/bxp-cli/zig-out/bin/bxp-cli"
EXAMPLES="$MONO_ROOT/docs/examples"

_run_example() {
    local dir="$1"
    local work rc=0
    work="$(mktemp -d)"

    # Seed inputs only.
    #
    # The rule that does the real work: **a file whose content equals one of
    # this example's goldens is an output, never an input.** A multi-pass
    # example commits the result of each stage (see docs/examples/CLAUDE.md),
    # and those intermediates carry ordinary input-looking names —
    # `legacy.unified.csv` feeds a later pass but is written by an earlier one,
    # and `1-enriched.in.json` matches the very `file_pattern_in` its consumer
    # scans for. Seeding either would let a stale committed copy stand in for
    # what the run is supposed to produce.
    #
    # Matching on content rather than on the name is not fussiness: the golden
    # naming is genuinely ambiguous. `sample.expected` pins `sample.csvx` in a
    # single-input example, but stripping the extension to pair it by stem would
    # equally claim `sample.csv` — the input. Content cannot be misread, and
    # `test-09` already requires each committed output to equal its golden.
    #
    # The rest are not inputs for duller reasons: goldens themselves, engine
    # output nobody pinned, the docs page, the fetch/generate scripts, and the
    # on-demand full-scale pull plus its config.
    local f b g
    for f in "$dir"/*; do
        [[ -f "$f" ]] || continue
        b="$(basename "$f")"
        case "$b" in
            *.expected|*.csvx|index.md|*.sh|full|full.*) continue ;;
        esac
        local is_output=0
        for g in "$dir"/*.expected; do
            [[ -f "$g" ]] || continue
            if cmp -s "$f" "$g"; then is_output=1; break; fi
        done
        [[ "$is_output" -eq 1 ]] && continue
        cp "$f" "$work/"
    done

    local before after new
    before="$(cd "$work" && ls -1)"

    # Same two-sided contract as test-07: exit code AND empty stderr. `step`
    # wraps this with `|| rc=$?`, which disables `set -e` for the whole body,
    # so a warning-but-identical-output example would otherwise pass green.
    local stderr_file
    stderr_file="$work/.stderr"
    ( cd "$work" && "$BXP" --config ./sample.json ) > /dev/null 2> "$stderr_file" || {
        rc=$?
        echo "exit $rc (warnings/error)"
        cat "$stderr_file"
        rm -rf "$work"
        return 1
    }
    if [[ -s "$stderr_file" ]]; then
        echo "non-empty stderr (warnings):"
        cat "$stderr_file"
        rm -rf "$work"
        return 1
    fi
    rm -f "$stderr_file"

    after="$(cd "$work" && ls -1)"
    new="$(comm -13 <(echo "$before") <(echo "$after"))"

    # An example with no golden is an example nothing gates — the exact hole
    # this phase closes. Fail rather than count it as a silent pass.
    local goldens=0
    for expected in "$dir"/*.expected; do
        [[ -f "$expected" ]] || continue
        goldens=$((goldens + 1))
        local base hit n
        base="$(basename "${expected%.expected}")"
        hit=""
        while read -r n; do
            [[ -z "$n" ]] && continue
            [[ "${n%.*}" == "$base" ]] && hit="$n"
        done <<< "$new"
        if [[ -z "$hit" ]]; then
            echo "no output produced for golden $base.expected"
            echo "run created: $(echo $new)"
            rm -rf "$work"
            return 1
        fi
        if ! diff -q "$work/$hit" "$expected" > /dev/null 2>&1; then
            echo "diff: $hit"
            diff "$work/$hit" "$expected" | head -20
            rm -rf "$work"
            return 1
        fi
        # The committed copy of the output is not just a convenience for people
        # browsing GitHub — the example page embeds it as its "result" tab. A
        # stale one would publish a wrong answer, so hold it to the golden too.
        if [[ -f "$dir/$hit" ]] && ! diff -q "$dir/$hit" "$expected" > /dev/null 2>&1; then
            echo "committed $hit is stale (differs from $base.expected)"
            diff "$dir/$hit" "$expected" | head -20
            rm -rf "$work"
            return 1
        fi
    done
    rm -rf "$work"

    if [[ "$goldens" -eq 0 ]]; then
        echo "no *.expected golden in $dir — example is ungated"
        return 1
    fi
}

section "Examples"
count=0
shopt -s nullglob
for sample_json in "$EXAMPLES"/*/*/sample.json; do
    dir="$(dirname "$sample_json")"
    step "${dir#$EXAMPLES/}" _run_example "$dir"
    count=$((count + 1))
done

# Guard against a silent no-op: a moved/renamed examples tree must fail loudly
# rather than report a vacuous pass (the class of false green test.sh itself
# guards against for phases).
if [[ "$count" -eq 0 ]]; then
    echo "test-09-examples.sh: no examples matched under $EXAMPLES — refusing to pass" >&2
    exit 1
fi
printf '  %d/%d passed\n' "$count" "$count"
