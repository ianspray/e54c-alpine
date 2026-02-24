#!/usr/bin/env bash
set -euo pipefail

export PATH="$PATH:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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
UPDATER_ALPINE_PACKAGES="${UPDATER_ALPINE_PACKAGES:-alpine-base alpine-conf openssh mtd-utils zstd}"

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

echo "Preparing updater Alpine rootfs..."
ROOTFS_DIR="$UPDATER_ROOTFS_DIR" \
ROOTFS_TAR="$UPDATER_ROOTFS_TAR" \
ALPINE_PACKAGES="$UPDATER_ALPINE_PACKAGES" \
ENABLE_BOOT_NET_BANNER=1 \
BOOT_BANNER_TITLE="E54C USB updater image" \
"$SCRIPT_DIR/prepare-alpine-rootfs.sh"

mkdir -p "$UPDATER_PAYLOAD_DIR"

echo "Creating compressed update payload..."
zstd -T0 -f "$NVME_IMAGE_PATH" -o "$UPDATER_PAYLOAD_FILE"
(
  cd "$UPDATER_PAYLOAD_DIR"
  sha256sum "$(basename "$UPDATER_PAYLOAD_FILE")" >"$(basename "$UPDATER_PAYLOAD_SHA256")"
)

cat >"$UPDATER_ROOTFS_DIR/usr/local/sbin/e54c-run-usb-update" <<'EOF'
#!/bin/sh
set -eu

PAYLOAD_FILE="/opt/e54c-updater/nvme-image.img.zst"
PAYLOAD_SHA256="/opt/e54c-updater/nvme-image.img.zst.sha256"
TARGET_NVME_DEVICE="${TARGET_NVME_DEVICE:-/dev/nvme0n1}"
ROOT_PARTLABEL_REQUIRED="${ROOT_PARTLABEL_REQUIRED:-updater-rootfs}"
TARGET_WAIT_SECONDS="${TARGET_WAIT_SECONDS:-120}"
UPDATER_EFI_MOUNT="/run/e54c-updater-efi"
LOCK_DIR="/run/e54c-usb-update.lock"

log() {
  echo "[e54c-usb-updater] $*"
}

log "E54C USB updater image active."

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "Updater is already running; skipping."
  exit 0
fi
cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if ! grep -q "root=PARTLABEL=$ROOT_PARTLABEL_REQUIRED" /proc/cmdline 2>/dev/null; then
  log "Not running from updater rootfs (expected root=PARTLABEL=$ROOT_PARTLABEL_REQUIRED)."
  exit 1
fi

resolve_root_device() {
  local src=""

  if command -v findmnt >/dev/null 2>&1; then
    src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  fi

  if [ -z "$src" ]; then
    src="$(awk '$2=="/"{print $1; exit}' /proc/mounts 2>/dev/null || true)"
  fi

  # Some kernels expose / as /dev/root; resolve from partlabel in that case.
  if [ "$src" = "/dev/root" ] || [ "$src" = "rootfs" ] || [ "$src" = "overlay" ] || [ -z "$src" ]; then
    if [ -b "/dev/disk/by-partlabel/$ROOT_PARTLABEL_REQUIRED" ]; then
      src="$(readlink -f "/dev/disk/by-partlabel/$ROOT_PARTLABEL_REQUIRED")"
    elif command -v blkid >/dev/null 2>&1; then
      src="$(blkid -t "PARTLABEL=$ROOT_PARTLABEL_REQUIRED" -o device 2>/dev/null | head -n1 || true)"
    fi
  fi

  if [ -n "$src" ] && [ -e "$src" ]; then
    src="$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")"
  fi

  printf '%s' "$src"
}

root_dev="$(resolve_root_device)"
if [ -z "$root_dev" ] || [ ! -b "$root_dev" ]; then
  log "Unable to determine root block device."
  exit 1
fi

case "$root_dev" in
  /dev/sd[a-z]3|/dev/vd[a-z]3|/dev/xvd[a-z]3)
    efi_dev="${root_dev%3}2"
    ;;
  /dev/mmcblk*p3|/dev/nvme*n*p3)
    efi_dev="${root_dev%p3}p2"
    ;;
  *)
    log "Unsupported root device layout: $root_dev"
    exit 1
    ;;
esac

if [ ! -b "$efi_dev" ]; then
  log "Updater EFI partition not found: $efi_dev"
  exit 1
fi

if [ "$root_dev" = "${TARGET_NVME_DEVICE}p3" ] || [ "$root_dev" = "${TARGET_NVME_DEVICE}p2" ] || [ "$root_dev" = "${TARGET_NVME_DEVICE}p1" ]; then
  log "Rootfs is on target device $TARGET_NVME_DEVICE; refusing to self-overwrite."
  exit 1
fi

