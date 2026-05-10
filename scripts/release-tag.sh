#!/usr/bin/env bash
# Cut a release tag from the version already written into the manifests
# by `release-changelog.sh`, and push it. The
# `.github/workflows/release.yml` workflow picks up the tag and builds
# both bxp-console and bxp-desktop archives, then publishes a GitHub
# Release.
#
# Usage (from any directory):
#   bash scripts/release-tag.sh             # tag = v<bxp-cli/build.zig.zon version>
#   bash scripts/release-tag.sh --dry-run   # show what would be tagged
#
# Run AFTER `release-changelog.sh` has bumped versions and prepared
# CHANGELOG.md, and after that commit has been pushed to master.

set -e

MONO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *)
            echo "error: unrecognised argument '$arg'" >&2
            echo "usage: $(basename "$0") [--dry-run]" >&2
            exit 1
            ;;
    esac
done

# ─── Read the canonical version ──────────────────────────────────────
#
# bxp-cli/build.zig.zon is the single source of truth for "current
# version" — release-changelog.sh bumps every manifest in lockstep, so
# any of them works, and this matches the canonical reference used
# there.

CANON="$MONO_ROOT/bxp-cli/build.zig.zon"
VERSION=$(grep -E '^\s*\.version\s*=\s*"' "$CANON" \
    | head -n1 \
    | sed -E 's/^\s*\.version\s*=\s*"([^"]+)".*/\1/')

if [ -z "$VERSION" ]; then
    echo "error: could not read .version from $CANON" >&2
    exit 1
fi

TAG="v$VERSION"

# ─── Sanity checks ──────────────────────────────────────────────────

if git -C "$MONO_ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
    echo "error: tag $TAG already exists locally" >&2
    echo "       did you forget to run release-changelog.sh first?" >&2
    exit 1
fi

# Refuse on dirty tree — the manifest bump should be committed first.
if [ -n "$(git -C "$MONO_ROOT" status --porcelain)" ]; then
    echo "error: working tree is dirty" >&2
    echo "       commit (or run release-changelog.sh first) before tagging" >&2
    exit 1
fi

# ─── Tag + push ─────────────────────────────────────────────────────

if $DRY_RUN; then
    echo "DRY-RUN — would tag and push:"
    echo "  git tag $TAG"
    echo "  git push origin $TAG"
    exit 0
fi

echo "Creating tag $TAG..."
git -C "$MONO_ROOT" tag "$TAG"
echo "Pushing tag to origin..."
git -C "$MONO_ROOT" push origin "$TAG"
echo ""
echo "Done. GitHub Actions should pick up the tag and start building."
echo "Track at: https://github.com/zaxified/bxp/actions"
