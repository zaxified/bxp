#!/usr/bin/env bash
# Fetch the FULL Eurostat `demo_pjan` table — population on 1 January, every
# year (1960→latest) for every age/sex/geo combination, in Eurostat's bulk TSV
# format. No login required; free reuse with attribution (Commission Decision
# 2011/833/EU). Source: Eurostat dissemination API.
#
#   bash fetch-full.sh
#   bxp-cli --config full.json   # cleans every ~17.7k rows
#
# The committed sample.csv is a column-slice (years 2021-2023) of the TOTAL/T
# rows only; the full file carries all dimension combinations and all years.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_DIR="$SCRIPT_DIR/full"
URL="https://ec.europa.eu/eurostat/api/dissemination/sdmx/2.1/data/demo_pjan?format=TSV&compressed=false"
TSV="$FULL_DIR/demo_pjan.tsv"
mkdir -p "$FULL_DIR"
if [ -f "$TSV" ]; then echo "already downloaded: $TSV"; exit 0; fi
echo "downloading demo_pjan bulk TSV …"
if ! curl -fSL --retry 3 -o "$TSV" "$URL"; then echo "download failed" >&2; rm -f "$TSV"; exit 1; fi
echo "ready: $TSV ($(du -h "$TSV"|cut -f1), $(($(wc -l < "$TSV")-1)) rows × ~66 year columns)"
