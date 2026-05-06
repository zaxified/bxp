#!/usr/bin/env bash
# Generate SHA256SUMS for every artifact in the given dir tree, sorted
# deterministically. Output format matches `sha256sum`:
#
#   <hex>  <basename>
#
# UpdaterService verifies downloaded artifacts against this file.

set -e

DIR=${1:-.}

if [ ! -d "$DIR" ]; then
    echo "error: $DIR is not a directory" >&2
    exit 1
fi

find "$DIR" -type f \( \
        -name 'bxp-console-*' -o \
        -name 'bxp-desktop-*' \
    \) | sort | while read -r f; do
    hex=$(sha256sum "$f" | awk '{print $1}')
    printf '%s  %s\n' "$hex" "$(basename "$f")"
done
