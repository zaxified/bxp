#!/usr/bin/env bash
#
# One-off output verification for the chunking refactor.
#
# Runs bxp-cli over every available input set (datasets/, docs/examples/real-world/,
# and optional gitignored DEV/) and copies every produced output file into
# <destdir>/<source>/<relative-path>, so two runs (before and after the refactor)
# can be compared with:  diff -r <pre-dir> <post-dir>
#
# Usage:
#   scripts/bench/verify-output.sh <destdir>
#
# Typical workflow:
#   bash scripts/bench/verify-output.sh /tmp/bxp-pre     # before refactor
#   # ... do the refactor + rebuild ...
#   bash scripts/bench/verify-output.sh /tmp/bxp-post    # after refactor
#   diff -r /tmp/bxp-pre /tmp/bxp-post                   # must be empty
#
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BXP="$REPO_ROOT/bxp-cli/zig-out/bin/bxp-cli"

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <destdir>" >&2; exit 2
fi
DEST="$1"
mkdir -p "$DEST"

if [ ! -x "$BXP" ]; then
  echo "bxp-cli binary missing — build with: (cd bxp-cli && zig build -Doptimize=ReleaseFast)" >&2
  exit 1
fi

# Run bxp-cli with the given config, then copy every newly-produced output
# file (matched by suffix) under $DEST/$tag/, preserving the original layout
# relative to $base.
run_and_capture() {
  local tag="$1" base="$2" config_args="$3" out_suffix="$4"

  # Wipe stale outputs first so we measure THIS run's products only.
  find "$base" -maxdepth 4 -name "*$out_suffix" -type f -delete 2>/dev/null || true

  ( cd "$base" && eval "$BXP $config_args" --quiet ) || {
    echo "  [warn] bxp-cli exited non-zero for $tag (continuing)" >&2
  }

  while IFS= read -r -d '' f; do
    local rel="${f#$base/}"
    local dst="$DEST/$tag/$rel"
    mkdir -p "$(dirname "$dst")"
    cp "$f" "$dst"
  done < <(find "$base" -maxdepth 4 -name "*$out_suffix" -type f -print0)
}

# 1. datasets/ — each subdir has its own sample.json
echo "=== datasets/ ==="
for d in "$REPO_ROOT"/datasets/*/; do
  [ -f "$d/sample.json" ] || continue
  name=$(basename "$d")
  echo "  $name"
  run_and_capture "datasets/$name" "$d" "--config sample.json" ".csvx"
done

# 2. docs/examples/real-world/ — each subdir has its own sample.json
echo "=== docs/examples/real-world/ ==="
for d in "$REPO_ROOT"/docs/examples/real-world/*/; do
  [ -f "$d/sample.json" ] || continue
  name=$(basename "$d")
  echo "  $name"
  run_and_capture "docs/examples/real-world/$name" "$d" "--config sample.json" ".csvx"
done

# 3. DEV/ — shared config, gitignored private data (skip if absent)
if [ -f "$REPO_ROOT/DEV/bxp-cli.json" ]; then
  echo "=== DEV/ (private data) ==="
  echo "  shared config: DEV/bxp-cli.json"
  run_and_capture "DEV" "$REPO_ROOT/DEV" "--config bxp-cli.json" ".csvx"
else
  echo "=== DEV/ — skipped (no DEV/bxp-cli.json) ==="
fi

echo
echo "Done. Outputs captured to: $DEST"
echo "Compare runs with:  diff -r <pre-dir> $DEST"
