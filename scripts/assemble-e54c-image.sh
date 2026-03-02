#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

export PATH="$PATH:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GUESTFS_TMP_DEFAULT="${REPO_ROOT}/build/guestfs-tmp"
mkdir -p "$GUESTFS_TMP_DEFAULT"

export TMPDIR="${TMPDIR:-$GUESTFS_TMP_DEFAULT}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$GUESTFS_TMP_DEFAULT}"
export LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND:-direct}"
export LIBGUESTFS_TMPDIR="${LIBGUESTFS_TMPDIR:-$GUESTFS_TMP_DEFAULT}"
export LIBGUESTFS_CACHEDIR="${LIBGUESTFS_CACHEDIR:-$GUESTFS_TMP_DEFAULT}"

IMAGE_PATH="${IMAGE_PATH:-$REPO_ROOT/build/e54c-alpine-custom.img}"
IMAGE_SIZE="${IMAGE_SIZE:-8G}"
ROOTFS_TAR="${ROOTFS_TAR:-$REPO_ROOT/build/alpine-rootfs.tar}"
UBOOT_DIR="${UBOOT_DIR:-$REPO_ROOT/assets/reference/u-boot}"
CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/assets/reference/radxa/config.txt}"
DEFAULT_BOOT_MODE="${DEFAULT_BOOT_MODE:-immutable}"
BOARD_DTB_NAME="${BOARD_DTB_NAME:-rk3588s-radxa-e54c-spi.dtb}"
ROOTFS_PARTLABEL="${ROOTFS_PARTLABEL:-rootfs}"
ROOTFS_MKFS_LABEL="${ROOTFS_MKFS_LABEL:-$ROOTFS_PARTLABEL}"
ENABLE_INITRAMFS_BOOT="${ENABLE_INITRAMFS_BOOT:-1}"
INITRAMFS_NAME="${INITRAMFS_NAME:-initramfs-e54c.cpio.gz}"
SINGLE_BOOT_LABEL="${SINGLE_BOOT_LABEL:-immutable}"

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
  latest_release=""
  latest_mtime=0
  for candidate in "$REPO_ROOT"/build/kernel-artifacts/*; do
    [ -d "$candidate" ] || continue
    candidate_mtime="$(stat -c %Y "$candidate" 2>/dev/null || echo 0)"
    if [ -z "$latest_release" ] || [ "$candidate_mtime" -gt "$latest_mtime" ]; then
      latest_release="$candidate"
      latest_mtime="$candidate_mtime"
    fi
  done
  KERNEL_RELEASE_DIR="$latest_release"
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

if [ "$ENABLE_INITRAMFS_BOOT" = "1" ]; then
  initramfs_root="$tmp_stage/initramfs"
  mkdir -p "$initramfs_root/bin" "$initramfs_root/lib" "$initramfs_root/proc" \
    "$initramfs_root/sys" "$initramfs_root/dev" "$initramfs_root/newroot" "$initramfs_root/ovl"

  rootfs_tar_list="$tmp_stage/rootfs-tar.list"
  tar -tf "$ROOTFS_TAR" >"$rootfs_tar_list"
  ld_musl_entry="$(awk '/^\.\/lib\/ld-musl-.*\.so\.1$/ {print; exit}' "$rootfs_tar_list")"
  libc_musl_entry="$(awk '/^\.\/lib\/libc\.musl-.*\.so\.1$/ {print; exit}' "$rootfs_tar_list")"

  if [ -z "$ld_musl_entry" ] || [ -z "$libc_musl_entry" ]; then
    echo "Unable to locate musl runtime libraries in $ROOTFS_TAR" >&2
    exit 1
  fi

  tar -xf "$ROOTFS_TAR" -C "$initramfs_root" ./bin/busybox "$ld_musl_entry" "$libc_musl_entry"
  ln -snf busybox "$initramfs_root/bin/sh"

  kernel_release="$(basename "$KERNEL_RELEASE_DIR")"
  overlay_module="$KERNEL_RELEASE_DIR/rootfs/lib/modules/$kernel_release/kernel/fs/overlayfs/overlay.ko"
  if [ -f "$overlay_module" ]; then
    overlay_rel="lib/modules/$kernel_release/kernel/fs/overlayfs/overlay.ko"
    mkdir -p "$initramfs_root/$(dirname "$overlay_rel")"
    cp "$overlay_module" "$initramfs_root/$overlay_rel"
  fi

  cat >"$initramfs_root/init" <<EOF
#!/bin/busybox sh
set -eu

BB=/bin/busybox
PATH=/bin:/sbin

log() {
  echo "[initramfs] \$*" >/dev/console 2>/dev/null || echo "[initramfs] \$*"
}

panic() {
  log "ERROR: \$*"
  exec /bin/busybox sh
}

root_spec=""
root_fstype="ext4"
overlay_mode="no"
diskless_mode="no"
root_wait_forever=0
root_wait_timeout=30
root_delay=0

\$BB mount -t proc proc /proc
CMDLINE="\$("\$BB" cat /proc/cmdline 2>/dev/null || true)"

for arg in \$CMDLINE; do
  case "\$arg" in
    root=*) root_spec="\${arg#root=}" ;;
    rootfstype=*) root_fstype="\${arg#rootfstype=}" ;;
    overlaytmpfs=*) overlay_mode="\${arg#overlaytmpfs=}" ;;
    diskless=*) diskless_mode="\${arg#diskless=}" ;;
    rootwait) root_wait_forever=1 ;;
    rootwait=*) root_wait_timeout="\${arg#rootwait=}" ;;
    rootdelay=*) root_delay="\${arg#rootdelay=}" ;;
  esac
done

[ -n "\$root_spec" ] || panic "Missing root= kernel argument."

\$BB mount -t sysfs sysfs /sys
\$BB mount -t devtmpfs devtmpfs /dev
\$BB mkdir -p /dev/pts /dev/shm

if [ "\$root_delay" -gt 0 ] 2>/dev/null; then
  \$BB sleep "\$root_delay"
fi

resolve_block_device() {
  spec="\$1"
  dev=""

  ensure_node() {
    name="\$1"
    node="/dev/\$name"
    [ -b "\$node" ] && { echo "\$node"; return 0; }
    if [ -r "/sys/class/block/\$name/dev" ]; then
      IFS=: read -r major minor <"/sys/class/block/\$name/dev" || true
      if [ -n "\${major:-}" ] && [ -n "\${minor:-}" ]; then
        \$BB mknod "\$node" b "\$major" "\$minor" 2>/dev/null || true
      fi
    fi
    [ -b "\$node" ] && { echo "\$node"; return 0; }
    return 1
  }

  case "\$spec" in
    /dev/*)
      [ -b "\$spec" ] && { echo "\$spec"; return 0; }
      echo "\$spec"
      return 0
      ;;
    PARTLABEL=*)
      want="\${spec#PARTLABEL=}"
      for uevent in /sys/class/block/*/uevent; do
        [ -f "\$uevent" ] || continue
        partname=""
        while IFS= read -r line; do
          case "\$line" in
            PARTNAME=*) partname="\${line#PARTNAME=}" ;;
          esac
        done <"\$uevent"
        if [ "\$partname" = "\$want" ]; then
          name="\${uevent#/sys/class/block/}"
          name="\${name%/uevent}"
          ensure_node "\$name" && return 0
        fi
      done
      ;;
    PARTUUID=*)
      want="\${spec#PARTUUID=}"
      for uevent in /sys/class/block/*/uevent; do
        [ -f "\$uevent" ] || continue
        partuuid=""
        while IFS= read -r line; do
          case "\$line" in
            PARTUUID=*) partuuid="\${line#PARTUUID=}" ;;
          esac
        done <"\$uevent"
        if [ "\$partuuid" = "\$want" ]; then
          name="\${uevent#/sys/class/block/}"
          name="\${name%/uevent}"
          ensure_node "\$name" && return 0
        fi
      done
      ;;
  esac

  return 1
}

root_dev=""
elapsed=0
while :; do
  root_dev="\$(resolve_block_device "\$root_spec" || true)"
  if [ -n "\$root_dev" ] && [ -b "\$root_dev" ]; then
    break
  fi

  if [ "\$root_wait_forever" -eq 0 ] && [ "\$elapsed" -ge "\$root_wait_timeout" ]; then
    panic "Root device not found: \$root_spec"
  fi

  elapsed=\$((elapsed + 1))
  \$BB sleep 1
done

log "Root device: \$root_dev"

mount_root() {
  mode="\$1"
  if ! \$BB mount -o "\$mode" -t "\$root_fstype" "\$root_dev" /newroot 2>/dev/null; then
    \$BB mount -o "\$mode" "\$root_dev" /newroot
  fi
}

if [ "\$overlay_mode" = "yes" ] || [ "\$overlay_mode" = "1" ]; then
  if ! \$BB grep -Eq '(^|[[:space:]])overlay$' /proc/filesystems; then
    if [ -f "/lib/modules/${kernel_release}/kernel/fs/overlayfs/overlay.ko" ]; then
      \$BB insmod "/lib/modules/${kernel_release}/kernel/fs/overlayfs/overlay.ko" 2>/dev/null || true
    fi
  fi

  if ! \$BB grep -Eq '(^|[[:space:]])overlay$' /proc/filesystems; then
    panic "overlayfs support is unavailable in kernel/initramfs."
  fi

  \$BB mount -t tmpfs -o mode=0755 tmpfs /ovl
  \$BB mkdir -p /ovl/lower /ovl/upper /ovl/work
  if ! \$BB mount -o ro -t "\$root_fstype" "\$root_dev" /ovl/lower 2>/dev/null; then
    \$BB mount -o ro "\$root_dev" /ovl/lower
  fi
  \$BB mount -t overlay overlay -o lowerdir=/ovl/lower,upperdir=/ovl/upper,workdir=/ovl/work /newroot
  \$BB mkdir -p /newroot/.overlay
  \$BB mount --move /ovl /newroot/.overlay
else
  if [ "\$diskless_mode" = "yes" ] || [ "\$diskless_mode" = "1" ]; then
    \$BB mkdir -p /media/rootsrc
    if ! \$BB mount -o ro -t "\$root_fstype" "\$root_dev" /media/rootsrc 2>/dev/null; then
      \$BB mount -o ro "\$root_dev" /media/rootsrc
    fi
    \$BB mount -t tmpfs -o mode=0755 tmpfs /newroot
    (cd /media/rootsrc && \$BB tar -cf - .) | (cd /newroot && \$BB tar -xf -)
    \$BB mkdir -p /newroot/.diskless-source
    \$BB mount --move /media/rootsrc /newroot/.diskless-source
  else
    mount_root rw
  fi
fi

\$BB mkdir -p /newroot/proc /newroot/sys /newroot/dev
\$BB mount --move /proc /newroot/proc
\$BB mount --move /sys /newroot/sys
\$BB mount --move /dev /newroot/dev

exec \$BB switch_root /newroot /sbin/init
EOF
  chmod 0755 "$initramfs_root/init"

  (
    cd "$initramfs_root"
    find . -print0 | cpio --null -o -H newc --owner 0:0 2>/dev/null | gzip -9 >"$tmp_stage/boot/$INITRAMFS_NAME"
  )
fi

# Keep bootargs intentionally short and put root first.
# Some U-Boot extlinux paths appear to truncate long APPEND lines.
CMDLINE_BASE_DEFAULT="root=PARTLABEL=${ROOTFS_PARTLABEL} rootfstype=ext4 rootwait console=ttyFIQ0,1500000n8 earlycon nvme_core.default_ps_max_latency_us=0 pcie_aspm=off"
CMDLINE_BASE="${KERNEL_CMDLINE_BASE:-$CMDLINE_BASE_DEFAULT}"
CMDLINE_IMMUTABLE_DEFAULT="${CMDLINE_BASE} ro diskless=yes"
CMDLINE_MAINTENANCE_DEFAULT="${CMDLINE_BASE} rw"
CMDLINE_IMMUTABLE="${KERNEL_CMDLINE_IMMUTABLE:-${KERNEL_CMDLINE:-$CMDLINE_IMMUTABLE_DEFAULT}}"
CMDLINE_MAINTENANCE="${KERNEL_CMDLINE_MAINTENANCE:-$CMDLINE_MAINTENANCE_DEFAULT}"
INITRD_LINE=""
if [ "$ENABLE_INITRAMFS_BOOT" = "1" ]; then
  INITRD_LINE="  INITRD /boot/${INITRAMFS_NAME}"
fi

DEFAULT_EXTLINUX_LABEL="$SINGLE_BOOT_LABEL"

cat >"$tmp_stage/boot/extlinux/extlinux.conf" <<EOF
DEFAULT ${DEFAULT_EXTLINUX_LABEL}
MENU TITLE U-Boot menu
PROMPT 1
TIMEOUT 50

LABEL immutable
  MENU LABEL Alpine Linux (diskless)
  LINUX /boot/Image
  FDT /boot/dtbs/rockchip/${BOARD_DTB_NAME}
${INITRD_LINE}
  APPEND ${CMDLINE_IMMUTABLE}
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

if [ "$ENABLE_INITRAMFS_BOOT" = "1" ]; then
guestfish <<EOF
add-drive $IMAGE_PATH
run
mount /dev/sda2 /
upload $tmp_stage/boot/$INITRAMFS_NAME /boot/$INITRAMFS_NAME
EOF
fi

# Radxa E54C bootloader offsets from vendor setup script:
#   idbloader @ LBA 64 (32 KiB), u-boot.itb @ LBA 16384 (8 MiB)
dd conv=notrunc,fsync if="$UBOOT_DIR/idbloader.img" of="$IMAGE_PATH" bs=512 seek=64 status=none
dd conv=notrunc,fsync if="$UBOOT_DIR/u-boot.itb" of="$IMAGE_PATH" bs=512 seek=16384 status=none

# Match Radxa GPT partition attributes:
# attribute flags 0x4 (bit 2) set on p2 and p3.
/usr/sbin/sgdisk --attributes=2:set:2 --attributes=3:set:2 "$IMAGE_PATH" >/dev/null

echo "Image assembled: $IMAGE_PATH"
