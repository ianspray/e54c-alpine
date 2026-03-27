#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

EFI_MOUNT="/boot/efi"
CONFIG_MOUNT="/media/config"
EXTLINUX_CONF="$EFI_MOUNT/extlinux/extlinux.conf"
NEXT_FILE="$CONFIG_MOUNT/boot-mode.next"

[ -f "$NEXT_FILE" ] || exit 0
[ -f "$EXTLINUX_CONF" ] || exit 0

if [ "$(cat "$NEXT_FILE" 2>/dev/null || true)" != "maintenance-once" ]; then
  exit 0
fi

if grep -qw 'overlaytmpfs=yes' /proc/cmdline; then
  exit 0
fi

mountpoint -q "$CONFIG_MOUNT" || exit 0
mountpoint -q "$EFI_MOUNT" || exit 0

mount -o remount,rw "$CONFIG_MOUNT" || exit 0
if ! mount -o remount,rw "$EFI_MOUNT"; then
  mount -o remount,ro "$CONFIG_MOUNT" || true
  exit 0
fi

tmp="$(mktemp -p /var/tmp)"
awk '
  BEGIN { done=0 }
  /^[[:space:]]*DEFAULT[[:space:]]+/ && done==0 {
    print "DEFAULT immutable"
    done=1
    next
  }
  { print }
  END {
    if (done==0) exit 2
  }
' "$EXTLINUX_CONF" >"$tmp"
cat "$tmp" >"$EXTLINUX_CONF"
rm -f "$tmp"
rm -f "$NEXT_FILE"
sync

mount -o remount,ro "$EFI_MOUNT" || true
mount -o remount,ro "$CONFIG_MOUNT" || true
