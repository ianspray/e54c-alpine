#!/bin/sh
set -eu

CONF_FILE="/etc/conf.d/e54c-partition-mount"
[ -f "$CONF_FILE" ] || exit 0

check_hardware_path="$(awk -F= '/^[[:space:]]*check_hardware_path[[:space:]]*=/{gsub(/[[:space:]]|"/,"",$2); print $2; exit}' "$CONF_FILE" 2>/dev/null || true)"

mount_point_root="$(awk -F= '/^[[:space:]]*mount_point_root[[:space:]]*=/{gsub(/[[:space:]]|"/,"",$2); print $2; exit}' "$CONF_FILE" 2>/dev/null || true)"

mount_options="$(awk -F= '/^[[:space:]]*mount_options[[:space:]]*=/{gsub(/[[:space:]]|"/,"",$2); print $2; exit}' "$CONF_FILE" 2>/dev/null || true)"

# fetch a space separated two column list of the device mountpoint
# and the filesystem label name for all unmounted partitions on the
# hardware interface requested that have a non-empty LABEL
to_be_mounted="$(lsblk -rn -o PATH,LABEL -Q 'TYPE=="part" && MOUNTPOINT!~".+" && LABEL=~".+" && FSTYPE!~"swap"' $check_hardware_path 2>/dev/null || true)"

# mount all the unmounted partitions with the name of the label
# at the starting offset supplied in the config file
printf '%s\n' "${to_be_mounted}" | while IFS=' ' read -r part label; do
  # ensure only one `/` separator in the path via parameter expansion
  mkdir -p "${mount_point_root%/}/${label}"
  mount -o "${mount_options}" "${part}" "${mount_point_root%/}/${label}"
done
