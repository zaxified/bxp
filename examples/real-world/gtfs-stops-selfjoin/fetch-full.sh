#!/usr/bin/env bash
# Fetch the full NYC subway GTFS feed and extract stops.txt for the complete
# self-join run. Source: MTA (rrgtfsfeeds), public.
#   bash fetch-full.sh
#   bxp-cli --config full.json
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_DIR="$SCRIPT_DIR/full"
URL="http://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip"
ZIP="$FULL_DIR/gtfs_subway.zip"
TXT="$FULL_DIR/stops.txt"
mkdir -p "$FULL_DIR"
if [ -f "$TXT" ]; then echo "already extracted: $TXT"; exit 0; fi
echo "downloading $URL …"
if ! curl -fSL --retry 3 -o "$ZIP" "$URL"; then echo "download failed" >&2; rm -f "$ZIP"; exit 1; fi
unzip -o "$ZIP" stops.txt -d "$FULL_DIR" >/dev/null
rm -f "$ZIP"
echo "ready: $TXT ($(($(wc -l < "$TXT")-1)) stops)"
