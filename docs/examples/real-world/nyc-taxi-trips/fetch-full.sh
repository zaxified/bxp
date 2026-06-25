#!/usr/bin/env bash
# Fetch the FULL 2019 NYC Yellow Taxi trip dataset for the scale demonstration.
#
# NOTE on the source: the NYC TLC retired its public CSV downloads in favour of
# Parquet (the cloudfront `.csv` URLs now return 403). The same trip records —
# in the original CSV layout, with the `MM/DD/YYYY hh:mm:ss AM/PM` timestamps
# this example's template expects — are mirrored on NYC OpenData (Socrata), so
# that is what we pull here. It is the complete 2019 dataset (~84M rows /
# ~8 GB), a superset of the committed sample's January slice.
#
# The download lands in ./full/ (gitignored). Run it through the bundled scale
# config afterwards:
#
#   bash fetch-full.sh          # ~8 GB — large; resumable via curl -C -
#   bxp-cli --config full.json
#
# Re-running is cheap: an already-downloaded full/yellow_tripdata_2019.csv is
# reused.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_DIR="$SCRIPT_DIR/full"
URL="https://data.cityofnewyork.us/api/views/2upf-qytp/rows.csv?accessType=DOWNLOAD"
CSV="$FULL_DIR/yellow_tripdata_2019.csv"

mkdir -p "$FULL_DIR"

if [ -f "$CSV" ]; then
    echo "already downloaded: $CSV ($(du -h "$CSV" | cut -f1))"
    exit 0
fi

echo "downloading the full 2019 dataset (~8 GB) — this takes a while …"
# -C - resumes a partial download if the script is re-run after an interruption.
if ! curl -fSL -C - --retry 3 -o "$CSV" "$URL"; then
    echo "download failed (partial file kept for resume: $CSV)" >&2
    exit 1
fi

rows=$(wc -l < "$CSV")
echo "ready: $CSV ($(du -h "$CSV" | cut -f1), $rows rows)"
