#!/usr/bin/env bash
# Cross-compile bxp-cli and bxp-fmt for x86_64-linux-musl (static) and stage
# them under build-bin/ so electrobun's build.copy can pull them into
# Resources/app/bin/ of the packaged app.
#
# Driven by `bun run build` in bxp-ui/package.json — do not run directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_ROOT="$(dirname "$SCRIPT_DIR")"
MONO_ROOT="$(dirname "$UI_ROOT")"
STAGE="$UI_ROOT/build-bin"

TARGET="${BXP_UI_BIN_TARGET:-x86_64-linux-musl}"
OPTIMIZE="${BXP_UI_BIN_OPTIMIZE:-ReleaseSmall}"

mkdir -p "$STAGE"

echo "[stage-bins] building bxp-cli ($TARGET, $OPTIMIZE)"
(cd "$MONO_ROOT/bxp-cli" && zig build -Dtarget="$TARGET" -Doptimize="$OPTIMIZE")
cp "$MONO_ROOT/bxp-cli/zig-out/bin/bxp-cli" "$STAGE/bxp-cli"
chmod +x "$STAGE/bxp-cli"

echo "[stage-bins] building bxp-fmt ($TARGET, $OPTIMIZE)"
(cd "$MONO_ROOT/bxp-fmt" && zig build -Dtarget="$TARGET" -Doptimize="$OPTIMIZE")
cp "$MONO_ROOT/bxp-fmt/zig-out/bin/bxp-fmt" "$STAGE/bxp-fmt"
chmod +x "$STAGE/bxp-fmt"

echo "[stage-bins] staged:"
ls -lh "$STAGE"

echo "[stage-bins] restoring native dev binaries"
(cd "$MONO_ROOT/bxp-cli" && zig build)
(cd "$MONO_ROOT/bxp-fmt" && zig build)
