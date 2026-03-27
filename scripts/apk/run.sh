#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Ian Spray

CACHE_DIR="${CACHE_DIR:-/build/cache}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
PACKAGES_DIR="${PACKAGES_DIR:-/build/packages}"
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

mkdir -p "$PACKAGES_DIR"
mkdir -p "$OUTPUT_DIR/apk"

if [ "$(id -u)" = "0" ]; then
    exec su build -c "ABUILD_KEYS=$ABUILD_KEYS PACKAGES_DIR=$PACKAGES_DIR OUTPUT_DIR=$OUTPUT_DIR CACHE_DIR=$CACHE_DIR /build/scripts/apk/run.sh"
fi

export ABUILD_NOCOLOR=1
export ABUILD_NOLOG=1
export PACKAGER_PRIVKEY="$ABUILD_KEYS/abuild.rsa"

echo "PACKAGER_PRIVKEY=$ABUILD_KEYS/abuild.rsa" > ~/.abuild/abuild.conf
echo 'CHOST="aarch64-alpine-linux-musl"' >> ~/.abuild/abuild.conf

echo "=== Updating Alpine package index ==="
apk update

for pkg in "$PACKAGES_DIR"/*/; do
    pkgname=$(basename "$pkg")
    pkgdir="$pkg"
    
    if [ -d "$pkgdir" ] && [ -f "$pkgdir/APKBUILD" ]; then
        echo "Building $pkgname APK..."
        cd "$pkgdir"
        abuild 2>&1 || true
    fi
done

for apk in "$PACKAGES_DIR"/*/*.apk; do
    if [ -f "$apk" ]; then
        cp "$apk" "$OUTPUT_DIR/apk/"
        echo "Copied: $apk"
    fi
done

echo "=== APK build complete ==="
