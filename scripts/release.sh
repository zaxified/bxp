#!/usr/bin/env bash
# Run the local release-build flow. Iterates `release-NN-*.sh` siblings
# in numeric order — adding a phase = drop `release-NN-foo.sh` next to
# this file and it picks up automatically. Standalone helpers without a
# numeric prefix (`release-changelog.sh`, `release-tag.sh`) are NOT
# invoked here; they're human-driven publish-flow steps.
#
# This wrapper produces release-style artifacts under `releases/console/`
# and `releases/desktop/` for local smoke testing — it does NOT publish
# anything. Real publishing happens via `scripts/release-tag.sh` →
# GitHub Actions.
#
# Usage (from any directory):
#   bash scripts/release.sh              — uses latest git tag as version
#   bash scripts/release.sh v0.2.0       — uses the given version string

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

shopt -s nullglob
for phase in "$SCRIPT_DIR"/release-[0-9][0-9]-*.sh; do
    bash "$phase" "$@"
done
