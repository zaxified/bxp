#!/usr/bin/env bash
# Bump versions across all 5 manifests + generate a CHANGELOG.md entry
# from commits since the last release tag, in one step. Commits both
# changes as "release: prepare <version> (<date>)". Push manually after
# review.
#
# Usage (from any directory):
#   bash scripts/release-changelog.sh patch     # all manifests +0.0.1
#   bash scripts/release-changelog.sh minor     # all manifests +0.1.0
#   bash scripts/release-changelog.sh major     # all manifests +1.0.0
#   bash scripts/release-changelog.sh 0.3.0     # explicit: set all to 0.3.0
#   bash scripts/release-changelog.sh patch --dry-run    # preview only
#
# After review:
#   git push origin master
#   bash scripts/release-tag.sh                  # CalVer tag → CI publishes

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$SCRIPT_DIR")"

# Manifest files participating in the lockstep bump. Lib manifests
# (bxp-core, json5_ast) move with apps for now — when a lib eventually
# diverges, drop it from this list and bump it manually per its own
# semver.
MANIFESTS=(
    "$MONO_ROOT/bxp-core/build.zig.zon"
    "$MONO_ROOT/bxp-cli/build.zig.zon"
    "$MONO_ROOT/bxp-fmt/build.zig.zon"
    "$MONO_ROOT/bxp-gui-bridge/build.zig.zon"
    "$MONO_ROOT/bxp-gui/pubspec.yaml"
    "$MONO_ROOT/bxp-gui/packages/json5_ast/pubspec.yaml"
)

DRY_RUN=false
BUMP_ARG=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) BUMP_ARG="$arg" ;;
    esac
done

if [ -z "$BUMP_ARG" ]; then
    echo "usage: $(basename "$0") {patch|minor|major|x.y.z} [--dry-run]" >&2
    exit 1
fi

# ─── Resolve the new version ────────────────────────────────────────

current_version() {
    grep -E '^\s*\.version|^version:' "$1" \
        | head -n1 \
        | sed -E 's/^\s*\.version\s*=\s*"([^"]+)".*/\1/; s/^version:\s*([^[:space:]]+).*/\1/'
}

bump_semver() {
    local current=$1
    local kind=$2
    local IFS=.
    read -r major minor patch <<< "$current"
    case "$kind" in
        patch) patch=$((patch + 1)) ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        major) major=$((major + 1)); minor=0; patch=0 ;;
    esac
    echo "$major.$minor.$patch"
}

# Use bxp-cli/build.zig.zon as the canonical "current version" reference.
# All apps are in lockstep so any of them works.
CURRENT=$(current_version "$MONO_ROOT/bxp-cli/build.zig.zon")

case "$BUMP_ARG" in
    patch|minor|major)
        NEW=$(bump_semver "$CURRENT" "$BUMP_ARG")
        ;;
    [0-9]*.[0-9]*.[0-9]*)
        NEW="$BUMP_ARG"
        ;;
    *)
        echo "error: unrecognised bump type '$BUMP_ARG'" >&2
        echo "       expected: patch | minor | major | x.y.z" >&2
        exit 1
        ;;
esac

