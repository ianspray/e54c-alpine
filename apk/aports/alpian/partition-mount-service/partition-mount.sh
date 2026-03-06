#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

CONF_FILE="/etc/conf.d/partition-mount"
[ -f "$CONF_FILE" ] || exit 0

read_conf_value() {
  awk -F= -v key="$1" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      value = $2
      sub(/^[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      gsub(/"/, "", value)
      print value
      exit
    }
  ' "$CONF_FILE" 2>/dev/null || true
}

join_path() {
  case "$1" in
    ""|/)
      printf '/%s\n' "$2"
      ;;
    *)
      printf '%s/%s\n' "${1%/}" "$2"
      ;;
  esac
}

check_hardware_path="$(read_conf_value check_hardware_path)"
mount_point_root="$(read_conf_value mount_point_root)"
work_mount_point="$(read_conf_value work_mount_point)"

[ -n "$check_hardware_path" ] || exit 0
[ -n "$mount_point_root" ] || exit 0
[ -n "$work_mount_point" ] || exit 0

mkdir -p "$work_mount_point"

# Fetch unmounted, non-swap partitions that belong to the requested device.
to_be_mounted="$(lsblk -pnr -o PATH -Q 'TYPE=="part" && MOUNTPOINT!~".+" && FSTYPE!~"swap"' -- "$check_hardware_path" 2>/dev/null || true)"

# Nothing to do when no matching partitions exist.
[ -n "$to_be_mounted" ] || exit 0

# Mount each labeled partition read-only and present it through an overlay
# whose upper/work directories live in tmpfs-backed ramdisk storage.
printf '%s\n' "${to_be_mounted}" | while IFS= read -r part; do
  [ -n "$part" ] || continue

  label="$(blkid -o value -s LABEL "$part" 2>/dev/null || true)"
  [ -n "$label" ] || continue

  case "$label" in
    "."|".."|*/*)
      printf 'partition-mount: skipping %s with unsupported label %s\n' "$part" "$label" >&2
      continue
      ;;
  esac

  target="$(join_path "$mount_point_root" "$label")"
  part_name="${part##*/}"
  lowerdir="$(join_path "$work_mount_point" ".partition-mount-${part_name}-lower")"
  upperdir="$(join_path "$work_mount_point" ".partition-mount-${part_name}-upper")"
  workdir="$(join_path "$work_mount_point" ".partition-mount-${part_name}-work")"

  if findmnt -rn -M "$target" >/dev/null 2>&1; then
    continue
  fi

  mkdir -p "$target" "$lowerdir" "$upperdir" "$workdir"

  if ! mount -o ro -- "$part" "$lowerdir"; then
    printf 'partition-mount: failed to mount %s read-only at %s\n' "$part" "$lowerdir" >&2
    continue
  fi

  if ! mount -t overlay overlay -o "lowerdir=$lowerdir,upperdir=$upperdir,workdir=$workdir" -- "$target"; then
    printf 'partition-mount: failed to mount overlay for %s at %s\n' "$part" "$target" >&2
    umount "$lowerdir" >/dev/null 2>&1 || true
  fi
done
