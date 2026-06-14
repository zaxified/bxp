#!/usr/bin/env bash
# Generate (or verify) SHA256SUMS for the release artifacts in a dir tree.
#
# Generate mode (default) — emit `sha256sum`-style lines to stdout:
#   bash release-03-checksums.sh <dir>            > <dir>/SHA256SUMS
#   <hex>  <basename>
#
# Check mode — re-verify an existing SHA256SUMS against the files on disk
# before upload, so a truncated / corrupted artifact (or an empty manifest)
# fails the release loudly instead of shipping:
#   bash release-03-checksums.sh --check <dir> <dir>/SHA256SUMS
#
# UpdaterService verifies downloaded artifacts against the generated file.

set -e

MODE=generate
if [ "$1" = "--check" ]; then
    MODE=check
    shift
fi

DIR=${1:-.}

if [ ! -d "$DIR" ]; then
    echo "error: $DIR is not a directory" >&2
    exit 1
fi

# GNU coreutils ships `sha256sum`; BSD/macOS ships `shasum -a 256`. CI runs
# this on ubuntu, but local smoke builds on a Mac should also work.
if command -v sha256sum >/dev/null 2>&1; then
    _hash() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
    _hash() { shasum -a 256 "$1" | awk '{print $1}'; }
else
    echo "error: neither sha256sum nor shasum found" >&2
    exit 1
fi

if [ "$MODE" = check ]; then
    SUMS=${2:?usage: release-03-checksums.sh --check <dir> <sumsfile>}
    if [ ! -f "$SUMS" ]; then
        echo "error: checksum file $SUMS not found" >&2
        exit 1
    fi
    count=0
    # Lines are "<hex>  <basename>"; read splits on whitespace so the second
    # field is the name (artifact names carry no spaces).
    while read -r expected name; do
        [ -z "$expected" ] && continue
        file="$DIR/$name"
        if [ ! -f "$file" ]; then
            echo "error: '$name' is listed in SHA256SUMS but missing in $DIR" >&2
            exit 1
        fi
        actual=$(_hash "$file")
        if [ "$actual" != "$expected" ]; then
            echo "error: checksum mismatch for '$name'" >&2
            echo "       expected $expected" >&2
            echo "       actual   $actual" >&2
            exit 1
        fi
        count=$((count + 1))
    done < "$SUMS"
    if [ "$count" -eq 0 ]; then
        echo "error: SHA256SUMS is empty — no artifacts to verify" >&2
        exit 1
    fi
    echo "checksum gate: $count artifact(s) verified against $SUMS" >&2
    exit 0
fi

# Generate mode.
find "$DIR" -type f \( \
        -name 'bxp-console-*' -o \
        -name 'bxp-desktop-*' \
    \) | sort | while read -r f; do
    printf '%s  %s\n' "$(_hash "$f")" "$(basename "$f")"
done
