#!/usr/bin/env bash
set -euo pipefail

export PATH="$PATH:/usr/sbin:/sbin"
export TMPDIR="${TMPDIR:-/tmp}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
export LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND:-direct}"
export LIBGUESTFS_TMPDIR="${LIBGUESTFS_TMPDIR:-/tmp}"
export LIBGUESTFS_CACHEDIR="${LIBGUESTFS_CACHEDIR:-/tmp}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE_PATH="${IMAGE_PATH:-$REPO_ROOT/build/e54c-alpine-custom.img}"
IMAGE_SIZE="${IMAGE_SIZE:-8G}"
ROOTFS_TAR="${ROOTFS_TAR:-$REPO_ROOT/build/alpine-rootfs.tar}"
UBOOT_DIR="${UBOOT_DIR:-$REPO_ROOT/assets/reference/u-boot}"
CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/assets/reference/radxa/config.txt}"
DEFAULT_BOOT_MODE="${DEFAULT_BOOT_MODE:-immutable}"
BOARD_DTB_NAME="${BOARD_DTB_NAME:-rk3588s-radxa-e54c-spi.dtb}"
ROOTFS_PARTLABEL="${ROOTFS_PARTLABEL:-rootfs}"
ROOTFS_MKFS_LABEL="${ROOTFS_MKFS_LABEL:-$ROOTFS_PARTLABEL}"

# Partition geometry (512-byte sectors):
# - p1 config: 256 MiB (starts at 16 MiB)
# - p2 efi:    300 MiB
# - p3 rootfs: remainder
P1_START=32768
P1_SIZE_SECTORS=$((256 * 1024 * 1024 / 512))
P1_END=$((P1_START + P1_SIZE_SECTORS - 1))
P2_START=$((P1_END + 1))
P2_SIZE_SECTORS=$((300 * 1024 * 1024 / 512))
P2_END=$((P2_START + P2_SIZE_SECTORS - 1))
P3_START=$((P2_END + 1))

if [ -z "${KERNEL_RELEASE_DIR:-}" ]; then
  KERNEL_RELEASE_DIR="$(ls -dt "$REPO_ROOT"/build/kernel-artifacts/* 2>/dev/null | head -n1 || true)"
fi

if [ -z "$KERNEL_RELEASE_DIR" ] || [ ! -d "$KERNEL_RELEASE_DIR" ]; then
  echo "KERNEL_RELEASE_DIR is not set and no kernel artifacts were found." >&2
  exit 1
fi

for req in "$ROOTFS_TAR" "$UBOOT_DIR/idbloader.img" "$UBOOT_DIR/u-boot.itb" "$KERNEL_RELEASE_DIR/boot/Image"; do
  if [ ! -e "$req" ]; then
    echo "Missing required input: $req" >&2
    exit 1
  fi
done

KERNEL_DTB="$KERNEL_RELEASE_DIR/boot/dtbs/rockchip/$BOARD_DTB_NAME"
if [ ! -f "$KERNEL_DTB" ]; then
  echo "Missing required DTB: $KERNEL_DTB" >&2
  exit 1
fi

mkdir -p "$(dirname "$IMAGE_PATH")"
truncate -s "$IMAGE_SIZE" "$IMAGE_PATH"

tmp_stage="$(mktemp -d)"
trap 'rm -rf "$tmp_stage"' EXIT

if [ ! -f "$CONFIG_FILE" ]; then
  CONFIG_FILE="$tmp_stage/config.txt"
  cat >"$CONFIG_FILE" <<'EOF'
# rsetup config placeholder
EOF
fi

mkdir -p "$tmp_stage/boot/extlinux" "$tmp_stage/boot/dtbs/rockchip"
cp "$KERNEL_RELEASE_DIR/boot/Image" "$tmp_stage/boot/Image"
cp "$KERNEL_DTB" "$tmp_stage/boot/dtbs/rockchip/"

# Keep bootargs intentionally short and put root first.
# Some U-Boot extlinux paths appear to truncate long APPEND lines.
CMDLINE_BASE_DEFAULT="root=PARTLABEL=${ROOTFS_PARTLABEL} rootfstype=ext4 rootwait console=ttyFIQ0,1500000n8 earlycon"
CMDLINE_BASE="${KERNEL_CMDLINE_BASE:-$CMDLINE_BASE_DEFAULT}"
CMDLINE_IMMUTABLE_DEFAULT="${CMDLINE_BASE} ro overlaytmpfs=yes"
CMDLINE_MAINTENANCE_DEFAULT="${CMDLINE_BASE} rw"
CMDLINE_IMMUTABLE="${KERNEL_CMDLINE_IMMUTABLE:-${KERNEL_CMDLINE:-$CMDLINE_IMMUTABLE_DEFAULT}}"
CMDLINE_MAINTENANCE="${KERNEL_CMDLINE_MAINTENANCE:-$CMDLINE_MAINTENANCE_DEFAULT}"

