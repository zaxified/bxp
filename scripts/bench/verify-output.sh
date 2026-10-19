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

# In-flight stash (see run_and_capture): restored by the EXIT trap if the script
# is interrupted or dies between stashing and restoring.
CUR_BASE=""
CUR_STASH=""
CUR_SUFFIX=""

# Put the stashed (tracked) outputs back: drop this run's products, move the
# originals home, remove the stash dir (per-filename ops, no rm -rf).
restore_stash() {
  [ -n "$CUR_STASH" ] || return 0
  find "$CUR_BASE" -maxdepth 4 -name "*$CUR_SUFFIX" -type f -delete 2>/dev/null || true
  while IFS= read -r -d '' f; do
    local rel="${f#$CUR_STASH/}"
    mkdir -p "$(dirname "$CUR_BASE/$rel")"
    mv "$f" "$CUR_BASE/$rel"
  done < <(find "$CUR_STASH" -type f -print0)
  find "$CUR_STASH" -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true
  rmdir "$CUR_STASH" 2>/dev/null || true
  CUR_STASH=""
}
trap restore_stash EXIT

# Run bxp-cli with the given config, then copy every newly-produced output
# file (matched by suffix) under $DEST/$tag/, preserving the original layout
# relative to $base. Pre-existing outputs may be tracked fixtures, so they are
# moved aside for the run (so only THIS run's products are measured) and put
# back afterwards — also when bxp-cli fails, in which case the script stops.
run_and_capture() {
  local tag="$1" base="$2" config_args="$3" out_suffix="$4"
  base="${base%/}"

  CUR_BASE="$base"; CUR_SUFFIX="$out_suffix"
  CUR_STASH="$(mktemp -d)"
  while IFS= read -r -d '' f; do
    local srel="${f#$base/}"
    mkdir -p "$(dirname "$CUR_STASH/$srel")"
    mv "$f" "$CUR_STASH/$srel"
  done < <(find "$base" -maxdepth 4 -name "*$out_suffix" -type f -print0)

  local rc=0
  ( cd "$base" && "$BXP" $config_args --quiet ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  [error] bxp-cli exited $rc for $tag — originals restored, stopping" >&2
    restore_stash
    exit 1
  fi

  while IFS= read -r -d '' f; do
    local rel="${f#$base/}"
    local dst="$DEST/$tag/$rel"
    mkdir -p "$(dirname "$dst")"
    cp "$f" "$dst"
  done < <(find "$base" -maxdepth 4 -name "*$out_suffix" -type f -print0)
  restore_stash
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
