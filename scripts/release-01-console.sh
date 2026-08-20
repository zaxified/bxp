#!/usr/bin/env bash
# Build console release archives for Linux, Windows, and macOS.
#
# Usage (from any directory):
#   bash scripts/release-01-console.sh           — uses latest git tag as version
#   bash scripts/release-01-console.sh v0.2.0    — uses the given version string
#
# Also runs as part of `scripts/release.sh` (console + desktop wrapper).
#
# Output: releases/console/bxp-console-<version>-<platform>.(tar.gz|zip)
#         Archive contains bxp/ with: bxp-cli(.exe), bxp-mcp(.exe),
#         bxp-cli.examples.json, bxp-cli.json (trading212 sample),
#         sample.{csv,csvx,expected}. No readme: `bxp-cli --help` prints the
#         documentation links instead, pinned to this release.
#
# bxp-mcp (the MCP server) ships alongside bxp-cli so an agent (or a console
# user) can drive bxp's stateless surface — validate a config / expression,
# evaluate, list templates, read the docs — and run a full conversion via its
# bxp_simulate tool, which spawns bxp-cli from the same directory. The two
# binaries must stay co-located in the archive.

# enable all command debugs
#set -x

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$SCRIPT_DIR")"
OUTDIR="$MONO_ROOT/releases/console"

VERSION=${1:-$(git -C "$MONO_ROOT" describe --tags --abbrev=0 2>/dev/null || echo "dev")}

echo "Building bxp-console ${VERSION}"
mkdir -p "$OUTDIR"

build() {
    local target=$1   # zig target triple
    local name=$2     # output filename suffix
    local ext=$3      # binary extension ("" or ".exe")

    echo "  [$target]"
    (cd "$MONO_ROOT/bxp-cli" && zig build -Dtarget="$target" -Doptimize=ReleaseSmall)
    (cd "$MONO_ROOT/bxp-mcp" && zig build -Dtarget="$target" -Doptimize=ReleaseSmall)

    local bin="$MONO_ROOT/bxp-cli/zig-out/bin/bxp-cli${ext}"
    local mcpbin="$MONO_ROOT/bxp-mcp/zig-out/bin/bxp-mcp${ext}"
    local base="$OUTDIR/bxp-console-${VERSION}-${name}"
    local stage
    stage=$(mktemp -d)
    mkdir -p "$stage/bxp"
    cp "$bin"                                                          "$stage/bxp/bxp-cli${ext}"
    cp "$mcpbin"                                                       "$stage/bxp/bxp-mcp${ext}"
    cp "$MONO_ROOT/resources/console/bxp-cli.examples.json"            "$stage/bxp/bxp-cli.examples.json"
    cp "$MONO_ROOT/datasets/trading212_to_wealthfolio/sample.json"     "$stage/bxp/bxp-cli.json"
    cp "$MONO_ROOT/datasets/trading212_to_wealthfolio/sample.csv"      "$stage/bxp/sample.csv"
    cp "$MONO_ROOT/datasets/trading212_to_wealthfolio/sample.csvx"     "$stage/bxp/sample.csvx"
    cp "$MONO_ROOT/datasets/trading212_to_wealthfolio/sample.expected" "$stage/bxp/sample.expected"

    if [[ "$ext" == ".exe" ]]; then
        (cd "$stage" && zip -r "${base}.zip" bxp)
        echo "    → ${base}.zip"
    else
        tar -czf "${base}.tar.gz" -C "$stage" bxp
        echo "    → ${base}.tar.gz"
    fi
    rm -rf "$stage"
}

build "x86_64-linux-musl" "linux-x86_64"   ""
build "x86_64-windows"    "windows-x86_64" ".exe"
build "aarch64-macos"     "macos-aarch64"  ""

echo ""
echo "Done. Packages in releases/console/:"
ls -lh "$OUTDIR"/bxp-console-"${VERSION}"-*

# Restore native dev binaries — cross-compilation overwrites zig-out/.
echo ""
echo "Restoring native binaries..."
(cd "$MONO_ROOT/bxp-cli" && zig build)
(cd "$MONO_ROOT/bxp-mcp" && zig build)
