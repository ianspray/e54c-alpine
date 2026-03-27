#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Ian Spray

CACHE_DIR="${CACHE_DIR:-/build/cache}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
PACKAGES_DIR="${PACKAGES_DIR:-/build/packages}"

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

setup_alpine_sdk() {
    if [ ! -d "$PACKAGES_DIR"/keychain ]; then
        mkdir -p "$PACKAGES_DIR"/keychain
        cd "$PACKAGES_DIR"/keychain
        
        cat > APKBUILD << 'APKBUILD_EOF'
pkgname=keychain
pkgver=2.8.5
pkgrel=0
pkgdesc="SSH and GPG agent"
url="https://github.com/rdelaage/keychain"
license="GPL2"
arch="aarch64"
source="keychain-$pkgver.tar.gz::https://github.com/rdelaage/keychain/archive/refs/tags/v$pkgver.tar.gz"
depends="openssl"

build() {
    ./configure --prefix=/usr --sysconfdir=/etc
    make
}

package() {
    make DESTDIR="$pkgdir" install
}
APKBUILD_EOF
        
        wget -q "https://github.com/rdelaage/keychain/archive/refs/tags/v2.8.5.tar.gz" -O keychain-2.8.5.tar.gz
    fi
}

build_apk() {
    local pkgname="$1"
    local pkgdir="$PACKAGES_DIR/$pkgname"
    
    if [ -d "$pkgdir" ]; then
        cd "$pkgdir"
        if [ -f "APKBUILD" ]; then
            echo "Building $pkgname APK..."
            if [ "$(id -u)" = "0" ]; then
                su - build -c "cd $pkgdir && abuild rootbld" || true
            else
                abuild rootbld || true
            fi
            cp "$pkgdir"/packages/aarch64/*.apk "$OUTPUT_DIR/apk/" 2>/dev/null || true
        fi
    fi
}

setup_alpine_sdk

export ABUILD_NOCOLOR=1
mkdir -p /build/.abuild
chown -R build:build /build 2>/dev/null || true

if [ ! -f /build/.abuild/abuild.rsa ]; then
    echo "=== Generating APK signing keys ==="
    ssh-keygen -t rsa -b 4096 -m PEM -f /build/.abuild/abuild.rsa -N "" -C "build@alpian"
    cp /build/.abuild/abuild.rsa.pub /etc/apk/keys/
    chown -R build:build /build/.abuild
fi

echo "PACKAGER_PRIVKEY=/build/.abuild/abuild.rsa" > /build/.abuild/abuild.conf
echo 'CHOST="aarch64-alpine-linux-musl"' >> /build/.abuild/abuild.conf

if [ "$PACKAGES_DIR" != "/" ]; then
    for pkg in "$PACKAGES_DIR"/*/; do
        pkgname=$(basename "$pkg")
        build_apk "$pkgname"
    done
fi

echo "=== APK build complete ==="