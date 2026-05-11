#!/usr/bin/env bash
# Build the bxp-desktop release bundle for the current host OS.
#
# Flutter desktop has no cross-compile, so each platform must be built
# on its native host. This script runs the host's branch only and skips
# the others; GitHub Actions wires three runners (ubuntu, windows,
# macos) to produce the full matrix in parallel.
#
# Usage (from any directory):
#   bash scripts/release-02-desktop.sh           — uses latest git tag as version
#   bash scripts/release-02-desktop.sh v0.2.0    — uses the given version string
#
# Output: releases/desktop/bxp-desktop-<version>-<platform>.<ext>
#   Linux   — .tar.gz, .AppImage, .deb
#   Windows — -setup.exe (NSIS installer)
#   macOS   — .dmg

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$SCRIPT_DIR")"
GUI_ROOT="$MONO_ROOT/bxp-gui"
OUTDIR="$MONO_ROOT/releases/desktop"

VERSION=${1:-$(git -C "$MONO_ROOT" describe --tags --abbrev=0 2>/dev/null || echo "dev")}
VERSION_BARE="${VERSION#v}"

mkdir -p "$OUTDIR"

# ─── Shared helpers ─────────────────────────────────────────────────────

build_companions() {
    local target=$1
    echo "  Cross-compiling bxp-cli + bxp-fmt for $target..."
    (cd "$MONO_ROOT/bxp-cli" && zig build -Dtarget="$target" -Doptimize=ReleaseSmall)
    (cd "$MONO_ROOT/bxp-fmt" && zig build -Dtarget="$target" -Doptimize=ReleaseSmall)
}

# Build the FFI bridge for a given target. Windows: load-bearing for the
# subprocess proxy (sdk#1727 pipe truncation workaround). Linux/macOS:
# hosts the in-process expression evaluator family (bridge_eval_expr /
# bridge_eval_expr_trace) so per-keystroke expr validation runs sub-ms
# instead of paying a ~50 ms subprocess spawn. Absence on Linux/macOS is
# non-fatal — BxpProcessClient falls back to subprocess.
build_bridge() {
    local target=$1
    echo "  Cross-compiling bxp-gui-bridge for $target..."
    (cd "$MONO_ROOT/bxp-gui-bridge" && \
        zig build -Dtarget="$target" -Doptimize=ReleaseSmall)
}

restore_native_companions() {
    echo "  Restoring native bxp-cli + bxp-fmt + bxp-gui-bridge..."
    (cd "$MONO_ROOT/bxp-cli" && zig build)
    (cd "$MONO_ROOT/bxp-fmt" && zig build)
    (cd "$MONO_ROOT/bxp-gui-bridge" && zig build)
}

# ─── Linux branch ───────────────────────────────────────────────────────

