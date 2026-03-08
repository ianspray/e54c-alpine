#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

export PATH="$PATH:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/board-config.sh"
load_board_config

GUESTFS_TMP_DEFAULT="${GUESTFS_TMP_DEFAULT:-/tmp/${BOARD}-guestfs-tmp}"
mkdir -p "$GUESTFS_TMP_DEFAULT"

export TMPDIR="${TMPDIR:-$GUESTFS_TMP_DEFAULT}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$GUESTFS_TMP_DEFAULT}"
export LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND:-direct}"
export LIBGUESTFS_TMPDIR="${LIBGUESTFS_TMPDIR:-$GUESTFS_TMP_DEFAULT}"
export LIBGUESTFS_CACHEDIR="${LIBGUESTFS_CACHEDIR:-$GUESTFS_TMP_DEFAULT}"
# Podman-on-mac often has no usable KVM in nested/containerized contexts.
# Force TCG for guestfs appliance boot stability unless caller overrides.
export LIBGUESTFS_BACKEND_SETTINGS="${LIBGUESTFS_BACKEND_SETTINGS:-force_tcg}"
export LIBGUESTFS_MEMSIZE="${LIBGUESTFS_MEMSIZE:-1024}"

IMAGE_PATH="${IMAGE_PATH:-$REPO_ROOT/build/${BOARD}-alpian-custom.img}"
IMAGE_SIZE="${IMAGE_SIZE:-8G}"
ROOTFS_TAR="${ROOTFS_TAR:-$REPO_ROOT/build/alpine-rootfs.tar}"
UBOOT_DIR="${UBOOT_DIR:-${BOARD_UBOOT_ASSETS_DIR:-$REPO_ROOT/assets/reference/u-boot}}"
CONFIG_FILE="${CONFIG_FILE:-${BOARD_CONFIG_FILE_DEFAULT:-$REPO_ROOT/assets/reference/radxa/config.txt}}"
BOOT_SCHEME="${BOOT_SCHEME:-${BOARD_BOOT_SCHEME:-rockchip-extlinux}}"
BOOTLOADER_MODE="${BOOTLOADER_MODE:-${BOARD_BOOTLOADER_MODE:-spi-dd}}"
DEFAULT_BOOT_MODE="${DEFAULT_BOOT_MODE:-immutable}"
BOARD_DTB_NAME="${BOARD_DTB_NAME:-${BOARD_DTB_NAME_DEFAULT:-rk3588s-radxa-e54c-spi.dtb}}"
BOARD_DTB_SUBDIR="${BOARD_DTB_SUBDIR:-${BOARD_DTB_SUBDIR_DEFAULT:-rockchip}}"
SERIAL_TTY="${SERIAL_TTY:-${BOARD_SERIAL_TTY:-ttyFIQ0}}"
SERIAL_BAUD="${SERIAL_BAUD:-${BOARD_SERIAL_BAUD:-1500000}}"
ROOTFS_PARTLABEL="${ROOTFS_PARTLABEL:-rootfs}"
ROOTFS_MKFS_LABEL="${ROOTFS_MKFS_LABEL:-$ROOTFS_PARTLABEL}"
ENABLE_INITRAMFS_BOOT="${ENABLE_INITRAMFS_BOOT:-1}"
INITRAMFS_NAME="${INITRAMFS_NAME:-initramfs-${BOARD}.cpio.gz}"
SINGLE_BOOT_LABEL="${SINGLE_BOOT_LABEL:-immutable}"
CONFIG_PART_GPT_TYPE="${CONFIG_PART_GPT_TYPE:-0FC63DAF-8483-4772-8E79-3D69D8477DE4}"
BOOTCFG_PART_GPT_TYPE="${BOOTCFG_PART_GPT_TYPE:-C12A7328-F81F-11D2-BA4B-00A0C93EC93B}"
BOOTABLE_GPT_PARTITIONS="${BOOTABLE_GPT_PARTITIONS:-${BOARD_BOOTABLE_GPT_PARTITIONS_DEFAULT:-2 3}}"
SPI_IDBLOADER_LBA="${SPI_IDBLOADER_LBA:-${BOARD_SPI_IDBLOADER_LBA_DEFAULT:-64}}"
SPI_UBOOT_ITB_LBA="${SPI_UBOOT_ITB_LBA:-${BOARD_SPI_UBOOT_ITB_LBA_DEFAULT:-16384}}"
DISKLESS_TMPFS_MARGIN_MIB="${DISKLESS_TMPFS_MARGIN_MIB:-200}"
DISKLESS_TMPFS_SIZE_MIB="${DISKLESS_TMPFS_SIZE_MIB:-}"

