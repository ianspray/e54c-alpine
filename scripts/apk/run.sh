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

if [ "$(id -u)" = "0" ]; then
    exec su build -c "ABUILD_KEYS=$ABUILD_KEYS APORTS_DIR=$APORTS_DIR OUTPUT_DIR=$OUTPUT_DIR CACHE_DIR=$CACHE_DIR /build/scripts/apk/run.sh"
fi

export ABUILD_NOCOLOR=1
export ABUILD_NOLOG=1
export PACKAGER_PRIVKEY="$ABUILD_KEYS/abuild.rsa"

echo "PACKAGER_PRIVKEY=$ABUILD_KEYS/abuild.rsa" > ~/.abuild/abuild.conf
echo 'CHOST="aarch64-alpine-linux-musl"' >> ~/.abuild/abuild.conf

echo "=== Updating Alpine package index ==="
apk update

echo "=== Building packages from $APORTS_DIR ==="
for apkbuild in "$APORTS_DIR"/*/*/APKBUILD; do
    if [ -f "$apkbuild" ]; then
        pkgdir="$(dirname "$apkbuild")"
        pkgname="$(basename "$pkgdir")"
        echo "Building $pkgname..."
        cd "$pkgdir"
        abuild 2>&1 || echo "Failed to build $pkgname"
    fi
done

for apk in "$HOME"/packages/aarch64/*.apk; do
    if [ -f "$apk" ]; then
        cp "$apk" "$OUTPUT_DIR/apk/"
        echo "Copied: $apk"
    fi
done

echo "=== APK build complete ==="