case "$DEFAULT_BOOT_MODE" in
  immutable) DEFAULT_EXTLINUX_LABEL="immutable" ;;
  maintenance) DEFAULT_EXTLINUX_LABEL="maintenance" ;;
  *)
    echo "Unsupported DEFAULT_BOOT_MODE: $DEFAULT_BOOT_MODE (expected immutable|maintenance)" >&2
    exit 1
    ;;
esac

cat >"$tmp_stage/boot/extlinux/extlinux.conf" <<EOF
DEFAULT ${DEFAULT_EXTLINUX_LABEL}
MENU TITLE U-Boot menu
PROMPT 1
TIMEOUT 50

LABEL immutable
  MENU LABEL Alpine Linux (immutable root, overlaytmpfs)
  LINUX /boot/Image
  FDT /boot/dtbs/rockchip/${BOARD_DTB_NAME}
  APPEND ${CMDLINE_IMMUTABLE}

LABEL maintenance
  MENU LABEL Alpine Linux (maintenance, writable rootfs)
  LINUX /boot/Image
  FDT /boot/dtbs/rockchip/${BOARD_DTB_NAME}
  APPEND ${CMDLINE_MAINTENANCE}
EOF

BOOT_TAR="$tmp_stage/boot.tar"
MODULES_TAR="$tmp_stage/modules.tar"
tar -C "$tmp_stage" -cf "$BOOT_TAR" boot

if [ -d "$KERNEL_RELEASE_DIR/rootfs/lib/modules" ]; then
  tar -C "$KERNEL_RELEASE_DIR/rootfs" -cf "$MODULES_TAR" lib/modules
else
  tar -cf "$MODULES_TAR" --files-from /dev/null
fi

guestfish <<EOF
add-drive $IMAGE_PATH
run
part-init /dev/sda gpt
part-add /dev/sda p $P1_START $P1_END
part-add /dev/sda p $P2_START $P2_END
part-add /dev/sda p $P3_START -34
part-set-name /dev/sda 1 config
part-set-name /dev/sda 2 efi
part-set-name /dev/sda 3 $ROOTFS_PARTLABEL
part-set-gpt-type /dev/sda 1 0FC63DAF-8483-4772-8E79-3D69D8477DE4
part-set-gpt-type /dev/sda 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B
part-set-gpt-type /dev/sda 3 0FC63DAF-8483-4772-8E79-3D69D8477DE4
mkfs vfat /dev/sda1 label:config
mkfs vfat /dev/sda2 label:efi
mkfs ext4 /dev/sda3 label:$ROOTFS_MKFS_LABEL
mount /dev/sda3 /
mkdir-p /boot
mkdir-p /boot/efi
mkdir-p /config
mount /dev/sda2 /boot/efi
mount /dev/sda1 /config
tar-in $ROOTFS_TAR /
tar-in $BOOT_TAR /
tar-in $MODULES_TAR /
upload $CONFIG_FILE /config/config.txt
mkdir-p /config/cache
mkdir-p /boot/efi/extlinux
mkdir-p /boot/efi/boot/dtbs/rockchip
upload $tmp_stage/boot/extlinux/extlinux.conf /boot/efi/extlinux/extlinux.conf
upload $tmp_stage/boot/Image /boot/efi/boot/Image
upload $KERNEL_DTB /boot/efi/boot/dtbs/rockchip/${BOARD_DTB_NAME}
EOF

# Radxa E54C bootloader offsets from vendor setup script:
#   idbloader @ LBA 64 (32 KiB), u-boot.itb @ LBA 16384 (8 MiB)
dd conv=notrunc,fsync if="$UBOOT_DIR/idbloader.img" of="$IMAGE_PATH" bs=512 seek=64 status=none
dd conv=notrunc,fsync if="$UBOOT_DIR/u-boot.itb" of="$IMAGE_PATH" bs=512 seek=16384 status=none

# Match Radxa GPT partition attributes:
# attribute flags 0x4 (bit 2) set on p2 and p3.
/usr/sbin/sgdisk --attributes=2:set:2 --attributes=3:set:2 "$IMAGE_PATH" >/dev/null

echo "Image assembled: $IMAGE_PATH"
