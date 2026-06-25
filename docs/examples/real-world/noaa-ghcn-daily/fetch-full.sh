#!/usr/bin/env bash
# Fetch the FULL GHCN-Daily record for the Central Park station (USW00094728)
# for the scale demonstration. The committed sample.csv is a 301-row slice;
# the real per-station file is the complete daily history (~150 years of rows,
# 124 columns wide).
#
# The download lands in ./full/ (gitignored). Run it through the bundled scale
# config afterwards:
#
#   bash fetch-full.sh
#   bxp-cli --config full.json
#
# Re-running is cheap: an already-downloaded full/USW00094728.csv is reused.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_DIR="$SCRIPT_DIR/full"
URL="https://www.ncei.noaa.gov/data/global-historical-climatology-network-daily/access/USW00094728.csv"
CSV="$FULL_DIR/USW00094728.csv"

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
echo "ready: $CSV ($(du -h "$CSV" | cut -f1), $rows rows, 124 cols)"
