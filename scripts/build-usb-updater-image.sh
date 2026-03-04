#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

export PATH="$PATH:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

UPDATER_WORK_DIR_WAS_SET="${UPDATER_WORK_DIR+x}"
UPDATER_ROOTFS_DIR_WAS_SET="${UPDATER_ROOTFS_DIR+x}"
UPDATER_ROOTFS_TAR_WAS_SET="${UPDATER_ROOTFS_TAR+x}"
UPDATER_PAYLOAD_DIR_WAS_SET="${UPDATER_PAYLOAD_DIR+x}"
UPDATER_PAYLOAD_FILE_WAS_SET="${UPDATER_PAYLOAD_FILE+x}"
UPDATER_PAYLOAD_SHA256_WAS_SET="${UPDATER_PAYLOAD_SHA256+x}"
UPDATER_GUESTFS_TMPDIR_WAS_SET="${UPDATER_GUESTFS_TMPDIR+x}"

NVME_IMAGE_PATH="${NVME_IMAGE_PATH:-$REPO_ROOT/build/e54c-alpine-custom.img}"
USB_UPDATER_IMAGE_PATH="${USB_UPDATER_IMAGE_PATH:-$REPO_ROOT/build/e54c-alpine-usb-updater.img}"
UPDATER_WORK_DIR="${UPDATER_WORK_DIR:-$REPO_ROOT/build/usb-updater}"
UPDATER_ROOTFS_DIR="${UPDATER_ROOTFS_DIR:-$UPDATER_WORK_DIR/rootfs}"
UPDATER_ROOTFS_TAR="${UPDATER_ROOTFS_TAR:-$UPDATER_WORK_DIR/rootfs.tar}"
UPDATER_PAYLOAD_DIR="${UPDATER_PAYLOAD_DIR:-$UPDATER_ROOTFS_DIR/opt/e54c-updater}"
UPDATER_PAYLOAD_FILE="${UPDATER_PAYLOAD_FILE:-$UPDATER_PAYLOAD_DIR/nvme-image.img.zst}"
UPDATER_PAYLOAD_SHA256="${UPDATER_PAYLOAD_SHA256:-$UPDATER_PAYLOAD_FILE.sha256}"
UPDATER_OVERHEAD_MIB="${UPDATER_OVERHEAD_MIB:-2048}"
USB_IMAGE_SIZE="${USB_IMAGE_SIZE:-}"
UPDATER_GUESTFS_TMPDIR="${UPDATER_GUESTFS_TMPDIR:-$UPDATER_WORK_DIR/guestfs-tmp}"
UPDATER_TARGET_NVME_DEVICE="${UPDATER_TARGET_NVME_DEVICE:-/dev/nvme0n1}"
UPDATER_ROOT_PARTLABEL="${UPDATER_ROOT_PARTLABEL:-updater-rootfs}"
UPDATER_INITRAMFS_NAME="${UPDATER_INITRAMFS_NAME:-${INITRAMFS_NAME:-initramfs-e54c.cpio.gz}}"
UPDATER_ALPINE_PACKAGES="${UPDATER_ALPINE_PACKAGES:-alpine-base alpine-conf openssh mtd-utils dosfstools e2fsprogs zstd}"

# In containerized macOS workflows, bind-mounted /workspace can reject
# extraction/deletion of many rootfs files. Prefer container-local paths.
if [[ "$REPO_ROOT" == /workspace* ]]; then
  if [ -z "$UPDATER_ROOTFS_DIR_WAS_SET" ]; then
    UPDATER_ROOTFS_DIR="/tmp/e54c-usb-updater-rootfs"
  fi
  if [ -z "$UPDATER_ROOTFS_TAR_WAS_SET" ]; then
    UPDATER_ROOTFS_TAR="/tmp/e54c-usb-updater-rootfs.tar"
  fi
  if [ -z "$UPDATER_GUESTFS_TMPDIR_WAS_SET" ]; then
    UPDATER_GUESTFS_TMPDIR="/tmp/e54c-usb-updater-guestfs-tmp"
  fi
