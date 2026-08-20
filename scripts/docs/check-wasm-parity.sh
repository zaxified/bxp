#!/usr/bin/env bash
# wasm/native parity gate for the docs expression scratchpad.
#
# The scratchpad's entire promise is that the browser runs THE SAME evaluator as
# bxp-cli. That is structurally true — docs/assets/wasm/bxp-eval.wasm is
# bxp-core compiled for wasm32-freestanding — but "structurally true" is not
# measured. This measures it: every expression in the cross-runner corpus is
# evaluated once through the wasm build and once through the native one
# (bxp-mcp's `bxp_eval_batch`), against an identical row, and the per-expression
# result objects must match byte for byte.
#
# It has caught nothing yet. It exists because the failure it guards against —
# a wasm-only miscompile, or the hand-written browser `Io` in src/wasm.zig
# answering differently from `std.Io.Threaded` — would otherwise surface as
# documentation that quietly disagrees with the tool it documents.
#
# NOT a test-NN phase: it needs a JavaScript runtime to instantiate the module,
# which the Zig/Flutter test matrix does not otherwise require. It runs in the
# docs workflow, where the runner has node preinstalled, and can be run by hand
# anywhere node or bun is available.
#
# Exit: 0 = every expression agrees. 1 = a mismatch (listed). 2 = cannot run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

WASM="$MONO_ROOT/docs/assets/wasm/bxp-eval.wasm"
BXP_MCP="$MONO_ROOT/bxp-mcp/zig-out/bin/bxp-mcp"

# A missing runtime is a hard failure, not a skip: a gate that silently passes
# when it did not run is worse than no gate.
JS=""
for c in node bun; do
    if command -v "$c" >/dev/null 2>&1; then JS="$c"; break; fi
done
if [[ -z "$JS" ]]; then
    echo "ERROR: neither node nor bun found; cannot instantiate the wasm module." >&2
    exit 2
fi

if [[ ! -f "$WASM" ]]; then
    echo "==> building the scratchpad engine first"
    bash "$SCRIPT_DIR/gen-wasm-playground.sh"
fi

if [[ ! -x "$BXP_MCP" ]]; then
    echo "==> building bxp-mcp (native runner)"
    (cd "$MONO_ROOT/bxp-mcp" && zig build -Doptimize=ReleaseSafe -Dcpu=baseline)
fi

echo "==> comparing wasm and native over scripts/test-06-expr-corpus.txt ($JS)"
BXP_JS="$JS" python3 "$SCRIPT_DIR/check-wasm-parity.py"
