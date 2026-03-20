#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

export PATH="$PATH:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/board-config.sh"
load_board_config

UPDATER_WORK_DIR_WAS_SET="${UPDATER_WORK_DIR+x}"
UPDATER_ROOTFS_DIR_WAS_SET="${UPDATER_ROOTFS_DIR+x}"
UPDATER_ROOTFS_TAR_WAS_SET="${UPDATER_ROOTFS_TAR+x}"
UPDATER_PAYLOAD_DIR_WAS_SET="${UPDATER_PAYLOAD_DIR+x}"
UPDATER_PAYLOAD_FILE_WAS_SET="${UPDATER_PAYLOAD_FILE+x}"
UPDATER_PAYLOAD_SHA256_WAS_SET="${UPDATER_PAYLOAD_SHA256+x}"
UPDATER_GUESTFS_TMPDIR_WAS_SET="${UPDATER_GUESTFS_TMPDIR+x}"

NVME_IMAGE_PATH="${NVME_IMAGE_PATH:-$REPO_ROOT/build/${BOARD}-alpian-custom.img}"
USB_UPDATER_IMAGE_PATH="${USB_UPDATER_IMAGE_PATH:-$REPO_ROOT/build/${BOARD}-alpian-usb-updater.img}"
UPDATER_WORK_DIR="${UPDATER_WORK_DIR:-$REPO_ROOT/build/usb-updater}"
UPDATER_ROOTFS_DIR="${UPDATER_ROOTFS_DIR:-$UPDATER_WORK_DIR/rootfs}"
UPDATER_ROOTFS_TAR="${UPDATER_ROOTFS_TAR:-$UPDATER_WORK_DIR/rootfs.tar}"
UPDATER_PAYLOAD_DIR="${UPDATER_PAYLOAD_DIR:-$UPDATER_ROOTFS_DIR/opt/${BOARD}-updater}"
UPDATER_PAYLOAD_FILE="${UPDATER_PAYLOAD_FILE:-$UPDATER_PAYLOAD_DIR/nvme-image.img.zst}"
UPDATER_PAYLOAD_SHA256="${UPDATER_PAYLOAD_SHA256:-$UPDATER_PAYLOAD_FILE.sha256}"
UPDATER_OVERHEAD_MIB="${UPDATER_OVERHEAD_MIB:-1024}"
USB_IMAGE_SIZE="${USB_IMAGE_SIZE:-}"
USB_IMAGE_MIN_SIZE_MIB="${USB_IMAGE_MIN_SIZE_MIB:-7168}"
UPDATER_GUESTFS_TMPDIR="${UPDATER_GUESTFS_TMPDIR:-$UPDATER_WORK_DIR/guestfs-tmp}"
UPDATER_TARGET_DEVICE="${UPDATER_TARGET_DEVICE:-${BOARD_UPDATER_TARGET_DEVICE_DEFAULT:-${UPDATER_TARGET_NVME_DEVICE:-/dev/nvme0n1}}}"
UPDATER_ROOT_PARTLABEL="${UPDATER_ROOT_PARTLABEL:-${BOARD}-updater-rootfs}"
UPDATER_ROOTFS_MKFS_LABEL="${UPDATER_ROOTFS_MKFS_LABEL:-$UPDATER_ROOT_PARTLABEL}"
UPDATER_INITRAMFS_NAME="${UPDATER_INITRAMFS_NAME:-${INITRAMFS_NAME:-initramfs-${BOARD}.cpio.gz}}"
UPDATER_ALPINE_PACKAGES="${UPDATER_ALPINE_PACKAGES:-alpine-base alpine-conf openssh mtd-utils dosfstools e2fsprogs zstd}"
UPDATER_SERVICE_NAME="${UPDATER_SERVICE_NAME:-${BOARD_UPDATER_SERVICE_NAME:-${BOARD}-usb-nvme-update}}"
UPDATER_RUNNER_BIN="${UPDATER_RUNNER_BIN:-${BOARD_UPDATER_RUNNER_BIN:-${BOARD}-run-usb-update}}"
UPDATER_ROOTMODE_SERVICE_NAME="${UPDATER_ROOTMODE_SERVICE_NAME:-${BOARD_ROOTMODE_SERVICE_NAME:-${BOARD}-root-mode}}"
UPDATER_DTB_NAME="${UPDATER_DTB_NAME:-${BOARD_USB_UPDATER_DTB_NAME_DEFAULT:-${BOARD_DTB_NAME_DEFAULT:-rk3588s-radxa-e54c-spi.dtb}}}"
BOARD_DTB_SUBDIR="${BOARD_DTB_SUBDIR:-${BOARD_DTB_SUBDIR_DEFAULT:-rockchip}}"
BOOT_SCHEME="${BOOT_SCHEME:-${BOARD_BOOT_SCHEME:-rockchip-extlinux}}"
SERIAL_TTY="${SERIAL_TTY:-${BOARD_SERIAL_TTY:-ttyFIQ0}}"
SERIAL_BAUD="${SERIAL_BAUD:-${BOARD_SERIAL_BAUD:-1500000}}"
UPDATER_DISKLESS_TMPFS_MARGIN_MIB="${UPDATER_DISKLESS_TMPFS_MARGIN_MIB:-${DISKLESS_TMPFS_MARGIN_MIB:-200}}"
UPDATER_DISKLESS_TMPFS_SIZE_MIB="${UPDATER_DISKLESS_TMPFS_SIZE_MIB:-}"
UPDATER_DISKLESS="${UPDATER_DISKLESS:-${BOARD_UPDATER_DISKLESS_DEFAULT:-1}}"
CMDLINE_BASE_DEFAULT="${BOARD_KERNEL_CMDLINE_BASE_DEFAULT:-root=PARTLABEL=rootfs rootfstype=ext4 rootwait=30 console=${SERIAL_TTY},${SERIAL_BAUD}n8 nvme_core.default_ps_max_latency_us=0 pcie_aspm=off}"

