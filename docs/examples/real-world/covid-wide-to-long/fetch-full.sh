#!/usr/bin/env bash
# Fetch the FULL Johns Hopkins COVID-19 confirmed-cases global time series.
# It is the canonical "wide" dataset — one column per day — and the classic
# reshape-to-long teaching case. Source: CSSEGISandData/COVID-19 (JHU CSSE),
# archived (stopped updating March 2023). CC BY 4.0.
#
#   bash fetch-full.sh
#   bxp-cli --config full.json   # unpivots all ~280 country/region rows
#
# Note: the file has ~1147 columns — comfortably inside bxp's 16384-column
# ceiling (MAX_COLUMNS), so every day-column stays reachable and the run is
# warning-free.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_DIR="$SCRIPT_DIR/full"
URL="https://raw.githubusercontent.com/CSSEGISandData/COVID-19/master/csse_covid_19_data/csse_covid_19_time_series/time_series_covid19_confirmed_global.csv"
CSV="$FULL_DIR/time_series_covid19_confirmed_global.csv"
mkdir -p "$FULL_DIR"
if [ -f "$CSV" ]; then echo "already downloaded: $CSV"; exit 0; fi
echo "downloading $URL …"
if ! curl -fSL --retry 3 -o "$CSV" "$URL"; then echo "download failed" >&2; rm -f "$CSV"; exit 1; fi
echo "ready: $CSV ($(du -h "$CSV"|cut -f1), $(($(wc -l < "$CSV")-1)) country/region rows × ~1147 day columns)"
