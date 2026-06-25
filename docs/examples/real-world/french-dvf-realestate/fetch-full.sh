#!/usr/bin/env bash
# Fetch the FULL French DVF (Demandes de valeurs foncières) 2024 dataset for
# the scale demonstration. The committed sample.csv is a 250-row slice; the
# real file is every property transaction registered in France in 2024
# (~4M rows). Source: DGFiP open data on data.gouv.fr (Licence Ouverte / CC-BY).
#
# The download lands in ./full/ (gitignored). Run it through the bundled scale
# config afterwards:
#
#   bash fetch-full.sh
#   bxp-cli --config full.json
#
# Re-running is cheap: an already-extracted full/valeursfoncieres-2024.txt is
# reused.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_DIR="$SCRIPT_DIR/full"
URL="https://static.data.gouv.fr/resources/demandes-de-valeurs-foncieres/20260405-002306/valeursfoncieres-2024.txt.zip"
ZIP="$FULL_DIR/valeursfoncieres-2024.txt.zip"
# The archive expands to a capitalised name.
TXT="$FULL_DIR/ValeursFoncieres-2024.txt"

mkdir -p "$FULL_DIR"

if [ -f "$TXT" ]; then
    echo "already extracted: $TXT ($(du -h "$TXT" | cut -f1))"
    exit 0
fi

echo "downloading $URL …"
if ! curl -fSL --retry 3 -o "$ZIP" "$URL"; then
    echo "download failed" >&2
    rm -f "$ZIP"
    exit 1
fi

echo "extracting …"
if ! unzip -o "$ZIP" -d "$FULL_DIR" >/dev/null; then
    echo "extract failed" >&2
    exit 1
fi
rm -f "$ZIP"

rows=$(wc -l < "$TXT")
echo "ready: $TXT ($(du -h "$TXT" | cut -f1), $rows rows)"