# In containerized macOS workflows, bind-mounted /workspace can reject
# extraction/deletion of many rootfs files. Prefer container-local paths.
if [[ "$REPO_ROOT" == /workspace* ]]; then
  if [ -z "$UPDATER_ROOTFS_DIR_WAS_SET" ]; then
    UPDATER_ROOTFS_DIR="/tmp/${BOARD}-usb-updater-rootfs"
  fi
  if [ -z "$UPDATER_ROOTFS_TAR_WAS_SET" ]; then
    UPDATER_ROOTFS_TAR="/tmp/${BOARD}-usb-updater-rootfs.tar"
  fi
  if [ -z "$UPDATER_GUESTFS_TMPDIR_WAS_SET" ]; then
    UPDATER_GUESTFS_TMPDIR="/tmp/${BOARD}-usb-updater-guestfs-tmp"
  fi
fi

if [ -z "$UPDATER_PAYLOAD_DIR_WAS_SET" ]; then
  UPDATER_PAYLOAD_DIR="$UPDATER_ROOTFS_DIR/opt/${BOARD}-updater"
fi
if [ -z "$UPDATER_PAYLOAD_FILE_WAS_SET" ]; then
  UPDATER_PAYLOAD_FILE="$UPDATER_PAYLOAD_DIR/nvme-image.img.zst"
fi
if [ -z "$UPDATER_PAYLOAD_SHA256_WAS_SET" ]; then
  UPDATER_PAYLOAD_SHA256="$UPDATER_PAYLOAD_FILE.sha256"
fi

# ext2/3/4 filesystem labels are limited to 16 bytes.
if [ "${#UPDATER_ROOTFS_MKFS_LABEL}" -gt 16 ]; then
  shortened_mkfs_label="$(printf '%s' "$UPDATER_ROOTFS_MKFS_LABEL" | cut -c1-16)"
  echo "ROOTFS_MKFS_LABEL '$UPDATER_ROOTFS_MKFS_LABEL' exceeds ext label limit; using '$shortened_mkfs_label'."
  UPDATER_ROOTFS_MKFS_LABEL="$shortened_mkfs_label"
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
  echo "Build it first with scripts/build-all.sh or scripts/assemble-image.sh (BOARD=$BOARD)." >&2
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

echo "Preparing updater rootfs..."
ROOTFS_DIR="$UPDATER_ROOTFS_DIR" \
ROOTFS_TAR="$UPDATER_ROOTFS_TAR" \
ROOTFS_FALLBACK_DIR="/tmp/${BOARD}-usb-updater-rootfs" \
ALPINE_PACKAGES="$UPDATER_ALPINE_PACKAGES" \
ENABLE_BOOT_NET_BANNER=1 \
BOOT_BANNER_TITLE="${BOARD_DISPLAY_NAME} updater image" \
MOTD_TEMPLATE_FILE="$REPO_ROOT/assets/reference/alpine/motd-updater" \
"$SCRIPT_DIR/prepare-alpian-rootfs.sh"

