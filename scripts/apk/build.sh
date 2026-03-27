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
        
        wget -q "https://github.com/rdelaage/keychain/archive/refs/tags/v2.8.5.tar.gz" -O keychain-2.8.5.tar.gz
        
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

        abuild checksum
    fi
}

build_apk() {
    local pkgname="$1"
    local pkgdir="$PACKAGES_DIR/$pkgname"
    
    if [ -d "$pkgdir" ]; then
        cd "$pkgdir"
        if [ -f "APKBUILD" ]; then
            echo "Building $pkgname APK..."
            abuild -r
            cp "$pkgdir"/packages/aarch64/*.apk "$OUTPUT_DIR/apk/" 2>/dev/null || true
        fi
    fi
}

if [ "$(id -u)" = "0" ]; then
    mkdir -p /build/.abuild
    chown -R build:build /build

    if [ ! -f /build/.abuild/abuild.rsa ]; then
        echo "=== Generating APK signing keys ==="
        ssh-keygen -t rsa -b 4096 -m PEM -f /build/.abuild/abuild.rsa -N "" -C "build@alpian"
    fi
    cp /build/.abuild/abuild.rsa.pub /etc/apk/keys/

    exec su - build -c "PACKAGES_DIR=$PACKAGES_DIR OUTPUT_DIR=$OUTPUT_DIR CACHE_DIR=$CACHE_DIR /build/scripts/apk/build.sh"
fi

export ABUILD_NOCOLOR=1
mkdir -p ~/.abuild

if [ ! -f ~/.abuild/abuild.rsa ]; then
    echo "=== Generating APK signing keys ==="
    ssh-keygen -t rsa -b 4096 -m PEM -f ~/.abuild/abuild.rsa -N "" -C "build@alpian"
fi

echo "PACKAGER_PRIVKEY=$HOME/.abuild/abuild.rsa" > ~/.abuild/abuild.conf
echo 'CHOST="aarch64-alpine-linux-musl"' >> ~/.abuild/abuild.conf

setup_alpine_sdk

for pkg in "$PACKAGES_DIR"/*/; do
    pkgname=$(basename "$pkg")
    build_apk "$pkgname"
done

echo "=== APK build complete ==="
