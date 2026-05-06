#!/usr/bin/env bash
# Build the bxp-desktop release bundle for the current host OS only.
# Flutter desktop has no cross-compile, so each platform must be built on
# its native host (locally or in GitHub Actions matrix jobs).
#
# Stub — real packaging logic lands in Phase 7 of the release-split plan.
# Until then this script no-ops cleanly so the top-level wrapper works.

set -e
echo "release-desktop.sh: not yet implemented — Phase 7 placeholder"
exit 0
