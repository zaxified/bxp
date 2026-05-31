#!/usr/bin/env bash
# Fetch the FULL set of ADT sample messages from Microsoft's open-source
# FHIR-Converter (MIT) and concatenate them into one HL7 feed. These are real,
# published HL7 v2 sample messages from a project that documents the
# HL7-v2→FHIR conversion problem. The committed sample.hl7 is a 5-message slice
# (distinct patients); this pulls every ADT-*.hl7 (~57 messages — note many
# share the same example patient, as real feeds repeat patients across events).
#
#   bash fetch-full.sh
#   bxp-cli --config full.json   # one roster row per PID segment in the feed
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_DIR="$SCRIPT_DIR/full"
FEED="$FULL_DIR/feed.hl7"
API="https://api.github.com/repos/microsoft/FHIR-Converter/contents/data/SampleData/Hl7v2"
RAW="https://raw.githubusercontent.com/microsoft/FHIR-Converter/main/data/SampleData/Hl7v2"
mkdir -p "$FULL_DIR"
if [ -f "$FEED" ]; then echo "already built: $FEED"; exit 0; fi
echo "listing ADT sample messages …"
names="$(curl -fsSL --retry 3 "$API" | grep -oE '"name": "ADT[^"]*\.hl7"' | sed -E 's/"name": "(.*)"/\1/')"
[ -z "$names" ] && { echo "could not list sample messages" >&2; exit 1; }
: > "$FEED.tmp"
n=0
while IFS= read -r name; do
  [ -z "$name" ] && continue
  if curl -fsSL --retry 3 "$RAW/$(printf '%s' "$name" | sed 's/ /%20/g')" | tr -d '\r' >> "$FEED.tmp"; then
    printf '\n' >> "$FEED.tmp"; n=$((n+1))
  fi
done <<< "$names"
mv "$FEED.tmp" "$FEED"
echo "ready: $FEED ($n messages, $(grep -c '^PID' "$FEED") PID segments)"
