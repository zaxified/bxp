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

# Regenerate the shipped readmes from the single source before packaging, so the
# bundled readme.md is never stale relative to resources/readme.src.md.
bash "$SCRIPT_DIR/gen-readme.sh"

# ─── Shared helpers ─────────────────────────────────────────────────────

build_companions() {
    local target=$1
    echo "  Cross-compiling bxp-cli + bxp-mcp for $target..."
    (cd "$MONO_ROOT/bxp-cli" && zig build -Dtarget="$target" -Doptimize=ReleaseSmall)
    (cd "$MONO_ROOT/bxp-mcp" && zig build -Dtarget="$target" -Doptimize=ReleaseSmall)
}

# Build the FFI bridge for a given target. Since the v0.3.0 proxy flip it is
# the GUI's single backend on every platform: stateless ops (config/expr
# validation, docs, templates, eval-batch) run in-process via bridge_inspect /
# bridge_eval_*, and bxp-cli runs are proxied through bridge_run(_streaming)
# (the latter sidesteps sdk#1727 pipe truncation on Windows). The library is
# mandatory — a missing probe is a fatal startup error on all hosts.
build_bridge() {
    local target=$1
    echo "  Cross-compiling bxp-gui-bridge for $target..."
    (cd "$MONO_ROOT/bxp-gui-bridge" && \
        zig build -Dtarget="$target" -Doptimize=ReleaseSmall)
}

restore_native_companions() {
    echo "  Restoring native bxp-cli + bxp-mcp + bxp-gui-bridge..."
    (cd "$MONO_ROOT/bxp-cli" && zig build)
    (cd "$MONO_ROOT/bxp-mcp" && zig build)
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
    # MCP server — sibling to bxp-cli so its bxp_simulate tool can spawn it.
    cp "$MONO_ROOT/bxp-mcp/zig-out/bin/bxp-mcp" "$appdir/bxp-mcp"
    # Starter templates — GUI-only installs lack the console archive, so
    # ship the examples next to the binaries; findExamplesSource() picks
    # them up for the open-dialog "create examples" action.
    cp "$MONO_ROOT/resources/console/bxp-cli.examples.json" \
       "$appdir/bxp-cli.examples.json"
    # FFI bridge — hosts in-process expr eval. Sibling to bxp-gui so
    # findBridgeLibrary() picks it up.
    cp "$MONO_ROOT/bxp-gui-bridge/zig-out/lib/libbxp-gui-bridge.so" \
       "$appdir/libbxp-gui-bridge.so"

    _build_appimage "$appdir" "$stage"

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
    mkdir -p "$appdir/usr/bin" "$appdir/usr/lib"

    # Layout per AppImage convention.
    cp -R "$appdir_src"/* "$appdir/usr/bin/"
    cp "$GUI_ROOT/linux/bxp-gui.png"                    "$appdir/bxp-gui.png"
    cp "$MONO_ROOT/resources/desktop/bxp-gui.desktop"   "$appdir/bxp-gui.desktop"

    # Ship the full hicolor icon tree inside the AppImage so the first-run
    # desktop-integration logic in bxp-gui can copy all sizes into
    # ~/.local/share/icons/hicolor/ — no sudo, user-owned destinations only.
    for size in 16 32 48 64 128 256 512 1024; do
        local src="$GUI_ROOT/linux/icons/hicolor/${size}x${size}/apps/bxp-gui.png"
        local dst="$appdir/usr/share/icons/hicolor/${size}x${size}/apps/bxp-gui.png"
        if [ -f "$src" ]; then
            mkdir -p "$(dirname "$dst")"
            cp "$src" "$dst"
        fi
    done

    # AppRun: cd into usr/bin and exec the binary.
    cat > "$appdir/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/bin/lib:$LD_LIBRARY_PATH"
exec "$HERE/usr/bin/bxp-gui" "$@"
EOF
    chmod +x "$appdir/AppRun"

    local out="$OUTDIR/bxp-desktop-linux-x86_64.AppImage"
    ARCH=x86_64 "$tool" --no-appstream "$appdir" "$out" >/dev/null
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
    # MCP server — sibling to bxp-cli so its bxp_simulate tool can spawn it.
    cp "$MONO_ROOT/bxp-mcp/zig-out/bin/bxp-mcp.exe" "$appdir/bxp-mcp.exe"
    # Starter templates for GUI-only installs (see Linux note above).
    cp "$MONO_ROOT/resources/console/bxp-cli.examples.json" \
       "$appdir/bxp-cli.examples.json"
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
    echo "  → $OUTDIR/bxp-desktop-windows-x86_64.exe"

    rm -rf "$stage"
    restore_native_companions
}

# ─── macOS branch ───────────────────────────────────────────────────────

build_macos() {
    echo "Building bxp-desktop ${VERSION} for macos-arm64..."
    build_companions "aarch64-macos"
    build_bridge "aarch64-macos"

    (cd "$GUI_ROOT" && flutter build macos --release)
    local app="$GUI_ROOT/build/macos/Build/Products/Release/bxp-gui.app"

    # Companions inside the .app bundle's MacOS dir alongside the main
    # binary, so BxpProcessClient.findBin finds them as siblings.
    cp "$MONO_ROOT/bxp-cli/zig-out/bin/bxp-cli" "$app/Contents/MacOS/bxp-cli"
    # MCP server — sibling to bxp-cli so its bxp_simulate tool can spawn it.
    cp "$MONO_ROOT/bxp-mcp/zig-out/bin/bxp-mcp" "$app/Contents/MacOS/bxp-mcp"
    # Starter templates for GUI-only installs (see Linux note above).
    cp "$MONO_ROOT/resources/console/bxp-cli.examples.json" \
       "$app/Contents/MacOS/bxp-cli.examples.json"
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
    local out="$OUTDIR/bxp-desktop-macos-arm64.dmg"
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
ls -lh "$OUTDIR"/bxp-desktop-* 2>/dev/null || echo "  (no artifacts produced)"