build_linux() {
    echo "Building bxp-desktop ${VERSION} for linux-x86_64..."
    build_companions "x86_64-linux-musl"
    build_bridge "x86_64-linux-gnu"

    (cd "$GUI_ROOT" && flutter build linux --release)
    local bundle="$GUI_ROOT/build/linux/x64/release/bundle"

    local stage
    stage=$(mktemp -d)
    local appdir="$stage/bxp-desktop"
    mkdir -p "$appdir"

    # Flutter bundle — binary + assets + shared libs.
    cp -R "$bundle"/* "$appdir/"

    # Companion binaries (overwrite the dev symlink the linux/CMake hook
    # would have placed when run via `flutter run`).
    cp "$MONO_ROOT/bxp-cli/zig-out/bin/bxp-cli" "$appdir/bxp-cli"
    cp "$MONO_ROOT/bxp-fmt/zig-out/bin/bxp-fmt" "$appdir/bxp-fmt"
    # FFI bridge — hosts in-process expr eval. Sibling to bxp-gui so
    # findBridgeLibrary() picks it up.
    cp "$MONO_ROOT/bxp-gui-bridge/zig-out/lib/libbxp-gui-bridge.so" \
       "$appdir/libbxp-gui-bridge.so"

    # Linux-specific extras. icons/ ships all four variants so users can
    # repoint their shortcut's Icon= line (.desktop) at a different one.
    mkdir -p "$appdir/icons"
    cp "$MONO_ROOT/resources/icons"/*.png "$appdir/icons/"
    cp "$MONO_ROOT/resources/desktop/bxp-gui.desktop" "$appdir/bxp-gui.desktop"
    cp "$MONO_ROOT/resources/desktop/readme.md"       "$appdir/readme.md"

    # ── (a) plain tarball ──
    local tgz="$OUTDIR/bxp-desktop-${VERSION}-linux-x86_64.tar.gz"
    tar -czf "$tgz" -C "$stage" bxp-desktop
    echo "  → $tgz"

    # ── (b) AppImage ──
    _build_appimage "$appdir" "$stage"

    # ── (c) .deb ──
    _build_deb "$appdir" "$stage"

    rm -rf "$stage"
    restore_native_companions
}

_appimagetool() {
    # Use a cached download so we don't depend on it being preinstalled.
    # All status messages go to stderr so callers can capture stdout as
    # the resolved path: `tool=$(_appimagetool)`.
    local cache="$HOME/.cache/bxp-build"
    local bin="$cache/appimagetool-x86_64.AppImage"
    if [ ! -x "$bin" ]; then
        mkdir -p "$cache"
        echo "  Downloading appimagetool to $bin..." >&2
        curl -fsSL -o "$bin" \
            "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage" >&2
        chmod +x "$bin"
    fi
    echo "$bin"
}

_build_appimage() {
    local appdir_src=$1
    local stage=$2
    local tool
    tool=$(_appimagetool) || return 1

    local appdir="$stage/AppDir"
    mkdir -p "$appdir/usr/bin" "$appdir/usr/lib" "$appdir/usr/share/icons/hicolor/256x256/apps"

    # Layout per AppImage convention.
    cp -R "$appdir_src"/* "$appdir/usr/bin/"
    cp "$GUI_ROOT/linux/bxp-gui.png"                    "$appdir/bxp-gui.png"
    cp "$GUI_ROOT/linux/bxp-gui.png"                    \
        "$appdir/usr/share/icons/hicolor/256x256/apps/bxp-gui.png"
    cp "$MONO_ROOT/resources/desktop/bxp-gui.desktop"   "$appdir/bxp-gui.desktop"

    # AppRun: cd into usr/bin and exec the binary.
    cat > "$appdir/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/bin/lib:$LD_LIBRARY_PATH"
exec "$HERE/usr/bin/bxp-gui" "$@"
EOF
    chmod +x "$appdir/AppRun"

    local out="$OUTDIR/bxp-desktop-${VERSION}-linux-x86_64.AppImage"
    ARCH=x86_64 "$tool" --no-appstream "$appdir" "$out" >/dev/null
    echo "  → $out"
}

_build_deb() {
    local appdir_src=$1
    local stage=$2
    local pkg="$stage/deb/bxp-gui_${VERSION_BARE}_amd64"
    mkdir -p "$pkg/DEBIAN" "$pkg/opt/bxp-gui" "$pkg/usr/bin" \
             "$pkg/usr/share/applications"

    # Payload under /opt to avoid clashing with system FHS dirs.
    cp -R "$appdir_src"/* "$pkg/opt/bxp-gui/"

    # /usr/bin shim so users can run `bxp-gui` from the terminal.
    ln -sf /opt/bxp-gui/bxp-gui "$pkg/usr/bin/bxp-gui"

    # Desktop entry + multi-size hicolor icons.
    cp "$MONO_ROOT/resources/desktop/bxp-gui.desktop" \
       "$pkg/usr/share/applications/bxp-gui.desktop"
    for size in 16 32 48 64 128 256 512 1024; do
        local src="$GUI_ROOT/linux/icons/hicolor/${size}x${size}/apps/bxp-gui.png"
        local dst="$pkg/usr/share/icons/hicolor/${size}x${size}/apps/bxp-gui.png"
        if [ -f "$src" ]; then
            mkdir -p "$(dirname "$dst")"
            cp "$src" "$dst"
        fi
    done

    # DEBIAN metadata — substitute version into the templated control file.
    sed "s/^Version: .*/Version: $VERSION_BARE/" \
        "$GUI_ROOT/installer/debian/control" > "$pkg/DEBIAN/control"
    cp "$GUI_ROOT/installer/debian/postinst" "$pkg/DEBIAN/postinst"
    cp "$GUI_ROOT/installer/debian/prerm"    "$pkg/DEBIAN/prerm"
    chmod 0755 "$pkg/DEBIAN/postinst" "$pkg/DEBIAN/prerm"

    local out="$OUTDIR/bxp-desktop-${VERSION}-linux-x86_64.deb"
    dpkg-deb --build --root-owner-group "$pkg" "$out" >/dev/null
    echo "  → $out"
}

# ─── Windows branch ─────────────────────────────────────────────────────

