#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Ian Spray
set -e

CACHE_DIR="/cache"
BOARDS_DIR="/boards"
BUILD_DIR="/build"
OUT_DIR="/out"

source "${BOARDS_DIR}/${BOARD}/${BOARD}.env"

LINUX_SRC="${CACHE_DIR}/linux/${KERNEL_DIR}/kernel"
UBOOT_SRC="${CACHE_DIR}/u-boot/${UBOOT_DIR}/u-boot"
APORTS_SRC="${BUILD}/aports"

####################
# F U N C T I O N S
#

setup_builder() {
  install -d -m 700  -o builder -g builder /home/builder/.abuild
  cp -f "${APORTS_SRC}/*.rsa" /home/builder/.abuild
  cp -f "${APORTS_SRC}/*.rsa.pub" /home/builder/.abuild
  chown builder:builder /home/builder/.abuild/*
}

build_aports() {
  for APKBUILD in "${APORTS_SRC}/alpian/*/APKBUILD"; do
    if [ -f "${APKBUILD}" ]; then
      PKG_DIR="$(dirname "${APKBUILD}")"
      PKG_NAME="$(basenamw "${PKG_DIR}")"
      echo "Building ${PKG_NAME}..."
      ./abuild
    fi
  done
  for APKBUILD in "${APORTS_SRC}/${BOARD}/*/APKBUILD"; do
  done
}

build_linux() {
}

build_uboot() {
}

build_aports() {
}

build_rootfs() {
}

build_bootfs() {
}

build_image() {
}

##########
# M A I N
#