echo "[1/3] Bumping versions: $CURRENT → $NEW"
for m in "${MANIFESTS[@]}"; do
    cur=$(current_version "$m")
    rel=${m#$MONO_ROOT/}
    printf '   %-50s %s → %s\n' "$rel" "$cur" "$NEW"
    if ! $DRY_RUN; then
        # `.version = "X"` (zon) and `version: X` (yaml) — sed handles both
        # by anchoring on the keyword. Write-to-tmp + mv instead of `sed -i`
        # so the script also works under BSD sed (macOS), which requires an
        # argument after `-i` and disagrees with GNU on the empty form.
        tmp=$(mktemp)
        sed -E \
            -e "s/^(\s*\.version\s*=\s*\")[^\"]+(\".*)$/\1$NEW\2/" \
            -e "s/^(version:\s*)[^[:space:]]+(.*)$/\1$NEW\2/" \
            "$m" > "$tmp"
        mv "$tmp" "$m"
    fi
done

# ─── Changelog from git log ─────────────────────────────────────────

LAST_TAG=$(git -C "$MONO_ROOT" describe --tags --abbrev=0 2>/dev/null || echo "")
TODAY=$(date +%Y.%m.%d)

if [ -z "$LAST_TAG" ]; then
    RANGE=""
    echo "[2/3] Generating CHANGELOG entry (no previous tag — full history)..."
else
    RANGE="$LAST_TAG..HEAD"
    COUNT=$(git -C "$MONO_ROOT" rev-list --count "$RANGE")
    echo "[2/3] Generating CHANGELOG entry from $COUNT commits since $LAST_TAG..."
fi

# Group commits by conventional-commit type. `chore`, `docs`, `refactor`,
# `style`, `test`, `build`, `ci` fall under Internal; `feat` → Features;
# `fix`, `bug`, `perf`, `revert` → Fixes; rest → Other (a sign the commit
# message lacks a conventional prefix — fix the message rather than letting
# it leak into the changelog).
classify() {
    local subject=$1
    case "$subject" in
        feat\(*|feat:*)              echo "Features" ;;
        fix\(*|fix:*|\
        bug\(*|bug:*|\
        perf\(*|perf:*|\
        revert\(*|revert:*)          echo "Fixes" ;;
        chore\(*|chore:*|\
        docs\(*|docs:*|\
        refactor\(*|refactor:*|\
        style\(*|style:*|\
        test\(*|test:*|\
        build\(*|build:*|\
        ci\(*|ci:*)                  echo "Internal" ;;
        *)                           echo "Other" ;;
    esac
}

# Skip-list — commits that should never appear in the changelog regardless
# of their message. Match against the full subject line.
should_skip() {
    local subject=$1
    case "$subject" in
        # Mechanical file moves with no descriptive intent.
        mv\ *|"Merge "*|"Revert"\ \"*) return 0 ;;
        # Release-prep commits emitted by this very script.
        "release: prepare "*) return 0 ;;
    esac
    return 1
}

NEW_ENTRY=$(mktemp)
{
    echo ""
    echo "## $TODAY — bxp-cli $NEW, bxp-fmt $NEW, bxp-gui $NEW"
    echo ""

    declare -A buckets
    declare -A order  # preserves insertion order for stable section sequence
    idx=0

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if should_skip "$line"; then continue; fi
        cat=$(classify "$line")
        if [ -z "${order[$cat]+x}" ]; then
            order[$cat]=$idx
            idx=$((idx + 1))
        fi
        buckets[$cat]+="- $line"$'\n'
    done < <(git -C "$MONO_ROOT" log $RANGE --pretty='%s' --reverse)

    # Stable section order regardless of commit order:
    for cat in "Features" "Fixes" "Internal" "Other"; do
        if [ -n "${buckets[$cat]+x}" ]; then
            echo "### $cat"
            echo ""
            echo -n "${buckets[$cat]}"
            echo ""
        fi
    done
} > "$NEW_ENTRY"

CHANGELOG="$MONO_ROOT/CHANGELOG.md"
if $DRY_RUN; then
    echo "[3/3] DRY-RUN — would prepend to $CHANGELOG:"
    echo "─────────────"
    cat "$NEW_ENTRY"
    echo "─────────────"
    rm -f "$NEW_ENTRY"
    exit 0
fi

if [ ! -f "$CHANGELOG" ]; then
    echo "# Changelog" > "$CHANGELOG"
    echo "" >> "$CHANGELOG"
fi

# Prepend new entry after the "# Changelog" heading.
TMP=$(mktemp)
{
    head -n 1 "$CHANGELOG"
    cat "$NEW_ENTRY"
    tail -n +2 "$CHANGELOG"
} > "$TMP"
mv "$TMP" "$CHANGELOG"
rm -f "$NEW_ENTRY"

# ─── Commit ─────────────────────────────────────────────────────────

echo "[3/3] Committing as 'release: prepare $NEW ($TODAY)'"
git -C "$MONO_ROOT" add "${MANIFESTS[@]}" "$CHANGELOG"
git -C "$MONO_ROOT" commit -m "release: prepare $NEW ($TODAY)" >/dev/null
echo ""
echo "Done. Review CHANGELOG.md, then:"
echo "  git push origin master"
echo "  bash scripts/release-tag.sh"
