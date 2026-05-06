#!/usr/bin/env bash
# Top-level release wrapper. Calls the console + desktop release scripts
# in sequence so a single invocation produces both archive families.
#
# Usage (from any directory):
#   bash scripts/release.sh           — uses latest git tag as version
#   bash scripts/release.sh v0.2.0    — uses the given version string
#
# The desktop branch is host-OS-specific (Flutter desktop has no
# cross-compile); on a non-Linux host the desktop script will produce
# only that host's bundle. GitHub Actions runs all three desktop hosts
# in parallel and collects artifacts. Locally, this wrapper builds the
# console set + the host's desktop set.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/release-console.sh" "$@"

if [ -x "$SCRIPT_DIR/release-desktop.sh" ]; then
    "$SCRIPT_DIR/release-desktop.sh" "$@"
fi