if [ ! -f "$PAYLOAD_FILE" ] || [ ! -f "$PAYLOAD_SHA256" ]; then
  log "Missing payload or checksum."
  exit 1
fi

i=0
while [ ! -b "$TARGET_NVME_DEVICE" ] && [ "$i" -lt "$TARGET_WAIT_SECONDS" ]; do
  i=$((i + 1))
  sleep 1
done
if [ ! -b "$TARGET_NVME_DEVICE" ]; then
  log "Target NVMe device not found after ${TARGET_WAIT_SECONDS}s: $TARGET_NVME_DEVICE"
  exit 1
fi

log "Root device: $root_dev"
log "Updater EFI partition: $efi_dev"
log "Target NVMe device: $TARGET_NVME_DEVICE"

EXTLINUX_CONF="$UPDATER_EFI_MOUNT/extlinux/extlinux.conf"
DISABLED_EXTLINUX_CONF="$UPDATER_EFI_MOUNT/extlinux/extlinux.conf.disabled"
DONE_MARKER="$UPDATER_EFI_MOUNT/UPDATE_DONE"
mkdir -p "$UPDATER_EFI_MOUNT"
mountpoint -q "$UPDATER_EFI_MOUNT" || mount "$efi_dev" "$UPDATER_EFI_MOUNT"
if [ -f "$DONE_MARKER" ]; then
  log "Update already completed on this USB media; skipping."
  umount "$UPDATER_EFI_MOUNT" || true
  exit 0
fi

log "Verifying payload checksum..."
(cd "$(dirname "$PAYLOAD_FILE")" && sha256sum -c "$(basename "$PAYLOAD_SHA256")")

log "Flashing payload to $TARGET_NVME_DEVICE (this can take several minutes)..."
zstd -dc "$PAYLOAD_FILE" | dd of="$TARGET_NVME_DEVICE" bs=8M iflag=fullblock conv=fsync status=progress
sync

if command -v partprobe >/dev/null 2>&1; then
  partprobe "$TARGET_NVME_DEVICE" || true
fi

if command -v udevadm >/dev/null 2>&1; then
  udevadm settle || true
fi

log "Disabling USB updater boot entry so next boot falls through to NVMe..."
if [ -f "$EXTLINUX_CONF" ]; then
  mv "$EXTLINUX_CONF" "$DISABLED_EXTLINUX_CONF"
fi
date -u +"updated:%Y-%m-%dT%H:%M:%SZ target:$TARGET_NVME_DEVICE" >"$DONE_MARKER"
sync
umount "$UPDATER_EFI_MOUNT" || true

log "Update complete. Rebooting into NVMe image."
sleep 2
exec /sbin/reboot -f
EOF
chmod 0755 "$UPDATER_ROOTFS_DIR/usr/local/sbin/e54c-run-usb-update"

cat >"$UPDATER_ROOTFS_DIR/etc/conf.d/e54c-usb-nvme-update" <<EOF
target_device="${UPDATER_TARGET_NVME_DEVICE}"
EOF

cat >"$UPDATER_ROOTFS_DIR/etc/init.d/e54c-usb-nvme-update" <<'EOF'
#!/sbin/openrc-run

name="e54c-usb-nvme-update"
description="Flash bundled NVMe image from USB media, then reboot"

depend() {
  need localmount
  before networking
}

start() {
  ebegin "Running USB to NVMe update flow"
  TARGET_NVME_DEVICE="${target_device:-/dev/nvme0n1}" \
    /usr/local/sbin/e54c-run-usb-update
  eend $?
}
EOF
chmod 0755 "$UPDATER_ROOTFS_DIR/etc/init.d/e54c-usb-nvme-update"
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
DEFAULT_BOOT_MODE=maintenance \
KERNEL_CMDLINE_MAINTENANCE="root=PARTLABEL=$UPDATER_ROOT_PARTLABEL rootfstype=ext4 rootwait rw console=ttyFIQ0,1500000n8 earlycon" \
KERNEL_CMDLINE_IMMUTABLE="root=PARTLABEL=$UPDATER_ROOT_PARTLABEL rootfstype=ext4 rootwait rw console=ttyFIQ0,1500000n8 earlycon" \
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
  FDT /boot/dtbs/rockchip/rk3588s-radxa-e54c-spi.dtb
  APPEND root=PARTLABEL=${UPDATER_ROOT_PARTLABEL} rootfstype=ext4 rootwait rw console=ttyFIQ0,1500000n8 earlycon
EOF

guestfish <<EOF
add-drive $USB_UPDATER_IMAGE_PATH
run
mount /dev/sda2 /
upload $tmp_extlinux /extlinux/extlinux.conf
EOF

echo "USB updater image complete: $USB_UPDATER_IMAGE_PATH"
echo "Payload source image: $NVME_IMAGE_PATH"
echo "Payload checksum: $UPDATER_PAYLOAD_SHA256"
