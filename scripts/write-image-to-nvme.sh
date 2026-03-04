#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

export PATH="$PATH:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BOARD="${BOARD:-e54c}"

IMAGE_PATH="$REPO_ROOT/build/${BOARD}-alpine-custom.img"
TARGET_DEVICE=""
ASSUME_YES=0
AUTO_UNMOUNT=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  write-image-to-nvme.sh --device /dev/nvme0n1 [options]

Options:
  --device <path>     Target block device (required, whole-disk only).
  --image <path>      Image file to write.
  --yes               Skip interactive confirmation prompt.
  --unmount           Unmount mounted target partitions before writing.
  --dry-run           Validate checks and print actions without writing.
  -h, --help          Show this help.
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --device)
      TARGET_DEVICE="${2:-}"
      shift 2
      ;;
    --image)
      IMAGE_PATH="${2:-}"
      shift 2
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --unmount)
      AUTO_UNMOUNT=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$TARGET_DEVICE" ]; then
  echo "--device is required." >&2
  usage
  exit 1
fi

require_cmd lsblk
require_cmd findmnt
require_cmd blockdev
require_cmd dd
require_cmd sha256sum
require_cmd sync

if [ "$EUID" -ne 0 ]; then
  echo "This script must run as root. Example:" >&2
  echo "  sudo $0 --device /dev/nvme0n1" >&2
  exit 1
fi

if [ ! -f "$IMAGE_PATH" ]; then
  echo "Image not found: $IMAGE_PATH" >&2
  exit 1
fi

if [ ! -b "$TARGET_DEVICE" ]; then
  echo "Target is not a block device: $TARGET_DEVICE" >&2
  exit 1
fi

target_type="$(lsblk -dn -o TYPE "$TARGET_DEVICE" 2>/dev/null || true)"
if [ "$target_type" != "disk" ]; then
  echo "Target must be a whole disk device (TYPE=disk), got TYPE=$target_type" >&2
  exit 1
fi

image_size="$(stat -c%s "$IMAGE_PATH")"
device_size="$(blockdev --getsize64 "$TARGET_DEVICE")"
if [ "$image_size" -gt "$device_size" ]; then
  echo "Image is larger than target device." >&2
  echo "  Image:  $image_size bytes" >&2
  echo "  Device: $device_size bytes" >&2
  exit 1
fi

root_source="$(findmnt -n -o SOURCE / || true)"
root_parent=""
if [ -n "$root_source" ] && [ -b "$root_source" ]; then
  if [ "$(lsblk -dn -o TYPE "$root_source" 2>/dev/null || true)" = "disk" ]; then
    root_parent="$root_source"
  else
    pkname="$(lsblk -dn -o PKNAME "$root_source" 2>/dev/null || true)"
    if [ -n "$pkname" ]; then
      root_parent="/dev/$pkname"
    fi
  fi
fi

if [ -n "$root_parent" ] && [ "$TARGET_DEVICE" = "$root_parent" ]; then
  echo "Refusing to write to current root disk: $TARGET_DEVICE" >&2
  exit 1
fi

mounted_lines="$(lsblk -nr -o PATH,MOUNTPOINT "$TARGET_DEVICE" | awk '$2 != "" {print $0}')"
if [ -n "$mounted_lines" ]; then
  if [ "$AUTO_UNMOUNT" -eq 1 ]; then
    while read -r dev mnt; do
      if [ -n "$mnt" ]; then
        echo "Unmounting $dev ($mnt)"
        umount "$dev"
      fi
    done <<< "$mounted_lines"
  else
    echo "Target has mounted filesystems. Unmount them first, or use --unmount." >&2
    echo "$mounted_lines" >&2
    exit 1
  fi
fi

echo "Write plan:"
echo "  Image : $IMAGE_PATH"
echo "  Target: $TARGET_DEVICE"
echo "  Size  : $image_size bytes -> $device_size byte device"
echo
lsblk "$TARGET_DEVICE"
echo

if [ "$ASSUME_YES" -ne 1 ]; then
  echo "Type the full target device path to confirm write:"
  read -r confirm
  if [ "$confirm" != "$TARGET_DEVICE" ]; then
    echo "Confirmation mismatch. Aborting."
    exit 1
  fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry-run complete. No data written."
  exit 0
fi

echo "Writing image to $TARGET_DEVICE ..."
dd if="$IMAGE_PATH" of="$TARGET_DEVICE" bs=8M iflag=fullblock conv=fsync status=progress
sync

if command -v partprobe >/dev/null 2>&1; then
  partprobe "$TARGET_DEVICE" || true
fi

if command -v udevadm >/dev/null 2>&1; then
  udevadm settle || true
fi

echo "Verifying first 12 MiB ..."
img_hash="$(dd if="$IMAGE_PATH" bs=1M count=12 status=none | sha256sum | awk '{print $1}')"
dev_hash="$(dd if="$TARGET_DEVICE" bs=1M count=12 status=none | sha256sum | awk '{print $1}')"
if [ "$img_hash" != "$dev_hash" ]; then
  echo "Verification failed: boot region checksum mismatch." >&2
  exit 1
fi

echo "Flash complete and verified."
