#!/usr/bin/env bash
# Copy freshly built dev binaries into both build-bin/ (Electrobun source)
# and the live dev bundle so the UI picks up the latest bxp-cli / bxp-fmt.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_CLI="$SCRIPT_DIR/../../bxp-cli/zig-out/bin/bxp-cli"
SRC_FMT="$SCRIPT_DIR/../../bxp-fmt/zig-out/bin/bxp-fmt"
SRC_ICON="$SCRIPT_DIR/../assets/appIcon.png"
BUILD_BIN="$SCRIPT_DIR/../build-bin"
DEV_RES="$SCRIPT_DIR/../build/dev-linux-x64/bxp-ui-dev/Resources"
DEV_BIN="$DEV_RES/app/bin"

cp -f "$SRC_CLI" "$BUILD_BIN/bxp-cli"
cp -f "$SRC_FMT" "$BUILD_BIN/bxp-fmt"
echo "Synced build-bin: bxp-cli $(du -sh "$BUILD_BIN/bxp-cli" | cut -f1)  bxp-fmt $(du -sh "$BUILD_BIN/bxp-fmt" | cut -f1)"

if [ -d "$DEV_BIN" ]; then
  cp -f "$SRC_CLI" "$DEV_BIN/bxp-cli"
  cp -f "$SRC_FMT" "$DEV_BIN/bxp-fmt"
  echo "Synced dev bundle: bxp-cli $(du -sh "$DEV_BIN/bxp-cli" | cut -f1)  bxp-fmt $(du -sh "$DEV_BIN/bxp-fmt" | cut -f1)"
  if [ -d "$DEV_RES" ] && [ -f "$SRC_ICON" ]; then
    cp -f "$SRC_ICON" "$DEV_RES/appIcon.png"
    echo "Synced dev icon: appIcon.png"
  fi
fi