# Partition geometry (512-byte sectors):
# - p1 config: 256 MiB (starts at 16 MiB)
# - p2 bootcfg: 300 MiB
# - p3 rootfs: remainder
P1_START=32768
P1_SIZE_SECTORS=$((256 * 1024 * 1024 / 512))
P1_END=$((P1_START + P1_SIZE_SECTORS - 1))
P2_START=$((P1_END + 1))
P2_SIZE_SECTORS=$((300 * 1024 * 1024 / 512))
P2_END=$((P2_START + P2_SIZE_SECTORS - 1))
P3_START=$((P2_END + 1))

if [ -z "${KERNEL_RELEASE_DIR:-}" ]; then
  current_kernel_file="$REPO_ROOT/build/kernel-artifacts/current-$BOARD"
  if [ -f "$current_kernel_file" ]; then
    KERNEL_RELEASE_DIR="$(cat "$current_kernel_file")"
  else
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
fi

if [ -z "$KERNEL_RELEASE_DIR" ] || [ ! -d "$KERNEL_RELEASE_DIR" ]; then
  echo "KERNEL_RELEASE_DIR is not set and no kernel artifacts were found." >&2
  exit 1
fi

required_inputs=("$ROOTFS_TAR" "$KERNEL_RELEASE_DIR/boot/Image")
if [ "$BOOTLOADER_MODE" = "spi-dd" ]; then
  required_inputs+=("$UBOOT_DIR/idbloader.img" "$UBOOT_DIR/u-boot.itb")
fi
for req in "${required_inputs[@]}"; do
  if [ ! -e "$req" ]; then
    echo "Missing required input: $req" >&2
    exit 1
  fi
done

file_size_bytes() {
  local file="$1"
  stat -c%s "$file" 2>/dev/null || stat -f%z "$file"
}

if [ -z "$DISKLESS_TMPFS_SIZE_MIB" ]; then
  rootfs_tar_bytes="$(file_size_bytes "$ROOTFS_TAR")"
  if [ -z "$rootfs_tar_bytes" ] || [ "$rootfs_tar_bytes" -le 0 ] 2>/dev/null; then
    echo "Unable to determine size for ROOTFS_TAR: $ROOTFS_TAR" >&2
    exit 1
  fi
  rootfs_tar_mib=$(((rootfs_tar_bytes + 1024 * 1024 - 1) / (1024 * 1024)))
  DISKLESS_TMPFS_SIZE_MIB=$((rootfs_tar_mib + DISKLESS_TMPFS_MARGIN_MIB))
fi

if ! [[ "$DISKLESS_TMPFS_SIZE_MIB" =~ ^[0-9]+$ ]] || [ "$DISKLESS_TMPFS_SIZE_MIB" -lt 1 ]; then
  echo "Invalid DISKLESS_TMPFS_SIZE_MIB value: $DISKLESS_TMPFS_SIZE_MIB" >&2
  exit 1
fi

