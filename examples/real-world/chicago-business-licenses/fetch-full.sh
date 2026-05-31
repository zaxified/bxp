#!/usr/bin/env bash
# Fetch the FULL City of Chicago business-licenses dataset (~1.2M rows) for the
# scale demonstration. The committed sample.csv is a 223-row slice selected to
# cover all four LICENSE STATUS codes.
#
# We pull from the Socrata SODA endpoint with the SAME column selection as the
# slice (lowercase API field names like `license_status`), so full.json reuses
# sample.json's schema verbatim. (The bulk "rows.csv" export instead uses the
# display names "LICENSE STATUS" etc. — a different schema, deliberately
# avoided here.)
#
#   bash fetch-full.sh
#   bxp-cli --config full.json
#
# Re-running is cheap: an already-downloaded full/chicago_licenses.csv is reused.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_DIR="$SCRIPT_DIR/full"
COLS="legal_name,doing_business_as_name,license_description,application_type,license_status,zip_code,city,state,application_created_date,license_start_date,expiration_date"
URL="https://data.cityofchicago.org/resource/r5kz-chrr.csv?\$select=${COLS}&\$order=:id&\$limit=2000000"
CSV="$FULL_DIR/chicago_licenses.csv"

mkdir -p "$FULL_DIR"

if [ -f "$CSV" ]; then
    echo "already downloaded: $CSV ($(du -h "$CSV" | cut -f1))"
    exit 0
fi

echo "downloading the full license register (~1.2M rows) from Socrata …"
if ! curl -fSL --retry 3 -o "$CSV" "$URL"; then
    echo "download failed" >&2
    rm -f "$CSV"
    exit 1
fi

rows=$(wc -l < "$CSV")
echo "ready: $CSV ($(du -h "$CSV" | cut -f1), $rows rows)"
