#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Ian Spray
#
# NB: rebuild the alpian-builder container after making changes to this files to
# ensure that the changes are available to use on subsequent build commands
set -e

CACHE_DIR="/cache"
BOARDS_DIR="/boards"
BUILD_DIR="/build"
WORK_DIR="/work"
OUT_DIR="/out"

source "${BOARDS_DIR}/${BOARD}/${BOARD}.env"

LINUX_SRC="${CACHE_DIR}/linux/${KERNEL_DIR}/kernel"
UBOOT_SRC="${CACHE_DIR}/u-boot/${UBOOT_DIR}/u-boot"
APORTS_SRC="${BUILD_DIR}/aports"

ROOTFS="${WORK_DIR}/rootfs"

####################
# F U N C T I O N S
#

setup_builder() {
  echo "setup_builder()"
  mkdir -p ${BUILD_DIR}/apk
  chmod 777 ${BUILD_DIR}/apk
  install -d -m 700 -o builder -g builder /home/builder/.abuild
  cp -f "${APORTS_SRC}/abuild.rsa" /home/builder/.abuild/
  cp -f "${APORTS_SRC}/abuild.rsa.pub" /home/builder/.abuild/
  echo 'PACKAGER_PRIVKEY="/home/builder/.abuild/abuild.rsa"' > /home/builder/.abuild/abuild.conf
  echo 'REPODEST="/build/apk"' >> /home/builder/.abuild/abuild.conf
  chown builder:builder /home/builder/.abuild/*
  cp -f "${APORTS_SRC}/abuild.rsa.pub" /etc/apk/keys

  echo "/apk-cache" > /etc/apk/repositories
#  cd /apk-cache/aarch64
#  apk index -o APKINDEX.tar.gz *.apk
#  cd -
  echo "${BUILD_DIR}/apk/alpian" >> /etc/apk/repositories
  echo "${BUILD_DIR}/apk/${BOARD}" >> /etc/apk/repositories
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

  cd ${BUILD_DIR}/apk/alpian/aarch64
  apk index -o APKINDEX.tar.gz *.apk
  cd -

  cd ${BUILD_DIR}/apk/${BOARD}/aarch64
  apk index -o APKINDEX.tar.gz *.apk
  cd -
}

build_linux() {
  echo "build_linux()"
}

build_uboot() {
  echo "build_uboot()"
}

build_rootfs() {
  echo "build_rootfs()"
  mkdir -p "${ROOTFS}"
  # add the packages common for all boards
  echo "Common..."
  source ${BOARDS_DIR}/common/packages.sh
  # add the packages that this specific device wants
  echo "${BAORD}..."
  source ${BOARDS_DIR}/${BOARD}/packages.sh
  # copy in any tree of files that is always to be present
  echo cp -a ${BUILD_DIR}/rootfs-overlay/* ${ROOTFS}/
  cp -a ${BUILD_DIR}/rootfs-overlay/* ${ROOTFS}/
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
build_rootfs
