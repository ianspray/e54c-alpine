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
APORTS_SRC="${BUILD_DIR}/aports"

####################
# F U N C T I O N S
#

setup_builder() {
  echo "setup_builder()"
  mkdir /build/apk
  chmod 777 /build/apk
  install -d -m 700 -o builder -g builder /home/builder/.abuild
  cp -f "${APORTS_SRC}/abuild.rsa" /home/builder/.abuild/
  cp -f "${APORTS_SRC}/abuild.rsa.pub" /home/builder/.abuild/
  echo 'PACKAGER_PRIVKEY="/home/builder/.abuild/abuild.rsa"' > /home/builder/.abuild/abuild.conf
  echo 'REPODEST="/build/apk"' >> /etc/abuild.conf
  chown builder:builder /home/builder/.abuild/*
  cp -f "${APORTS_SRC}/abuild.rsa.pub" /etc/apk/keys
}

build_aports() {
  echo "build_aports()"
  for APKBUILD in ${APORTS_SRC}/alpian/*/APKBUILD ${APORTS_SRC}/${BOARD}/*/APKBUILD; do
    if [ -f "${APKBUILD}" ]; then
      PKG_DIR="$(dirname ${APKBUILD})"
      PKG_NAME="$(basename ${PKG_DIR})"
      echo "Building '${PKG_NAME}'..."
      su -s /bin/sh builder -c "abuild-pkg.sh ${PKG_DIR}" 2>&1 || echo "Failed to build '${PKG_NAME}'"
    fi
  done
}

build_linux() {
  echo "build_linux()"
}

build_uboot() {
  echo "build_uboot()"
}

build_rootfs() {
  echo "build_rootfs()"
}

build_bootfs() {
  echo "build_bootfs"
}

build_image() {
  echo "build_image()"
}

##########
# M A I N
#
setup_builder
build_aports
