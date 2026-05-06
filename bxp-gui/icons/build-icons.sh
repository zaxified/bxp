#!/usr/bin/env bash
# Regenerate platform icons from icons/bxp-gui.svg (master, version-controlled).
# Run only when the master SVG changes — outputs are committed so CI does
# not need an SVG-rendering toolchain.
#
# Requirements:
#   - ImageMagick (`convert`) — used for SVG → PNG and PNG → ICO.
#     Fallbacks honored: ImageMagick 7's `magick` binary if `convert` is
#     missing.
#
# Outputs:
#   linux/bxp-gui.png                                           (256×256)
#   linux/icons/hicolor/<size>x<size>/apps/bxp-gui.png          (8 sizes)
#   windows/runner/resources/app_icon.ico                       (multi-size)
#   macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_<size>.png
#                                                               (7 sizes)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUI_ROOT="$(dirname "$SCRIPT_DIR")"
SVG="$SCRIPT_DIR/bxp-gui.svg"

if [ ! -f "$SVG" ]; then
    echo "error: master not found at $SVG" >&2
    exit 1
fi

# Pick the available ImageMagick CLI.
if command -v magick >/dev/null 2>&1; then
    IM=(magick)
elif command -v convert >/dev/null 2>&1; then
    IM=(convert)
else
    echo "error: ImageMagick (convert/magick) required" >&2
    exit 1
fi

# render <size> <out>
render() {
    local size=$1
    local out=$2
    mkdir -p "$(dirname "$out")"
    "${IM[@]}" -background none -density "$size" "$SVG" \
        -resize "${size}x${size}" "$out"
}

echo "Rendering Linux icons..."
render 256 "$GUI_ROOT/linux/bxp-gui.png"
for size in 16 32 48 64 128 256 512 1024; do
    render "$size" \
        "$GUI_ROOT/linux/icons/hicolor/${size}x${size}/apps/bxp-gui.png"
done

echo "Rendering macOS appiconset..."
ICONSET="$GUI_ROOT/macos/Runner/Assets.xcassets/AppIcon.appiconset"
for size in 16 32 64 128 256 512 1024; do
    render "$size" "$ICONSET/app_icon_${size}.png"
done

echo "Rendering Windows .ico..."
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
for size in 16 32 48 64 128 256; do
    render "$size" "$TMPDIR/icon-${size}.png"
done
"${IM[@]}" "$TMPDIR"/icon-*.png \
    "$GUI_ROOT/windows/runner/resources/app_icon.ico"

echo "Done. Outputs:"
echo "  $GUI_ROOT/linux/bxp-gui.png"
echo "  $GUI_ROOT/linux/icons/hicolor/.../apps/bxp-gui.png  (8 sizes)"
echo "  $ICONSET/app_icon_*.png  (7 sizes)"
echo "  $GUI_ROOT/windows/runner/resources/app_icon.ico"