fi

if [ -z "$UPDATER_PAYLOAD_DIR_WAS_SET" ]; then
  UPDATER_PAYLOAD_DIR="$UPDATER_ROOTFS_DIR/opt/e54c-updater"
fi
if [ -z "$UPDATER_PAYLOAD_FILE_WAS_SET" ]; then
  UPDATER_PAYLOAD_FILE="$UPDATER_PAYLOAD_DIR/nvme-image.img.zst"
fi
if [ -z "$UPDATER_PAYLOAD_SHA256_WAS_SET" ]; then
  UPDATER_PAYLOAD_SHA256="$UPDATER_PAYLOAD_FILE.sha256"
fi

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

require_cmd zstd
require_cmd sha256sum
require_cmd tar
require_cmd awk

"$SCRIPT_DIR/check-tooling.sh"

if [ ! -f "$NVME_IMAGE_PATH" ]; then
  echo "NVMe image not found: $NVME_IMAGE_PATH" >&2
  echo "Build it first with scripts/build-all-e54c.sh or scripts/assemble-e54c-image.sh." >&2
  exit 1
fi

mkdir -p "$UPDATER_WORK_DIR"
mkdir -p "$UPDATER_GUESTFS_TMPDIR"

# Avoid failures on systems where /tmp is a small tmpfs.
export TMPDIR="$UPDATER_GUESTFS_TMPDIR"
export LIBGUESTFS_TMPDIR="$UPDATER_GUESTFS_TMPDIR"
export LIBGUESTFS_CACHEDIR="$UPDATER_GUESTFS_TMPDIR"
export LIBGUESTFS_BACKEND_SETTINGS="${LIBGUESTFS_BACKEND_SETTINGS:-force_tcg}"
export LIBGUESTFS_MEMSIZE="${LIBGUESTFS_MEMSIZE:-1024}"

echo "Preparing updater Alpine rootfs..."
ROOTFS_DIR="$UPDATER_ROOTFS_DIR" \
ROOTFS_TAR="$UPDATER_ROOTFS_TAR" \
ALPINE_PACKAGES="$UPDATER_ALPINE_PACKAGES" \
ENABLE_BOOT_NET_BANNER=1 \
BOOT_BANNER_TITLE="E54C USB updater image" \
MOTD_TEMPLATE_FILE="$REPO_ROOT/assets/reference/alpine/motd-updater" \
"$SCRIPT_DIR/prepare-alpine-rootfs.sh"

# Updater image must be able to persistently edit its own boot entries.
# Keep root writable fallback if overlaytmpfs is not active.
rm -f "$UPDATER_ROOTFS_DIR/etc/runlevels/boot/e54c-root-mode"

mkdir -p "$UPDATER_PAYLOAD_DIR"

echo "Creating compressed update payload..."
zstd -T0 -f "$NVME_IMAGE_PATH" -o "$UPDATER_PAYLOAD_FILE"
(
  cd "$UPDATER_PAYLOAD_DIR"
  sha256sum "$(basename "$UPDATER_PAYLOAD_FILE")" >"$(basename "$UPDATER_PAYLOAD_SHA256")"
)

if [ ! -x "$UPDATER_ROOTFS_DIR/usr/sbin/e54c-run-usb-update" ] || [ ! -e "$UPDATER_ROOTFS_DIR/etc/init.d/e54c-usb-nvme-update" ]; then
  echo "Missing updater service package payload (e54c-usb-updater-services)." >&2
  echo "Build and enable the custom APK repository before building updater images." >&2
  exit 1
fi

mkdir -p "$UPDATER_ROOTFS_DIR/etc/conf.d"
cat >"$UPDATER_ROOTFS_DIR/etc/conf.d/e54c-usb-nvme-update" <<EOF
target_device="${UPDATER_TARGET_NVME_DEVICE}"
root_partlabel="${UPDATER_ROOT_PARTLABEL}"
target_wait_seconds="120"
EOF

