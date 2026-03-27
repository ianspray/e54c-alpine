#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

serial_tty="ttyS2"
wait_seconds="${NET_ADDR_WAIT_SECONDS:-40}"
banner_title=""

if [ -f /etc/conf.d/show-net-addrs ]; then
  # shellcheck disable=SC1091
  . /etc/conf.d/show-net-addrs
fi

collect_addrs() {
  ip -o -4 addr show scope global 2>/dev/null | awk '{print "IPv4 " $2 " " $4}'
  ip -o -6 addr show scope global 2>/dev/null | awk '{print "IPv6 " $2 " " $4}'
}

start_ts=$(date +%s)
addrs=""
while :; do
  addrs="$(collect_addrs | sort -u || true)"
  [ -n "$addrs" ] && break
  now=$(date +%s)
  [ $((now - start_ts)) -ge "$wait_seconds" ] && break
  sleep 1
done

issue_base_file="/etc/issue.base"
[ -f "$issue_base_file" ] || cp /etc/issue "$issue_base_file" 2>/dev/null || true
{
  if [ -f "$issue_base_file" ]; then
    cat "$issue_base_file"
  else
    echo "Alpine Linux"
  fi
  echo
  if [ -n "$banner_title" ]; then
    echo "$banner_title"
    echo
  fi
  echo "Network addresses:"
  if [ -n "$addrs" ]; then
    echo "$addrs"
  else
    echo "No global DHCP address acquired yet."
  fi
} >/etc/issue

{
  echo
  if [ -n "$banner_title" ]; then
    echo "=== $banner_title ==="
  fi
  echo "=== Network Addresses ==="
  if [ -n "$addrs" ]; then
    echo "$addrs"
  else
    echo "No global DHCP address acquired yet."
  fi
  echo "========================="
  echo
} >/run/network-addresses.banner

cat /run/network-addresses.banner >/dev/console 2>/dev/null || true
if [ -c "/dev/$serial_tty" ]; then
  cat /run/network-addresses.banner >"/dev/$serial_tty" 2>/dev/null || true
fi
