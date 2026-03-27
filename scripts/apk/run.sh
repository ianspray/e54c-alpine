#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Ian Spray

CACHE_DIR="${CACHE_DIR:-/build/cache}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
APORTS_DIR="${APORTS_DIR:-/build/apk/aports}"
ABUILD_KEYS="${ABUILD_KEYS:-/build/.abuild}"

for board in rock5b rock5c rock5e rock3b rpi4 rpi5; do
    BOARD_CONF="/build/config/${board}.conf"
    if [ -f "$BOARD_CONF" ]; then
        . "$BOARD_CONF"
        break
    fi
done

ALPINE_VERSION="${ALPINE_VERSION:-3.23.3}"

echo "=== Building custom APK packages ==="

mkdir -p "$OUTPUT_DIR/apk"

chmod 700 "$ABUILD_KEYS"
chmod 600 "$ABUILD_KEYS/abuild.rsa"
chmod 644 "$ABUILD_KEYS/abuild.rsa.pub"

export ABUILD_NOCOLOR=1
export ABUILD_NOLOG=1
export PACKAGER_PRIVKEY="$ABUILD_KEYS/abuild.rsa"
export HOME=/home/build

mkdir -p "$HOME/packages"
chmod 755 "$HOME"

CURRENT_USER=$(whoami)
CURRENT_GROUP=$(id -gn)
addgroup "$CURRENT_GROUP" abuild 2>/dev/null || true

echo "=== Updating Alpine package index ==="
apk update

echo "=== Building packages from $APORTS_DIR ==="
for apkbuild in "$APORTS_DIR"/*/*/APKBUILD; do
    if [ -f "$apkbuild" ]; then
        pkgdir="$(dirname "$apkbuild")"
        pkgname="$(basename "$pkgdir")"
        echo "Building $pkgname..."
        cd "$pkgdir"
        abuild checksum 2>/dev/null || true
        abuild -r 2>&1 || echo "Failed to build $pkgname"
    fi
done

for apk in "$HOME"/packages/aarch64/*.apk; do
    if [ -f "$apk" ]; then
        cp "$apk" "$OUTPUT_DIR/apk/"
        echo "Copied: $apk"
    fi
done

echo "=== APK build complete ==="
