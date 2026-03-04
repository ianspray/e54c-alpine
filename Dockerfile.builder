# SPDX-License-Identifier: MIT
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Linux-native build toolchain for image/kernel/rootfs assembly.
RUN apt-get update && apt-get install -y --no-install-recommends \
  bash \
  bc \
  binwalk \
  bison \
  build-essential \
  ca-certificates \
  cpio \
  curl \
  debootstrap \
  device-tree-compiler \
  dosfstools \
  dwarves \
  e2fsprogs \
  fdisk \
  file \
  flex \
  gawk \
  gdisk \
  genisoimage \
  git \
  kpartx \
  libguestfs-tools \
  mtools \
  openssl \
  parted \
  perl \
  podman \
  python3 \
  qemu-utils \
  rsync \
  gcc-aarch64-linux-gnu \
  binutils-aarch64-linux-gnu \
  sed \
  squashfs-tools \
  tar \
  u-boot-tools \
  xorriso \
  xz-utils \
  && rm -rf /var/lib/apt/lists/*

# Podman-in-container is more reliable with vfs storage.
RUN mkdir -p /etc/containers /var/lib/containers/storage /run/containers/storage && \
  cat >/etc/containers/storage.conf <<'EOF'
[storage]
driver = "vfs"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
EOF

ENV BUILDAH_ISOLATION=chroot
ENV PODMAN_IGNORE_CGROUPSV1_WARNING=1

WORKDIR /workspace

CMD ["bash"]
