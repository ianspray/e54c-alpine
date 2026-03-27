#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

read_serial() {
  if [ -r /proc/device-tree/serial-number ]; then
    tr -d '\000' </proc/device-tree/serial-number | tr '[:upper:]' '[:lower:]'
    return 0
  fi

  if [ -r /proc/cpuinfo ]; then
    awk -F ': *' '/^Serial/ {print tolower($2); exit}' /proc/cpuinfo
    return 0
  fi

  return 1
}

normalize_hex() {
  tr -cd '0-9a-f'
}

increment_mac() {
  mac="$1"
  delta="${2:-1}"
  old_ifs="$IFS"
  IFS=:
  set -- $mac
  IFS="$old_ifs"

  b1=$((0x$1))
  b2=$((0x$2))
  b3=$((0x$3))
  b4=$((0x$4))
  b5=$((0x$5))
  b6=$((0x$6))
  carry="$delta"

  b6=$((b6 + carry))
  carry=$((b6 / 256))
  b6=$((b6 % 256))

  b5=$((b5 + carry))
  carry=$((b5 / 256))
  b5=$((b5 % 256))

  b4=$((b4 + carry))
  carry=$((b4 / 256))
  b4=$((b4 % 256))

  b3=$((b3 + carry))
  carry=$((b3 / 256))
  b3=$((b3 % 256))

  b2=$((b2 + carry))
  carry=$((b2 / 256))
  b2=$((b2 % 256))

  b1=$((b1 + carry))
  b1=$((b1 % 256))

  printf '%02x:%02x:%02x:%02x:%02x:%02x\n' \
    "$b1" \
    "$b2" \
    "$b3" \
    "$b4" \
    "$b5" \
    "$b6"
}

set_iface_mac() {
  iface="$1"
  mac="$2"
  was_up=0

  for _ in 1 2 3 4 5; do
    if ip link show dev "$iface" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  ip link show dev "$iface" >/dev/null 2>&1 || return 0
  current_mac="$(cat "/sys/class/net/$iface/address" 2>/dev/null || true)"
  [ "$current_mac" = "$mac" ] && return 0
  if ip link show dev "$iface" 2>/dev/null | grep -q "UP"; then
    was_up=1
  fi
  ip link set dev "$iface" down >/dev/null 2>&1 || true
  ip link set dev "$iface" address "$mac"
  if [ "$was_up" -eq 1 ]; then
    ip link set dev "$iface" up >/dev/null 2>&1 || true
  fi
}

serial="$(read_serial | normalize_hex || true)"
[ -n "$serial" ] || exit 0

hash="$(printf '%s\n' "$serial" | md5sum | awk '{print $1}')"
oct1_hex="$(printf '%s' "$hash" | cut -c1-2)"
oct2_hex="$(printf '%s' "$hash" | cut -c3-4)"
oct3_hex="$(printf '%s' "$hash" | cut -c5-6)"
oct4_hex="$(printf '%s' "$hash" | cut -c7-8)"
oct5_hex="$(printf '%s' "$hash" | cut -c9-10)"
oct6_hex="$(printf '%s' "$hash" | cut -c11-12)"

oct1=$(((0x$oct1_hex | 0x02) & 0xfe))
eth0_mac="$(printf '%02x:%s:%s:%s:%s:%s\n' \
  "$oct1" \
  "$oct2_hex" \
  "$oct3_hex" \
  "$oct4_hex" \
  "$oct5_hex" \
  "$oct6_hex")"
eth1_mac="$(increment_mac "$eth0_mac" 1)"

set_iface_mac eth0 "$eth0_mac"
set_iface_mac eth1 "$eth1_mac"
