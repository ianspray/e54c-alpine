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

if ! id abuild >/dev/null 2>&1; then
    echo "=== Creating abuild user ==="
    adduser -D -s /bin/sh abuild
    addgroup abuild abuild
fi

ABUILD_HOME="$(getent passwd abuild | cut -d: -f6)"

cp "$ABUILD_KEYS/abuild.rsa.pub" /etc/apk/keys/ 2>/dev/null || true

chmod 700 "$ABUILD_KEYS"
chmod 600 "$ABUILD_KEYS/abuild.rsa"
chmod 644 "$ABUILD_KEYS/abuild.rsa.pub"

cp -r "$ABUILD_KEYS" "$ABUILD_HOME/.abuild"
chown -R abuild:abuild "$ABUILD_HOME/.abuild"

chmod 700 "$ABUILD_HOME/.abuild"
chmod 600 "$ABUILD_HOME/.abuild/abuild.rsa"
chmod 644 "$ABUILD_HOME/.abuild/abuild.rsa.pub"

export ABUILD_NOCOLOR=1
export ABUILD_NOLOG=1

echo "=== Updating Alpine package index ==="
apk update

echo "=== Building packages from $APORTS_DIR ==="
for apkbuild in "$APORTS_DIR"/*/*/APKBUILD; do
    if [ -f "$apkbuild" ]; then
        pkgdir="$(dirname "$apkbuild")"
        pkgname="$(basename "$pkgdir")"
        echo "Building $pkgname..."
        su-exec abuild sh -c "cd $pkgdir && abuild checksum 2>/dev/null || true"
        su-exec abuild sh -c "cd $pkgdir && abuild -r" 2>&1 || echo "Failed to build $pkgname"
    fi
done

for apk in "$ABUILD_HOME"/packages/aarch64/*.apk; do
    if [ -f "$apk" ]; then
        cp "$apk" "$OUTPUT_DIR/apk/"
        echo "Copied: $apk"
    fi
done

echo "=== APK build complete ==="
