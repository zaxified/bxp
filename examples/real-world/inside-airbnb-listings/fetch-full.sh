#!/usr/bin/env bash
# Fetch the FULL Inside Airbnb NYC listings file (2026-02-13 scrape) for the
# scale demonstration. The committed sample.csv is a 300-row slice; the real
# file is the complete current NYC listing set (~tens of thousands of rows).
#
# The download lands in ./full/ (gitignored). Run it through the bundled scale
# config afterwards:
#
#   bash fetch-full.sh
#   bxp-cli --config full.json
#
# Re-running is cheap: an already-downloaded full/listings.csv is reused.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_DIR="$SCRIPT_DIR/full"
URL="https://data.insideairbnb.com/united-states/ny/new-york-city/2026-02-13/visualisations/listings.csv"
CSV="$FULL_DIR/listings.csv"

mkdir -p "$FULL_DIR"

if [ -f "$CSV" ]; then
    echo "already downloaded: $CSV ($(du -h "$CSV" | cut -f1))"
    exit 0
fi

echo "downloading $URL …"
if ! curl -fSL --retry 3 -o "$CSV" "$URL"; then
    echo "download failed" >&2
    rm -f "$CSV"
    exit 1
fi

rows=$(wc -l < "$CSV")
echo "ready: $CSV ($(du -h "$CSV" | cut -f1), $rows rows)"
