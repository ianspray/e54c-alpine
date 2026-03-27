#!/bin/sh
# SPDX-License-Identifier: MIT
# Custom udhcpc script for e25: writes /etc/resolv.conf reliably
# and handles interface events cleanly.

RESOLV_CONF="/etc/resolv.conf"

case "$1" in
  deconfig)
    ip link set "$interface" up
    ip addr flush dev "$interface"
    ;;
  renew|bound)
    ip addr add "$ip"/"$mask" dev "$interface" broadcast "$broadcast" 2>/dev/null || true
    ip link set "$interface" up

    if [ -n "$router" ]; then
      ip route del default via "$router" dev "$interface" 2>/dev/null || true
      ip route add default via "$router" dev "$interface"
    fi

    : >"$RESOLV_CONF"
    for dns in $dns; do
      echo "nameserver $dns" >>"$RESOLV_CONF"
    done
    if [ -s "$RESOLV_CONF" ]; then
      chmod 644 "$RESOLV_CONF"
    fi
    ;;
esac
