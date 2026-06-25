#!/usr/bin/env bash
# Fetch the FULL 2018 NYC Central Park Squirrel Census as JSON (all ~3,023
# sightings) from NYC Open Data (Socrata). Public domain. The committed
# sample.in.json is the first 40 records; this pulls the whole array.
#
#   bash fetch-full.sh
#   bxp-cli --config full.json   # flattens every sighting → CSV
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_DIR="$SCRIPT_DIR/full"
JSON="$FULL_DIR/squirrel.in.json"
# $limit=5000 clears the dataset's ~3,023 rows (Socrata defaults to 1,000).
URL="https://data.cityofnewyork.us/resource/vfnx-vebw.json?\$limit=5000"
mkdir -p "$FULL_DIR"
if [ -f "$JSON" ]; then echo "already downloaded: $JSON"; exit 0; fi
echo "downloading full squirrel census …"
if ! curl -fSL --retry 3 -o "$JSON" "$URL"; then echo "download failed" >&2; rm -f "$JSON"; exit 1; fi
echo "ready: $JSON ($(du -h "$JSON"|cut -f1))"
