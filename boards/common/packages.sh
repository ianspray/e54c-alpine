#!/bin/sh -x
# These APK's will be added to the image of all boards
# NB: this file assumes items that are only correct inside alpian-build.sh
apk add --no-scripts --allow-untrusted \
  --cache-dir /etc/apk/cache \
  --repository ${BUILD_DIR}/apk/alpian \
  --repository ${BUILD_DIR}/apk/${BOARD} \
  --root ${ROOTFS} \
  alpine-base \
  openrc \
  openssh \
  e2fsprogs \
  tzdata \
  xz \
  zstd \
  jq \
  wget \
  htop \
  curl \
  libelf \
  libmnl \
  iproute2-minimal \
  libxtables \
  iproute2-tc \
  iproute2 \
  iproute2-ss \
  avahi-libs \
  avahi \
  dbus-libs \
  libintl \
  libdaemon \
  libevent
