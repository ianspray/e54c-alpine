#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Ian Spray
set -e

CACHE_DIR="${CACHE_DIR:-/build/cache}"
BOARD="${BOARD:-rock5b}"

BOARD_CONF="/build/config/${BOARD}.conf"
if [ -f "$BOARD_CONF" ]; then
    . "$BOARD_CONF"
fi

ALPINE_VERSION="${ALPINE_VERSION:-3.23.3}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/radxa/kernel}"
KERNEL_BRANCH="${KERNEL_BRANCH:-linux-6.1-stan-rkr5.1}"

echo "=== Fetching assets for board: $BOARD ==="

KERNEL_SHARED_DIR="$CACHE_DIR/kernel/shared"
UBOOT_SHARED_DIR="$CACHE_DIR/uboot/shared"

fetch_kernel() {
    case "$BOARD" in
        rock5b|rock5c|rock5e|rock3b)
            kernel_name="linux-rockchip"
            echo "Fetching Rockchip kernel $KERNEL_REPO"
            if [ ! -d "$KERNEL_SHARED_DIR/$kernel_name" ]; then
                mkdir -p "$KERNEL_SHARED_DIR"
                git clone --depth 1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_SHARED_DIR/$kernel_name"
            fi
            mkdir -p "$CACHE_DIR/kernel/$BOARD"
            if [ ! -L "$CACHE_DIR/kernel/$BOARD/$kernel_name" ]; then
                ln -sf "$KERNEL_SHARED_DIR/$kernel_name" "$CACHE_DIR/kernel/$BOARD/$kernel_name"
            fi
            ;;
        rpi4|rpi5)
            kernel_name="linux"
            echo "Fetching upstream Linux kernel"
            if [ ! -d "$KERNEL_SHARED_DIR/$kernel_name" ]; then
                mkdir -p "$KERNEL_SHARED_DIR"
                git clone --depth 1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_SHARED_DIR/$kernel_name"
            fi
            mkdir -p "$CACHE_DIR/kernel/$BOARD"
            if [ ! -L "$CACHE_DIR/kernel/$BOARD/$kernel_name" ]; then
                ln -sf "$KERNEL_SHARED_DIR/$kernel_name" "$CACHE_DIR/kernel/$BOARD/$kernel_name"
            fi
            ;;
    esac
}

fetch_uboot() {
    case "$BOARD" in
        rock5b|rock5c|rock5e)
            uboot_name="u-boot"
            UBOOT_REPO="https://github.com/radxa-uboot/u-boot"
            UBOOT_BRANCH="stable-2024.02-rk35xx"
            echo "Fetching Radxa U-Boot"
            if [ ! -d "$UBOOT_SHARED_DIR/$uboot_name" ]; then
                mkdir -p "$UBOOT_SHARED_DIR"
                git clone --depth 1 --branch "$UBOOT_BRANCH" "$UBOOT_REPO" "$UBOOT_SHARED_DIR/$uboot_name"
            fi
            mkdir -p "$CACHE_DIR/uboot/$BOARD"
            if [ ! -L "$CACHE_DIR/uboot/$BOARD/$uboot_name" ]; then
                ln -sf "$UBOOT_SHARED_DIR/$uboot_name" "$CACHE_DIR/uboot/$BOARD/$uboot_name"
            fi
            ;;
        rock3b)
            uboot_name="u-boot"
            UBOOT_REPO="https://github.com/u-boot/u-boot"
            UBOOT_BRANCH="v2024.10"
            echo "Fetching upstream U-Boot"
            if [ ! -d "$UBOOT_SHARED_DIR/$uboot_name" ]; then
                mkdir -p "$UBOOT_SHARED_DIR"
                git clone --depth 1 --branch "$UBOOT_BRANCH" "$UBOOT_REPO" "$UBOOT_SHARED_DIR/$uboot_name"
            fi
            mkdir -p "$CACHE_DIR/uboot/$BOARD"
            if [ ! -L "$CACHE_DIR/uboot/$BOARD/$uboot_name" ]; then
                ln -sf "$UBOOT_SHARED_DIR/$uboot_name" "$CACHE_DIR/uboot/$BOARD/$uboot_name"
            fi
            ;;
        rpi4|rpi5)
            uboot_name="u-boot"
            UBOOT_REPO="https://github.com/u-boot/u-boot"
            UBOOT_BRANCH="v2024.10"
            echo "Fetching upstream U-Boot"
            if [ ! -d "$UBOOT_SHARED_DIR/$uboot_name" ]; then
                mkdir -p "$UBOOT_SHARED_DIR"
                git clone --depth 1 --branch "$UBOOT_BRANCH" "$UBOOT_REPO" "$UBOOT_SHARED_DIR/$uboot_name"
            fi
            mkdir -p "$CACHE_DIR/uboot/$BOARD"
            if [ ! -L "$CACHE_DIR/uboot/$BOARD/$uboot_name" ]; then
                ln -sf "$UBOOT_SHARED_DIR/$uboot_name" "$CACHE_DIR/uboot/$BOARD/$uboot_name"
            fi
            ;;
    esac
}

fetch_rootfs() {
    echo "Fetching Alpine rootfs"
    mkdir -p "$CACHE_DIR/rootfs"
    if [ ! -f "$CACHE_DIR/rootfs/alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz" ]; then
        wget -q "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/aarch64/alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz" \
            -O "$CACHE_DIR/rootfs/alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz"
    fi
}

fetch_genimage() {
    echo "Checking for genimage"
    GENIMAGE_DIR="$CACHE_DIR/tools/genimage"
    if ! command -v genimage >/dev/null 2>&1; then
        mkdir -p "$CACHE_DIR/tools"
        if [ ! -d "$GENIMAGE_DIR" ]; then
            git clone --depth 1 https://github.com/pengutronix/genimage "$GENIMAGE_DIR"
        fi
        cd "$GENIMAGE_DIR"
        if [ ! -f "Makefile" ]; then
            ./bootstrap
        fi
        ./configure
        make
        make install DESTDIR="$CACHE_DIR/tools/install"
        export PATH="$CACHE_DIR/tools/install/bin:$PATH"
    fi
}

fetch_kernel
fetch_uboot
fetch_rootfs
fetch_genimage

echo "=== Fetch complete for $BOARD ==="
