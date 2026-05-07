#!/usr/bin/env bash
# Regenerate icon assets from resources/icons/*.svg.
#
# Produces:
#   1. resources/icons/<variant>.png — single 512px PNG per SVG variant.
#      release-02-desktop.sh bundles all four into the archive's `icons/`
#      directory so users can swap their shortcut/launcher icon to a
#      different variant after install.
#   2. Multi-size PNG/ICO sets for the PRIMARY variant at the paths
#      Flutter expects (so `flutter run -d linux` works in the dev tree
#      and `flutter build` embeds the right icon at compile time):
#        bxp-gui/linux/bxp-gui.png
#        bxp-gui/linux/icons/hicolor/<size>x<size>/apps/bxp-gui.png  (8 sizes)
#        bxp-gui/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png  (7 sizes)
#        bxp-gui/windows/runner/resources/app_icon.ico  (multi-size)
#
# Run when an SVG master changes. Outputs are committed to git so CI
# does not need an SVG-rendering toolchain.
#
# Requirements: ImageMagick (`magick` from IM7 or legacy `convert`).

set -e

PRIMARY="bxp-sand-80"
FLAT_PX=512

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUI_ROOT="$MONO_ROOT/bxp-gui"

if command -v magick >/dev/null 2>&1; then
    IM=(magick)
elif command -v convert >/dev/null 2>&1; then
    IM=(convert)
else
    echo "error: ImageMagick (magick/convert) required" >&2
    exit 1
fi

# render <svg> <size> <out>
render() {
    local svg=$1
    local size=$2
    local out=$3
    mkdir -p "$(dirname "$out")"
    "${IM[@]}" -background none -density "$size" "$svg" \
        -resize "${size}x${size}" "$out"
}

# 1. Flat per-variant PNG next to each SVG.
echo "Rendering flat ${FLAT_PX}px PNGs for all variants..."
for svg in "$SCRIPT_DIR"/*.svg; do
    [ -e "$svg" ] || continue
    out="${svg%.svg}.png"
    render "$svg" "$FLAT_PX" "$out"
    echo "  $(basename "$out")"
done

# 2. Multi-size sets for the primary variant on Flutter's expected paths.
SVG_PRIMARY="$SCRIPT_DIR/${PRIMARY}.svg"
if [ ! -f "$SVG_PRIMARY" ]; then
    echo "error: primary master not found at $SVG_PRIMARY" >&2
    exit 1
fi

echo ""
echo "Rendering primary (${PRIMARY}) into Flutter platform paths..."

echo "  Linux..."
render "$SVG_PRIMARY" 256 "$GUI_ROOT/linux/bxp-gui.png"
for size in 16 32 48 64 128 256 512 1024; do
    render "$SVG_PRIMARY" "$size" \
        "$GUI_ROOT/linux/icons/hicolor/${size}x${size}/apps/bxp-gui.png"
done

echo "  macOS appiconset..."
ICONSET="$GUI_ROOT/macos/Runner/Assets.xcassets/AppIcon.appiconset"
for size in 16 32 64 128 256 512 1024; do
    render "$SVG_PRIMARY" "$size" "$ICONSET/app_icon_${size}.png"
done

echo "  Windows .ico..."
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
for size in 16 32 48 64 128 256; do
    render "$SVG_PRIMARY" "$size" "$TMPDIR/icon-${size}.png"
done
"${IM[@]}" "$TMPDIR"/icon-*.png \
    "$GUI_ROOT/windows/runner/resources/app_icon.ico"

echo ""
echo "Done."
