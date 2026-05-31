#!/usr/bin/env bash
# Fetch the FULL IMDb title.basics dataset (~11M rows, 222 MB gzip → ~1 GB TSV)
# for the scale demonstration. The committed sample.csv is a 500-row slice that
# shows the data quirks; this pulls the real file so you can prove BXP processes
# the whole thing at constant memory.
#
# The download lands in ./full/ (gitignored). Run it through the bundled
# scale config afterwards:
#
#   bash fetch-full.sh
#   bxp-cli --config full.json
#
# Re-running is cheap: an already-extracted full/title.basics.tsv is reused.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_DIR="$SCRIPT_DIR/full"
URL="https://datasets.imdbws.com/title.basics.tsv.gz"
GZ="$FULL_DIR/title.basics.tsv.gz"
TSV="$FULL_DIR/title.basics.tsv"

mkdir -p "$FULL_DIR"

if [ -f "$TSV" ]; then
    echo "already extracted: $TSV ($(du -h "$TSV" | cut -f1))"
    exit 0
fi

echo "downloading $URL …"
if ! curl -fSL --retry 3 -o "$GZ" "$URL"; then
    echo "download failed" >&2
    rm -f "$GZ"
    exit 1
fi

echo "decompressing …"
if ! gunzip -kf "$GZ"; then
    echo "decompress failed" >&2
    rm -f "$TSV"
    exit 1
fi
rm -f "$GZ"

rows=$(wc -l < "$TSV")
echo "ready: $TSV ($(du -h "$TSV" | cut -f1), $rows rows)"
