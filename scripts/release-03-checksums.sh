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

find "$DIR" -type f \( \
        -name 'bxp-console-*' -o \
        -name 'bxp-desktop-*' \
    \) | sort | while read -r f; do
    printf '%s  %s\n' "$(_hash "$f")" "$(basename "$f")"
done