mkdir -p "$UPDATER_ROOTFS_DIR/etc/runlevels/boot"
ln -snf /etc/init.d/e54c-usb-nvme-update "$UPDATER_ROOTFS_DIR/etc/runlevels/boot/e54c-usb-nvme-update"

tar --numeric-owner --owner=0 --group=0 -C "$UPDATER_ROOTFS_DIR" -cf "$UPDATER_ROOTFS_TAR" .

if [ -z "$USB_IMAGE_SIZE" ]; then
  payload_bytes="$(stat -c%s "$UPDATER_PAYLOAD_FILE")"
  overhead_bytes=$((UPDATER_OVERHEAD_MIB * 1024 * 1024))
  required_bytes=$((payload_bytes + overhead_bytes))
  required_mib=$(((required_bytes + 1024 * 1024 - 1) / (1024 * 1024)))
  if [ "$required_mib" -lt 4096 ]; then
    required_mib=4096
  fi
  USB_IMAGE_SIZE="${required_mib}M"
fi

echo "Assembling USB updater image..."
IMAGE_PATH="$USB_UPDATER_IMAGE_PATH" \
IMAGE_SIZE="$USB_IMAGE_SIZE" \
ROOTFS_TAR="$UPDATER_ROOTFS_TAR" \
ROOTFS_PARTLABEL="$UPDATER_ROOT_PARTLABEL" \
ROOTFS_MKFS_LABEL="$UPDATER_ROOT_PARTLABEL" \
INITRAMFS_NAME="$UPDATER_INITRAMFS_NAME" \
BOOTCFG_PART_GPT_TYPE="EBD0A0A2-B9E5-4433-87C0-68B6B72699C7" \
DEFAULT_BOOT_MODE=maintenance \
KERNEL_CMDLINE_MAINTENANCE="root=PARTLABEL=$UPDATER_ROOT_PARTLABEL rootfstype=ext4 rootwait ro diskless=yes console=ttyFIQ0,1500000n8 earlycon nvme_core.default_ps_max_latency_us=0 pcie_aspm=off" \
KERNEL_CMDLINE_IMMUTABLE="root=PARTLABEL=$UPDATER_ROOT_PARTLABEL rootfstype=ext4 rootwait ro diskless=yes console=ttyFIQ0,1500000n8 earlycon nvme_core.default_ps_max_latency_us=0 pcie_aspm=off" \
"$SCRIPT_DIR/assemble-e54c-image.sh"

tmp_extlinux="$(mktemp)"
trap 'rm -f "$tmp_extlinux"' EXIT
cat >"$tmp_extlinux" <<EOF
DEFAULT updater
MENU TITLE U-Boot menu
PROMPT 1
TIMEOUT 10

LABEL updater
  MENU LABEL Alpine Linux USB updater (flash NVMe and reboot)
  LINUX /boot/Image
  INITRD /boot/${UPDATER_INITRAMFS_NAME}
  FDT /boot/dtbs/rockchip/rk3588s-radxa-e54c-spi.dtb
  APPEND root=PARTLABEL=${UPDATER_ROOT_PARTLABEL} rootfstype=ext4 rootwait ro diskless=yes console=ttyFIQ0,1500000n8 earlycon nvme_core.default_ps_max_latency_us=0 pcie_aspm=off
EOF

guestfish <<EOF
add-drive $USB_UPDATER_IMAGE_PATH
run
mount /dev/sda2 /
upload $tmp_extlinux /extlinux/extlinux.conf
umount /
mount /dev/sda3 /
rm-f /boot/extlinux/extlinux.conf
EOF

echo "USB updater image complete: $USB_UPDATER_IMAGE_PATH"
echo "Payload source image: $NVME_IMAGE_PATH"
echo "Payload checksum: $UPDATER_PAYLOAD_SHA256"