build_windows() {
    echo "Building bxp-desktop ${VERSION} for windows-x86_64..."
    build_companions "x86_64-windows"
    build_bridge "x86_64-windows"

    (cd "$GUI_ROOT" && flutter build windows --release)
    local bundle="$GUI_ROOT/build/windows/x64/runner/Release"

    local stage
    stage=$(mktemp -d)
    local appdir="$stage/bxp-desktop"
    mkdir -p "$appdir"
    cp -R "$bundle"/* "$appdir/"
    cp "$MONO_ROOT/bxp-cli/zig-out/bin/bxp-cli.exe" "$appdir/bxp-cli.exe"
    cp "$MONO_ROOT/bxp-fmt/zig-out/bin/bxp-fmt.exe" "$appdir/bxp-fmt.exe"
    # FFI bridge DLL — sidesteps dart:io's Windows pipe truncation
    # (sdk#1727) on `--docs`, `--config`, and `--trace` reads. Found by
    # findBridgeLibrary() as a sibling of bxp-gui.exe.
    cp "$MONO_ROOT/bxp-gui-bridge/zig-out/bin/bxp-gui-bridge.dll" \
       "$appdir/bxp-gui-bridge.dll"
    cp "$MONO_ROOT/resources/desktop/readme.md"     "$appdir/readme.md"
    # icons/ ships all four variants for shortcut-icon swap.
    mkdir -p "$appdir/icons"
    cp "$MONO_ROOT/resources/icons"/*.png "$appdir/icons/"

    if ! command -v makensis >/dev/null 2>&1; then
        echo "  ! makensis not found — Windows installer is the only release artifact, refusing to skip" >&2
        echo "    install NSIS and ensure 'makensis' is on PATH (e.g. C:\\Program Files (x86)\\NSIS\\Bin)" >&2
        exit 1
    fi
    makensis \
        -DAPPVERSION="$VERSION_BARE" \
        -DVERSIONTAG="$VERSION" \
        -DSTAGEDIR="$appdir" \
        -DOUTDIR="$OUTDIR" \
        "$GUI_ROOT/installer/bxp-desktop.nsi" >/dev/null
    echo "  → $OUTDIR/bxp-desktop-${VERSION}-windows-x86_64-setup.exe"

    rm -rf "$stage"
    restore_native_companions
}

# ─── macOS branch ───────────────────────────────────────────────────────

build_macos() {
    echo "Building bxp-desktop ${VERSION} for macos-aarch64..."
    build_companions "aarch64-macos"
    build_bridge "aarch64-macos"

    (cd "$GUI_ROOT" && flutter build macos --release)
    local app="$GUI_ROOT/build/macos/Build/Products/Release/bxp-gui.app"

    # Companions inside the .app bundle's MacOS dir alongside the main
    # binary, so BxpProcessClient.findBin finds them as siblings.
    cp "$MONO_ROOT/bxp-cli/zig-out/bin/bxp-cli" "$app/Contents/MacOS/bxp-cli"
    cp "$MONO_ROOT/bxp-fmt/zig-out/bin/bxp-fmt" "$app/Contents/MacOS/bxp-fmt"
    # FFI bridge — hosts in-process expr eval. Sibling to bxp-gui so
    # findBridgeLibrary() picks it up via the same dev-tree probe order
    # as the Win/Linux paths.
    cp "$MONO_ROOT/bxp-gui-bridge/zig-out/lib/libbxp-gui-bridge.dylib" \
       "$app/Contents/MacOS/libbxp-gui-bridge.dylib"

    # Ad-hoc codesign — Gatekeeper still warns on first launch but the app
    # is otherwise loadable. Proper Developer ID signing is out of scope.
    # --deep applies the signature to all nested binaries including the
    # bridge .dylib, so we don't need a separate codesign pass.
    codesign --deep --force --sign - "$app"

    if ! command -v create-dmg >/dev/null 2>&1; then
        echo "  ! create-dmg not found — skipping DMG packaging"
        return 0
    fi
    local out="$OUTDIR/bxp-desktop-${VERSION}-macos-aarch64.dmg"
    create-dmg \
        --volname "BXP" \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "bxp-gui.app" 175 175 \
        --app-drop-link 425 175 \
        --no-internet-enable \
        "$out" "$app"
    echo "  → $out"
    restore_native_companions
}

# ─── Dispatch ───────────────────────────────────────────────────────────

case "$(uname -s)" in
    Linux)   build_linux ;;
    Darwin)  build_macos ;;
    MINGW*|MSYS*|CYGWIN*) build_windows ;;
    *)
        echo "Unsupported host OS: $(uname -s)" >&2
        exit 1
        ;;
esac

echo ""
echo "Done. Packages in releases/desktop/:"
ls -lh "$OUTDIR"/bxp-desktop-"${VERSION}"-* 2>/dev/null || echo "  (no artifacts produced)"
