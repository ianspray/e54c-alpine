#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

EFI_MOUNT="/boot/efi"
CONFIG_MOUNT="/media/config"
EXTLINUX_CONF="$EFI_MOUNT/extlinux/extlinux.conf"
NEXT_FILE="$CONFIG_MOUNT/boot-mode.next"

usage() {
  cat <<'USAGE'
Usage:
  rock3b-boot-mode status
  rock3b-boot-mode next-maintenance
  rock3b-boot-mode cancel-next
  rock3b-boot-mode set-default immutable|maintenance
  rock3b-boot-mode reboot-maintenance
  rock3b-boot-mode reboot-immutable
USAGE
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This command must run as root." >&2
    exit 1
  fi
}

ensure_mounts() {
  mountpoint -q "$EFI_MOUNT" || mount "$EFI_MOUNT"
  mountpoint -q "$CONFIG_MOUNT" || mount "$CONFIG_MOUNT"
}

set_default_label() {
  label="$1"
  tmp="$(mktemp)"
  awk -v lbl="$label" '
    BEGIN { done=0 }
    /^[[:space:]]*DEFAULT[[:space:]]+/ && done==0 {
      print "DEFAULT " lbl
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
}

get_default_label() {
  awk '/^[[:space:]]*DEFAULT[[:space:]]+/ {print $2; exit}' "$EXTLINUX_CONF"
}

get_next_mode() {
  if [ -f "$NEXT_FILE" ]; then
    cat "$NEXT_FILE"
  else
    echo "none"
  fi
}

current_mode() {
  if grep -qw 'diskless=yes' /proc/cmdline; then
    echo "diskless"
  elif grep -qw 'overlaytmpfs=yes' /proc/cmdline; then
    echo "immutable"
  else
    echo "maintenance"
  fi
}

set_ro_mounts() {
  mount -o remount,ro "$EFI_MOUNT" || true
  mount -o remount,ro "$CONFIG_MOUNT" || true
}

set_rw_mounts() {
  mount -o remount,rw "$CONFIG_MOUNT"
  mount -o remount,rw "$EFI_MOUNT"
}

cmd="${1:-status}"
case "$cmd" in
  status)
    ensure_mounts
    echo "Current mode: $(current_mode)"
    echo "Default next-boot label: $(get_default_label)"
    echo "One-shot next mode: $(get_next_mode)"
    ;;
  next-maintenance)
    require_root
    ensure_mounts
    set_rw_mounts
    echo "maintenance-once" >"$NEXT_FILE"
    set_default_label maintenance
    sync
    set_ro_mounts
    echo "Scheduled one-shot maintenance boot."
    ;;
  cancel-next)
    require_root
    ensure_mounts
    set_rw_mounts
    rm -f "$NEXT_FILE"
    set_default_label immutable
    sync
    set_ro_mounts
    echo "Cancelled one-shot boot and restored immutable default."
    ;;
  set-default)
    require_root
    mode="${2:-}"
    case "$mode" in
      immutable|maintenance) ;;
      *)
        echo "set-default requires immutable|maintenance" >&2
        exit 1
        ;;
    esac
    ensure_mounts
    set_rw_mounts
    set_default_label "$mode"
    sync
    set_ro_mounts
    echo "Default boot label set to: $mode"
    ;;
  reboot-maintenance)
    "$0" next-maintenance
    exec /sbin/reboot
    ;;
  reboot-immutable)
    "$0" cancel-next
    exec /sbin/reboot
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
