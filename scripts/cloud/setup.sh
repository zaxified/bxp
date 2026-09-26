#!/usr/bin/env bash
# Setup script for Claude Code cloud sessions (claude.ai/code) on this repo:
# installs the pinned Zig toolchain the cloud image lacks. Paste it into the
# cloud environment's setup script field; this copy is the versioned original.
#
# Deliberately NOT installed: Flutter / Dart. GUI work and its tests stay on a
# local machine; scripts/test.sh skips test-04 and the json5_ast Dart tests
# cleanly when the SDKs are absent, so the rest of the suite runs as is.
#
# Network: the environment needs ziglang.org on top of the Trusted defaults
# (Custom access). Build fetch deps come from github.com, which is always
# reachable.
#
# Runs as root on Ubuntu, must exit 0 and finish within ~5 minutes for the
# result to be cached.
set -euo pipefail

ZIG_VERSION="0.16.0"   # keep in sync with .zigversion (the checksum belongs to it)
ZIG_SHA256="70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00"
ZIG_DIR="zig-x86_64-linux-${ZIG_VERSION}"
ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_DIR}.tar.xz"

if ! command -v zig >/dev/null 2>&1 || [[ "$(zig version)" != "$ZIG_VERSION" ]]; then
    tmp="$(mktemp -d)"
    curl -fsSL "$ZIG_URL" -o "$tmp/zig.tar.xz"
    echo "${ZIG_SHA256}  $tmp/zig.tar.xz" | sha256sum -c -
    tar -xJf "$tmp/zig.tar.xz" -C /opt
    ln -sf "/opt/${ZIG_DIR}/zig" /usr/local/bin/zig
    rm "$tmp/zig.tar.xz"
    rmdir "$tmp"
fi
zig version