# libguestfs/supermin requires a host kernel + modules available in the
# build environment to construct its appliance.
if ! ls /boot/vmlinuz* >/dev/null 2>&1 || ! ls -d /lib/modules/* >/dev/null 2>&1; then
  echo "Missing host kernel artifacts required by libguestfs/supermin." >&2
  echo "Expected: /boot/vmlinuz* and /lib/modules/*" >&2
  echo "In the builder container, install a kernel package (e.g. linux-image-arm64)." >&2
  echo "If you just updated Dockerfile.builder, rebuild with --rebuild-image." >&2
  exit 1
fi

KERNEL_DTB="$KERNEL_RELEASE_DIR/boot/dtbs/$BOARD_DTB_SUBDIR/$BOARD_DTB_NAME"
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
  mkdir -p "$initramfs_root/bin" "$initramfs_root/sbin" "$initramfs_root/lib" "$initramfs_root/proc" \
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
  # Add common applet entrypoints so emergency shell is usable.
  for applet in \
    ls cat dmesg grep awk sed mount umount mkdir mknod sleep echo \
    find head tail cut tr sort uniq wc printf test; do
    ln -snf busybox "$initramfs_root/bin/$applet"
  done
  ln -snf ../bin/busybox "$initramfs_root/sbin/mdev"

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
diskless_tmpfs_size_mib=""
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
    diskless_tmpfs_size=*) diskless_tmpfs_size_mib="\${arg#diskless_tmpfs_size=}" ;;
    rootwait) : ;;
    rootwait=*) root_wait_timeout="\${arg#rootwait=}" ;;
    rootdelay=*) root_delay="\${arg#rootdelay=}" ;;
  esac
done

[ -n "\$root_spec" ] || panic "Missing root= kernel argument."
if [ -n "\$diskless_tmpfs_size_mib" ] && ! \$BB echo "\$diskless_tmpfs_size_mib" | \$BB grep -Eq '^[0-9]+$'; then
  panic "Invalid diskless_tmpfs_size value: \$diskless_tmpfs_size_mib"
fi

\$BB mount -t sysfs sysfs /sys
\$BB mount -t devtmpfs devtmpfs /dev
\$BB mkdir -p /dev/pts /dev/shm

log "cmdline root=\$root_spec rootfstype=\$root_fstype diskless=\$diskless_mode overlay=\$overlay_mode tmpfs_size=\${diskless_tmpfs_size_mib:-auto}"

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
    log "resolved root device: \$root_dev"
    break
  fi

  if [ "\$root_wait_forever" -eq 0 ] && [ "\$elapsed" -ge "\$root_wait_timeout" ]; then
    panic "Root device not found: \$root_spec"
  fi

  elapsed=\$((elapsed + 1))
  \$BB sleep 1
done

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
    log "mounting source root read-only"
    \$BB mkdir -p /media/rootsrc
    if ! \$BB mount -o ro -t "\$root_fstype" "\$root_dev" /media/rootsrc 2>/dev/null; then
      \$BB mount -o ro "\$root_dev" /media/rootsrc
    fi
    tmpfs_opts="mode=0755"
    if [ -n "\$diskless_tmpfs_size_mib" ] && [ "\$diskless_tmpfs_size_mib" -gt 0 ]; then
      tmpfs_opts="\${tmpfs_opts},size=\${diskless_tmpfs_size_mib}m"
    fi
    log "mounting diskless tmpfs: \$tmpfs_opts"
    \$BB mount -t tmpfs -o "\$tmpfs_opts" tmpfs /newroot
    log "copying rootfs into tmpfs"
    (cd /media/rootsrc && \$BB tar -cf - .) | (cd /newroot && \$BB tar -xf -)
    log "rootfs copy complete"
    \$BB mkdir -p /newroot/.diskless-source
    \$BB mount --move /media/rootsrc /newroot/.diskless-source
  else
    log "mounting writable root"
    mount_root rw
  fi
fi

\$BB mkdir -p /newroot/proc /newroot/sys /newroot/dev
\$BB mount --move /proc /newroot/proc
\$BB mount --move /sys /newroot/sys
\$BB mount --move /dev /newroot/dev

log "switch_root to /sbin/init"
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
CMDLINE_BASE_DEFAULT="${BOARD_KERNEL_CMDLINE_BASE_DEFAULT:-root=PARTLABEL=${ROOTFS_PARTLABEL} rootfstype=ext4 rootwait=30 console=${SERIAL_TTY},${SERIAL_BAUD}n8 nvme_core.default_ps_max_latency_us=0 pcie_aspm=off}"
CMDLINE_BASE="${KERNEL_CMDLINE_BASE:-$CMDLINE_BASE_DEFAULT}"
CMDLINE_IMMUTABLE_DEFAULT="${CMDLINE_BASE} ro diskless=yes diskless_tmpfs_size=${DISKLESS_TMPFS_SIZE_MIB}"
CMDLINE_MAINTENANCE_DEFAULT="${CMDLINE_BASE} rw"
CMDLINE_IMMUTABLE="${KERNEL_CMDLINE_IMMUTABLE:-${KERNEL_CMDLINE:-$CMDLINE_IMMUTABLE_DEFAULT}}"
CMDLINE_MAINTENANCE="${KERNEL_CMDLINE_MAINTENANCE:-$CMDLINE_MAINTENANCE_DEFAULT}"
INITRD_LINE=""
if [ "$ENABLE_INITRAMFS_BOOT" = "1" ]; then
  INITRD_LINE="  INITRD /boot/${INITRAMFS_NAME}"
fi

DEFAULT_EXTLINUX_LABEL="$SINGLE_BOOT_LABEL"
BOOT_TAR="$tmp_stage/boot.tar"
RPI_BOOT_TAR="$tmp_stage/rpi-boot.tar"
MODULES_TAR="$tmp_stage/modules.tar"

case "$BOOT_SCHEME" in
  rockchip-extlinux)
    cat >"$tmp_stage/boot/extlinux/extlinux.conf" <<EOF
DEFAULT ${DEFAULT_EXTLINUX_LABEL}
MENU TITLE U-Boot menu
PROMPT 0
TIMEOUT 50

LABEL immutable
  MENU LABEL Alpine Linux (diskless)
  LINUX /boot/Image
  FDT /boot/dtbs/${BOARD_DTB_SUBDIR}/${BOARD_DTB_NAME}
${INITRD_LINE}
  APPEND ${CMDLINE_IMMUTABLE}
EOF
    tar -C "$tmp_stage" -cf "$BOOT_TAR" boot
    ;;
  rpi-firmware)
    firmware_dir="$KERNEL_RELEASE_DIR/boot/firmware"
    if [ ! -d "$firmware_dir" ]; then
      echo "Missing required Raspberry Pi firmware directory: $firmware_dir" >&2
      exit 1
    fi

    rpi_boot_dir="$tmp_stage/rpi-boot"
    mkdir -p "$rpi_boot_dir/dtbs/$BOARD_DTB_SUBDIR"
    cp -a "$firmware_dir"/. "$rpi_boot_dir/"
    cp "$tmp_stage/boot/Image" "$rpi_boot_dir/Image"
    cp "$KERNEL_DTB" "$rpi_boot_dir/dtbs/$BOARD_DTB_SUBDIR/$BOARD_DTB_NAME"

    if [ "$ENABLE_INITRAMFS_BOOT" = "1" ]; then
      cp "$tmp_stage/boot/$INITRAMFS_NAME" "$rpi_boot_dir/$INITRAMFS_NAME"
    fi

    if [ -f "$CONFIG_FILE" ]; then
      cp "$CONFIG_FILE" "$rpi_boot_dir/config.txt"
    else
      : >"$rpi_boot_dir/config.txt"
    fi

    if ! grep -Eq '^[[:space:]]*kernel=' "$rpi_boot_dir/config.txt"; then
      printf '%s\n' "kernel=Image" >>"$rpi_boot_dir/config.txt"
    fi
    if ! grep -Eq '^[[:space:]]*device_tree=' "$rpi_boot_dir/config.txt"; then
      printf '%s\n' "device_tree=dtbs/${BOARD_DTB_SUBDIR}/${BOARD_DTB_NAME}" >>"$rpi_boot_dir/config.txt"
    fi
    if [ "$ENABLE_INITRAMFS_BOOT" = "1" ] && ! grep -Eq "^[[:space:]]*initramfs[[:space:]]+${INITRAMFS_NAME}[[:space:]]+followkernel" "$rpi_boot_dir/config.txt"; then
      printf '%s\n' "initramfs ${INITRAMFS_NAME} followkernel" >>"$rpi_boot_dir/config.txt"
    fi

    printf '%s\n' "$CMDLINE_IMMUTABLE" >"$rpi_boot_dir/cmdline.txt"
    tar -C "$rpi_boot_dir" -cf "$RPI_BOOT_TAR" .
    ;;
  *)
    echo "Unsupported BOOT_SCHEME: $BOOT_SCHEME" >&2
    echo "Supported values: rockchip-extlinux, rpi-firmware" >&2
    exit 1
    ;;
esac

if [ -d "$KERNEL_RELEASE_DIR/rootfs/lib/modules" ]; then
  tar -C "$KERNEL_RELEASE_DIR/rootfs" -cf "$MODULES_TAR" lib/modules
elif [ -f "$KERNEL_RELEASE_DIR/modules-rootfs.tar" ]; then
  cp "$KERNEL_RELEASE_DIR/modules-rootfs.tar" "$MODULES_TAR"
else
  tar -cf "$MODULES_TAR" --files-from /dev/null
fi

case "$BOOT_SCHEME" in
  rockchip-extlinux)
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
part-set-gpt-type /dev/sda 1 $CONFIG_PART_GPT_TYPE
part-set-gpt-type /dev/sda 2 $BOOTCFG_PART_GPT_TYPE
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
mkdir-p /boot/efi/boot/dtbs/${BOARD_DTB_SUBDIR}
upload $tmp_stage/boot/extlinux/extlinux.conf /boot/efi/extlinux/extlinux.conf
upload $tmp_stage/boot/Image /boot/efi/boot/Image
upload $KERNEL_DTB /boot/efi/boot/dtbs/${BOARD_DTB_SUBDIR}/${BOARD_DTB_NAME}
EOF

    if [ "$ENABLE_INITRAMFS_BOOT" = "1" ]; then
guestfish <<EOF
add-drive $IMAGE_PATH
run
mount /dev/sda2 /
upload $tmp_stage/boot/$INITRAMFS_NAME /boot/$INITRAMFS_NAME
EOF
    fi
    ;;
  rpi-firmware)
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
part-set-gpt-type /dev/sda 1 $BOOTCFG_PART_GPT_TYPE
part-set-gpt-type /dev/sda 2 $CONFIG_PART_GPT_TYPE
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
tar-in $MODULES_TAR /
tar-in $RPI_BOOT_TAR /config
mkdir-p /config/cache
EOF
    ;;
esac

if [ "$BOOTLOADER_MODE" = "spi-dd" ]; then
  # Rockchip bootloader offsets from vendor setup script defaults.
  dd conv=notrunc,fsync if="$UBOOT_DIR/idbloader.img" of="$IMAGE_PATH" bs=512 seek="$SPI_IDBLOADER_LBA" status=none
  dd conv=notrunc,fsync if="$UBOOT_DIR/u-boot.itb" of="$IMAGE_PATH" bs=512 seek="$SPI_UBOOT_ITB_LBA" status=none
fi

if [ "$BOOT_SCHEME" = "rockchip-extlinux" ]; then
  # Some vendor U-Boot builds only scan GPT entries with the legacy BIOS
  # bootable attribute set. Keep that list board-configurable.
  for partno in 1 2 3; do
    /usr/sbin/sgdisk --attributes="${partno}:clear:2" "$IMAGE_PATH" >/dev/null
  done
  for partno in $BOOTABLE_GPT_PARTITIONS; do
    /usr/sbin/sgdisk --attributes="${partno}:set:2" "$IMAGE_PATH" >/dev/null
  done
fi

echo "Image assembled: $IMAGE_PATH"
