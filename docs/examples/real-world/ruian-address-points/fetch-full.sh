#!/usr/bin/env bash
# Fetch the FULL Czech state address register (RÚIAN OB_ADR) for the scale
# demonstration: one ~63 MB deflate archive holding 6,258 per-municipality
# Windows-1250 CSVs (354 MB unpacked, ~3.02M address rows). The committed
# sample.zip is a 5-municipality slice so the example stays small.
#
# ČÚZK publishes the exchange format behind a form
# (https://vdp.cuzk.cz/vdp/ruian/vymennyformat), but the generated archives sit
# at a stable path dated to a month end:
#
#   https://vdp.cuzk.gov.cz/vymenny_format/csv/<YYYYMMDD>_OB_ADR_csv.zip
#
# The current month's file only appears once that month has closed, so this
# script probes month ends backwards from today and takes the newest that
# resolves, rather than hard-coding a date that rots.
#
# STAGING LIVES OUTSIDE THE REPO. Unlike its single-file siblings, this run
# explodes into 6,258 intermediate CSVs plus the combined output. Dropping that
# into the working tree makes editors and SCM watchers churn over thousands of
# new entries, so the payload is staged in a temp dir and `./full` is left as a
# symlink pointing at it — `data_dir: "full"` in full.json keeps working, while
# not one of those files is inside the workspace. Override the location with
# BXP_RUIAN_WORK=/some/dir.
#
#   bash fetch-full.sh
#   bxp-cli --config full.json
#
# Re-running is cheap: an already-downloaded archive is reused.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINK="$SCRIPT_DIR/full"
WORK="${BXP_RUIAN_WORK:-${TMPDIR:-/tmp}/bxp-ruian-full}"
BASE_URL="https://vdp.cuzk.gov.cz/vymenny_format/csv"
MONTHS_BACK=12

mkdir -p "$WORK"

# Point ./full at the staging dir. A pre-existing real directory (an older
# in-tree pull) is migrated rather than silently shadowed.
if [ -L "$LINK" ]; then
    :
elif [ -d "$LINK" ]; then
    echo "migrating existing $LINK into $WORK …"
    for f in "$LINK"/*; do
        [ -e "$f" ] || continue
        mv "$f" "$WORK/"
    done
    rmdir "$LINK" || {
        echo "could not empty $LINK — move its contents to $WORK by hand" >&2
        exit 1
    }
fi

if [ ! -L "$LINK" ] && ! ln -s "$WORK" "$LINK" 2>/dev/null; then
    echo "warning: this platform would not create the ./full symlink;" >&2
    echo "         staging in the working tree instead — delete ./full after" >&2
    echo "         the run so your editor does not index 6,258 files." >&2
    mkdir -p "$LINK"
    WORK="$LINK"
fi

existing=$(ls "$WORK"/*_OB_ADR_csv.zip 2>/dev/null | head -1)
if [ -n "$existing" ]; then
    echo "already downloaded: $existing ($(du -h "$existing" | cut -f1))"
    echo "staging dir: $WORK (reachable as ./full)"
    exit 0
fi

# Last day of month <y>-<m>, Gregorian leap rule included.
days_in_month() {
    local y="$1" m="$2"
    case "$m" in
        1|3|5|7|8|10|12) echo 31 ;;
        4|6|9|11)        echo 30 ;;
        2)
            if [ $((y % 4)) -eq 0 ] && { [ $((y % 100)) -ne 0 ] || [ $((y % 400)) -eq 0 ]; }; then
                echo 29
            else
                echo 28
            fi
            ;;
    esac
}

year=$(date -u +%Y)
month=$((10#$(date -u +%m)))
stamp=""

for _ in $(seq 1 "$MONTHS_BACK"); do
    day=$(days_in_month "$year" "$month")
    candidate=$(printf '%04d%02d%02d' "$year" "$month" "$day")
    printf 'probing %s_OB_ADR_csv.zip … ' "$candidate"
    if curl -fsI --retry 2 "$BASE_URL/${candidate}_OB_ADR_csv.zip" >/dev/null 2>&1; then
        echo "found"
        stamp="$candidate"
        break
    fi
    echo "not published"
    month=$((month - 1))
    if [ "$month" -lt 1 ]; then
        month=12
        year=$((year - 1))
    fi
done

if [ -z "$stamp" ]; then
    echo "no OB_ADR export found in the last $MONTHS_BACK month ends — the publication" >&2
    echo "path may have moved; check $BASE_URL/" >&2
    exit 1
fi

ZIP="$WORK/${stamp}_OB_ADR_csv.zip"
echo "downloading the full address register (~63 MB, 6,258 municipalities) …"
if ! curl -fSL --retry 3 -o "$ZIP" "$BASE_URL/${stamp}_OB_ADR_csv.zip"; then
    echo "download failed" >&2
    rm -f "$ZIP"
    exit 1
fi

echo "ready: $ZIP ($(du -h "$ZIP" | cut -f1)) — bxp unpacks it in-process, no unzip needed"
echo "staging dir: $WORK (reachable as ./full)"
