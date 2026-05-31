#!/usr/bin/env bash
# Fetch the FULL OpenNGC catalogue (~13,970 NGC/IC deep-sky objects). Real,
# maintained, cited open dataset (CC-BY-SA-4.0). The committed sample.csv is a
# curated slice of famous objects; this pulls the whole catalogue.
#
#   bash fetch-full.sh
#   bxp-cli --config full.json   # converts every object's RA/Dec → decimal degrees
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_DIR="$SCRIPT_DIR/full"
CSV="$FULL_DIR/NGC.csv"
URL="https://raw.githubusercontent.com/mattiaverga/OpenNGC/master/database_files/NGC.csv"
mkdir -p "$FULL_DIR"
if [ -f "$CSV" ]; then echo "already downloaded: $CSV"; exit 0; fi
echo "downloading OpenNGC catalogue …"
if ! curl -fSL --retry 3 -o "$CSV" "$URL"; then echo "download failed" >&2; rm -f "$CSV"; exit 1; fi
echo "ready: $CSV ($(du -h "$CSV"|cut -f1), $(($(wc -l < "$CSV")-1)) objects)"
