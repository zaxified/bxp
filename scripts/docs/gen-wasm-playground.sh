#!/usr/bin/env bash
# Build the docs playground's wasm engine into docs/assets/wasm/.
#
# The artifact is bxp-core compiled for wasm32-freestanding (src/wasm.zig →
# inspect.evalBatchIo) — the same expression evaluator bxp-cli, bxp-mcp and the
# GUI bridge run, making the browser a fourth consumer of one engine rather
# than a reimplementation.
#
# Deliberately NOT tracked in git and NOT a test-NN phase: it is a generated
# binary, so it belongs to the docs build the same way `site/` does. Run this
# before `mkdocs build` / `mkdocs serve` (scripts/docs/gen-docs.sh does it for you);
# without it the widget renders and reports that the engine failed to load,
# which is the intended degradation — the surrounding prose still reads.
#
# ReleaseSmall, not ReleaseSafe: this one artifact is shipped over the wire to
# every reader of the page, so it follows the release-01 sizing rule rather than
# the test-suite's single-optimize-mode rule (see CLAUDE.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
OUT_DIR="$MONO_ROOT/docs/assets/wasm"

echo "==> building bxp-eval.wasm (wasm32-freestanding, ReleaseSmall)"
(
    cd "$MONO_ROOT/bxp-core"
    zig build wasm -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
)

mkdir -p "$OUT_DIR"
cp "$MONO_ROOT/bxp-core/zig-out/bin/bxp-eval.wasm" "$OUT_DIR/bxp-eval.wasm"

raw=$(wc -c <"$OUT_DIR/bxp-eval.wasm")
gz=$(gzip -9 -c "$OUT_DIR/bxp-eval.wasm" | wc -c)
printf '==> %s  (%d KiB raw, %d KiB gzipped over the wire)\n' \
    "docs/assets/wasm/bxp-eval.wasm" "$((raw / 1024))" "$((gz / 1024))"
