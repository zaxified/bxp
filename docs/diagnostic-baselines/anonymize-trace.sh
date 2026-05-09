#!/usr/bin/env bash
# anonymize-trace.sh — strip Windows username from BXP diagnostic traces.
#
# Usage:
#   anonymize-trace.sh <input-dir> [output-dir]
#
# If output-dir is omitted, writes to <input-dir>-anon/.
# All regular files in input-dir are copied; every occurrence of the
# detected Windows username (case-insensitive) is replaced with `<user>`.
#
# Inputs handled: diagnostic-*.ndjson, diagnostic-native-*.log,
# diagnostic-probe.txt, bxp-gui.json — anything else passes through with
# the same substitution.

set -euo pipefail

if [ "$#" -lt 1 ] || [ ! -d "$1" ]; then
  echo "Usage: $0 <input-dir> [output-dir]" >&2
  exit 1
fi

src=${1%/}
dst=${2:-${src}-anon}
mkdir -p "$dst"

# Detect username from any `Users\NAME\` or `Users\\NAME\\` (JSON-escaped)
# match in the input files. Prefer the first hit; warn if multiple distinct
# names are found.
mapfile -t names < <(
  grep -ahioE 'Users[\\/]+[A-Za-z0-9._-]+' "$src"/* 2>/dev/null \
    | perl -pe 's|^Users[\\/]+||i' \
    | sort -u
)

if [ "${#names[@]}" -eq 0 ]; then
  echo "Could not detect a Windows username in $src" >&2
  exit 1
fi

if [ "${#names[@]}" -gt 1 ]; then
  # Multiple candidates differ by case (e.g. Zak vs zak from cwd vs API path).
  # Pick the longest then alphabetically-first as the canonical token; the
  # case-insensitive substitution catches every variant anyway.
  printf 'note: multiple username candidates found: %s\n' "${names[*]}" >&2
fi

username=${names[0]}
echo "Detected username: '$username' -> <user>"

shopt -s nullglob
count=0
for f in "$src"/*; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  perl -pe "s/\\Q${username}\\E/<user>/gi" "$f" > "$dst/$base"
  count=$((count + 1))
done

echo "Anonymized $count file(s): $src -> $dst"