if [ -f "$UPDATER_ROOTFS_DIR/etc/inittab" ]; then
  inittab_tmp="$(mktemp)"
  {
    printf '%s\n' '# updater debug marker'
    printf '%s\n' "::sysinit:/bin/sh -c 'echo \"<6>[updater-userspace] pid1 reached sysinit\" >/dev/kmsg 2>/dev/null || true; echo \"[updater-userspace] pid1 reached sysinit\" >/dev/console 2>/dev/null || true; if [ -c /dev/${SERIAL_TTY} ]; then echo \"[updater-userspace] pid1 reached sysinit\" >/dev/${SERIAL_TTY} 2>/dev/null || true; fi'"
    printf '%s\n' "::sysinit:/bin/sh -c 'if [ -c /dev/${SERIAL_TTY} ] && [ -f /etc/motd ]; then cat /etc/motd > /dev/${SERIAL_TTY} 2>/dev/null || true; printf \"\\n\" > /dev/${SERIAL_TTY} 2>/dev/null || true; fi'"
    cat "$UPDATER_ROOTFS_DIR/etc/inittab"
  } >"$inittab_tmp"
  mv "$inittab_tmp" "$UPDATER_ROOTFS_DIR/etc/inittab"
fi

# Updater image must be able to persistently edit its own boot entries.
# Keep root writable fallback if overlaytmpfs is not active.
rm -f "$UPDATER_ROOTFS_DIR/etc/runlevels/boot/$UPDATER_ROOTMODE_SERVICE_NAME"

mkdir -p "$UPDATER_PAYLOAD_DIR"

echo "Creating compressed update payload..."
zstd -T0 -f "$NVME_IMAGE_PATH" -o "$UPDATER_PAYLOAD_FILE"
(
  cd "$UPDATER_PAYLOAD_DIR"
  sha256sum "$(basename "$UPDATER_PAYLOAD_FILE")" >"$(basename "$UPDATER_PAYLOAD_SHA256")"
)

if [ ! -x "$UPDATER_ROOTFS_DIR/usr/sbin/$UPDATER_RUNNER_BIN" ] || [ ! -e "$UPDATER_ROOTFS_DIR/etc/init.d/$UPDATER_SERVICE_NAME" ]; then
  echo "Missing updater service package payload ($UPDATER_SERVICE_NAME / $UPDATER_RUNNER_BIN)." >&2
  echo "Build and enable the custom APK repository before building updater images." >&2
  exit 1
fi

mkdir -p "$UPDATER_ROOTFS_DIR/etc/conf.d"
cat >"$UPDATER_ROOTFS_DIR/etc/conf.d/$UPDATER_SERVICE_NAME" <<EOF
target_device="${UPDATER_TARGET_DEVICE}"
root_partlabel="${UPDATER_ROOT_PARTLABEL}"
target_wait_seconds="120"
EOF

mkdir -p "$UPDATER_ROOTFS_DIR/etc/runlevels/boot"
ln -snf "/etc/init.d/$UPDATER_SERVICE_NAME" "$UPDATER_ROOTFS_DIR/etc/runlevels/boot/$UPDATER_SERVICE_NAME"

tar --numeric-owner --owner=0 --group=0 -C "$UPDATER_ROOTFS_DIR" -cf "$UPDATER_ROOTFS_TAR" .

if [ -z "$UPDATER_DISKLESS_TMPFS_SIZE_MIB" ]; then
  updater_rootfs_tar_bytes="$(stat -c%s "$UPDATER_ROOTFS_TAR" 2>/dev/null || stat -f%z "$UPDATER_ROOTFS_TAR")"
  if [ -z "$updater_rootfs_tar_bytes" ] || [ "$updater_rootfs_tar_bytes" -le 0 ] 2>/dev/null; then
    echo "Unable to determine updater rootfs tar size: $UPDATER_ROOTFS_TAR" >&2
    exit 1
  fi
  updater_rootfs_tar_mib=$(((updater_rootfs_tar_bytes + 1024 * 1024 - 1) / (1024 * 1024)))
  UPDATER_DISKLESS_TMPFS_SIZE_MIB=$((updater_rootfs_tar_mib + UPDATER_DISKLESS_TMPFS_MARGIN_MIB))
fi

if ! [[ "$UPDATER_DISKLESS_TMPFS_SIZE_MIB" =~ ^[0-9]+$ ]] || [ "$UPDATER_DISKLESS_TMPFS_SIZE_MIB" -lt 1 ]; then
  echo "Invalid UPDATER_DISKLESS_TMPFS_SIZE_MIB value: $UPDATER_DISKLESS_TMPFS_SIZE_MIB" >&2
  exit 1
fi

