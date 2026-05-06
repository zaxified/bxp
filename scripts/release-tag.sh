#!/usr/bin/env bash
# Cut a release: create a CalVer tag (YYYY.MM.DD with -N suffix when
# multiple releases happen on the same day) and push it. The
# `.github/workflows/release.yml` workflow picks up the tag and builds
# both bxp-console and bxp-desktop archives, then publishes a GitHub
# Release.
#
# Usage (from any directory):
#   bash scripts/release-tag.sh              # auto-derive YYYY.MM.DD[-N]
#   bash scripts/release-tag.sh 2026.05.06   # explicit tag (without "v" prefix)
#   bash scripts/release-tag.sh --dry-run    # show what would be tagged
#
# Run AFTER `release-changelog.sh` has bumped versions and prepared
# CHANGELOG.md, and after that commit has been pushed to master.

set -e

MONO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DRY_RUN=false
EXPLICIT=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) EXPLICIT="$arg" ;;
    esac
done

# ─── Derive the tag ─────────────────────────────────────────────────

if [ -n "$EXPLICIT" ]; then
    BASE="${EXPLICIT#v}"   # strip "v" if user typed it
    TAG="v$BASE"
else
    BASE=$(date +%Y.%m.%d)
    # Find existing same-day tags; suffix `-N` for the next free counter.
    EXISTING=$(git -C "$MONO_ROOT" tag --list "v$BASE*" | sort)
    if [ -z "$EXISTING" ]; then
        TAG="v$BASE"
    else
        # Highest existing -N suffix (or 0 if only `v$BASE` exists).
        N=$(echo "$EXISTING" | grep -oE -- "-[0-9]+\$" | sort -t- -k2 -n | tail -n1 | tr -d -)
        N=${N:-0}
        TAG="v$BASE-$((N + 1))"
    fi
fi

# ─── Sanity check ───────────────────────────────────────────────────

if git -C "$MONO_ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
    echo "error: tag $TAG already exists locally" >&2
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
