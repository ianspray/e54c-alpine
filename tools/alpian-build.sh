#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Ian Spray
#
# NB: rebuild the alpian-builder container after making changes to this files to
# ensure that the changes are available to use on subsequent build commands
set -e

ALPINE_VER="v3.23"
CACHE_DIR="/cache"
BOARDS_DIR="/boards"
BUILD_DIR="/build"
WORK_DIR="/work"
OUT_DIR="/out"

source "${BOARDS_DIR}/${BOARD}/${BOARD}.env"

LINUX_SRC="${CACHE_DIR}/linux/${KERNEL_DIR}/kernel"
LINUX_CFG="${BOARDS_DIR}/${BOARD}/linux.config"
UBOOT_SRC="${CACHE_DIR}/u-boot/${UBOOT_DIR}/u-boot"
UBOOT_CFG="${BOARDS_DIR}/${BOARD}/u-boot.config"
APORTS_SRC="${BUILD_DIR}/aports"

ROOTFS="${WORK_DIR}/rootfs"
ROOTFS="${WORK_DIR}/bootfs"

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

  # remove any stale indexes that would cause signature mismatch
  rm -f "${BUILD_DIR}/apk/alpian/aarch64/APKINDEX.tar.gz"
  rm -f "${BUILD_DIR}/apk/${BOARD}/aarch64/APKINDEX.tar.gz"

  # re-create indexes signed with the correct key if packages exist
  for dir in "${BUILD_DIR}/apk/alpian/aarch64" "${BUILD_DIR}/apk/${BOARD}/aarch64"; do
    mkdir -p "$dir"
    if ls "$dir"/*.apk 2>/dev/null | grep -q .; then
      apk index -o "$dir/APKINDEX.tar.gz" "$dir"/*.apk
      abuild-sign -k "${APORTS_SRC}/abuild.rsa" "$dir/APKINDEX.tar.gz"
    fi
  done

  # keep standard alpine repos for dependency resolution
  # /etc/apk/cache is already bind-mounted with the pre-fetched .apk files
  # so network hits will be avoided for anything already cached
  cat > /etc/apk/repositories <<EOF
https://dl-cdn.alpinelinux.org/alpine/${ALPINE_VER}/main
https://dl-cdn.alpinelinux.org/alpine/${ALPINE_VER}/community
${BUILD_DIR}/apk/alpian
${BUILD_DIR}/apk/${BOARD}
EOF
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
  cd "${LINUX_SRC}"
  make clean
  # take the preferred defaults
  cp "${LINUX_CFG}" .config
  # fold in any new options with sensible defaults
  make olddefconfig
  # build the kernel
  make
  # build modules
  make modules
  # FIXME: do I need to execute the code from the following line ?
  echo make modules_install
  # show any new options and their defaults
  echo "--- new linux kernel config entries and defaults: ---"
  make listnewconfig
  echo "--- new kernel config ends ---"
  cd -
}

build_uboot() {
  echo "build_uboot()"
  cd "${UBOOT_SRC}"
  make clean
  # take the preferred defaults
  cp "${UBOOT_CFG}" .config
  # fold in any new options with sensible defaults
  make olddefconfig
  # build the kernel
  make
  # show any new options and their defaults
  echo "--- new u-boot config entries and defaults: ---"
  make listnewconfig
  echo "--- new u-boot config ends ---"
  cd -
}

build_rootfs() {
  echo "build_rootfs()"
  mkdir -p "${ROOTFS}/etc/apk"
  apk --root ${ROOTFS} add --initdb
  cp /etc/apk/repositories $ROOTFS/etc/apk
  # add the packages common for all boards
  echo "Add Common APKs..."
  source ${BOARDS_DIR}/common/packages.sh
  # add the packages that this specific device wants
  echo "Add ${BOARD} APKs..."
  source ${BOARDS_DIR}/${BOARD}/packages.sh
}

setup_alpine() {
  echo "setup_alpine()"
  # Ensure OpenRC works in containerized root
  echo "rc_sys=lxc" >> ${ROOTFS}/etc/rc.conf
  echo "rc_provide=loopback" >> ${ROOTFS}/etc/rc.conf
  # Enable services
  chroot ${ROOTFS} rc-update add sshd default
  # copy in the tree of files that is always to be present
  echo cp -a ${BUILD_DIR}/rootfs-overlay/* ${ROOTFS}/
  cp -a ${BUILD_DIR}/rootfs-overlay/* ${ROOTFS}/
  # FIXME: this is opaque and probably incorrect - read from custom kernel build
  KVER=$( ls /lib/modules | head -n1 )
  # build initramfs
  mkinitfs -b ${ROOTFS} \
    -c ${ROOTFS}/etc/mkinitfs/mkinitfs.conf \
    ${KVER}
}

export_rootfs() {
  echo "export_rootfs()"
  tar -cvpf ${OUT}/rootfs.tar -C ${ROOTFS}
  xz ${OUT}/rootfs.tar
}

build_bootfs() {
  echo "build_bootfs"
  mkdir -p ${BOOTFS}
  # copy in the tree of files that is always to be present
  echo cp -a ${BUILD_DIR}/bootfs/* ${BOOTFS}/
  cp -a ${BUILD_DIR}/bootfs/* ${BOOTFS}/
  # FIXME: run the extlinux.conf file through an env var expansion
  # so that the correct boot media and kernel command line can be set
  echo "*** Missing extlinx.conf changes for ${BOARD}"
  # FIXME: should this come from the kernel & uboot builds ?
  cp ${ROOTFS}/boot/vmlinuz-* ${BOOTFS}/vmlinuz
  cp ${ROOTFS}/boot/initramfs-* ${BOOTFS}/initramfs
}

export_bootfs() {
  echo "export_bootfs()"
  tar -cvpf ${OUT}/bootfs.tar -C ${BOOTFS}
  xz ${OUT}/bootfs.tar
}

build_image() {
  echo "build_image()"
  genimage \
    --rootpath ${ROOTFS}
    --tmppath /tmp/genimage \
    --inputpath ${WORK} \
    --outputpath ${OUT} \
    --config ${BOARDS_DIR}/${BOARD}/genimage.${BOARD}
}

##########
# M A I N
#
setup_builder
build_aports
build_uboot
build_linux
build_rootfs
setup_alpine
build_bootfs
export_rootfs
export_bootfs
build_image
echo "Done."