if [ -z "$USB_IMAGE_SIZE" ]; then
  payload_bytes="$(stat -c%s "$UPDATER_PAYLOAD_FILE")"
  overhead_bytes=$((UPDATER_OVERHEAD_MIB * 1024 * 1024))
  required_bytes=$((payload_bytes + overhead_bytes))
  required_mib=$(((required_bytes + 1024 * 1024 - 1) / (1024 * 1024)))
  if [ "$required_mib" -lt "$USB_IMAGE_MIN_SIZE_MIB" ]; then
    required_mib="$USB_IMAGE_MIN_SIZE_MIB"
  fi
  USB_IMAGE_SIZE="${required_mib}M"
fi

echo "Assembling updater image..."
UPDATER_CMDLINE_BASE_DEFAULT="$(printf '%s\n' "$CMDLINE_BASE_DEFAULT" | sed -E "s#(^| )root=[^ ]+# root=PARTLABEL=${UPDATER_ROOT_PARTLABEL}#; s#^ ##")"
UPDATER_CMDLINE_BASE="${UPDATER_KERNEL_CMDLINE_BASE:-${BOARD_UPDATER_KERNEL_CMDLINE_BASE_DEFAULT:-$UPDATER_CMDLINE_BASE_DEFAULT}}"
case "$UPDATER_DISKLESS" in
  1|yes|true)
    UPDATER_ENABLE_INITRAMFS_BOOT=1
    UPDATER_CMDLINE_COMMON="${UPDATER_CMDLINE_BASE} ro diskless=yes diskless_tmpfs_size=${UPDATER_DISKLESS_TMPFS_SIZE_MIB}"
    ;;
  0|no|false)
    UPDATER_ENABLE_INITRAMFS_BOOT=0
    UPDATER_CMDLINE_COMMON="${UPDATER_CMDLINE_BASE} rw"
    ;;
  *)
    echo "Invalid UPDATER_DISKLESS value: $UPDATER_DISKLESS" >&2
    exit 1
    ;;
esac
IMAGE_PATH="$USB_UPDATER_IMAGE_PATH" \
IMAGE_SIZE="$USB_IMAGE_SIZE" \
ROOTFS_TAR="$UPDATER_ROOTFS_TAR" \
ROOTFS_PARTLABEL="$UPDATER_ROOT_PARTLABEL" \
ROOTFS_MKFS_LABEL="$UPDATER_ROOTFS_MKFS_LABEL" \
INITRAMFS_NAME="$UPDATER_INITRAMFS_NAME" \
ENABLE_INITRAMFS_BOOT="$UPDATER_ENABLE_INITRAMFS_BOOT" \
BOOTCFG_PART_GPT_TYPE="EBD0A0A2-B9E5-4433-87C0-68B6B72699C7" \
DEFAULT_BOOT_MODE=maintenance \
KERNEL_CMDLINE_MAINTENANCE="$UPDATER_CMDLINE_COMMON" \
KERNEL_CMDLINE_IMMUTABLE="$UPDATER_CMDLINE_COMMON" \
"$SCRIPT_DIR/assemble-image.sh"

if [ "$BOOT_SCHEME" = "rockchip-extlinux" ]; then
  tmp_extlinux="$(mktemp)"
  trap 'rm -f "$tmp_extlinux"' EXIT
  tmp_initrd_line=""
  if [ "$UPDATER_ENABLE_INITRAMFS_BOOT" = "1" ]; then
    tmp_initrd_line="  INITRD /boot/${UPDATER_INITRAMFS_NAME}"
  fi
  cat >"$tmp_extlinux" <<EOF
DEFAULT updater
MENU TITLE U-Boot menu
PROMPT 0
TIMEOUT 10

LABEL updater
  MENU LABEL Alpian updater image (flash target storage and reboot)
  LINUX /boot/Image
  FDT /boot/dtbs/${BOARD_DTB_SUBDIR}/${UPDATER_DTB_NAME}
${tmp_initrd_line}
  APPEND ${UPDATER_CMDLINE_COMMON}
EOF

  guestfish <<EOF
add-drive $USB_UPDATER_IMAGE_PATH
run
mount /dev/sda2 /
upload $tmp_extlinux /extlinux/extlinux.conf
EOF
else
  echo "BOOT_SCHEME=$BOOT_SCHEME: using firmware-native boot config generated by assemble-image.sh"
fi

echo "Updater image complete: $USB_UPDATER_IMAGE_PATH"
echo "Payload source image: $NVME_IMAGE_PATH"
echo "Payload checksum: $UPDATER_PAYLOAD_SHA256"
