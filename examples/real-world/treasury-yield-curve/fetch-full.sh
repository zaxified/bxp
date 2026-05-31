#!/usr/bin/env bash
# Fetch the FULL US Treasury Daily Par Yield Curve Rates for 2023 + 2024 and
# concatenate them into one CSV (header once). Public domain (US Treasury).
# Source: home.treasury.gov resource-center daily CSV endpoint.
#
#   bash fetch-full.sh
#   bxp-cli --config full.json   # unpivots every business day → 13 tidy rows
#
# We fetch only 2023-2024 on purpose: both years carry the full 13-maturity
# schema. Older Treasury files have a DIFFERENT column set (the "2 Mo" tenor
# began 2018, "4 Mo" only in Oct 2022, "20 Yr"/"30 Yr" have historical gaps),
# so concatenating them under one header would misalign columns.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_DIR="$SCRIPT_DIR/full"
OUT="$FULL_DIR/treasury_2023_2024.csv"
BASE="https://home.treasury.gov/resource-center/data-chart-center/interest-rates/daily-treasury-rates.csv"
mkdir -p "$FULL_DIR"
if [ -f "$OUT" ]; then echo "already downloaded: $OUT"; exit 0; fi

tmp_hdr=""
: > "$OUT.tmp"
for yr in 2023 2024; do
  url="$BASE/$yr/all?type=daily_treasury_yield_curve&field_tdr_date_value=$yr&page&_format=csv"
  echo "downloading $yr …"
  yr_csv="$FULL_DIR/.$yr.csv"
  if ! curl -fSL --retry 3 -o "$yr_csv" "$url"; then echo "download failed for $yr" >&2; rm -f "$yr_csv" "$OUT.tmp"; exit 1; fi
  hdr="$(head -1 "$yr_csv")"
  if [ -z "$tmp_hdr" ]; then tmp_hdr="$hdr"; printf '%s\n' "$hdr" > "$OUT.tmp"; fi
  if [ "$hdr" != "$tmp_hdr" ]; then echo "header mismatch for $yr — schema differs, aborting" >&2; rm -f "$yr_csv" "$OUT.tmp"; exit 1; fi
  tail -n +2 "$yr_csv" >> "$OUT.tmp"
  rm -f "$yr_csv"
done
mv "$OUT.tmp" "$OUT"
echo "ready: $OUT ($(du -h "$OUT"|cut -f1), $(($(wc -l < "$OUT")-1)) business days × 13 maturities)"
