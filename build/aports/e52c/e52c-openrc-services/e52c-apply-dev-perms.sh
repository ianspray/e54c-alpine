#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

CONF_FILE="/etc/conf.d/e52c-dev-perms"
[ -f "$CONF_FILE" ] || exit 0

wait_seconds="$(awk -F= '/^[[:space:]]*wait_seconds[[:space:]]*=/{gsub(/[[:space:]]|"/,"",$2); print $2; exit}' "$CONF_FILE" 2>/dev/null || true)"
case "${wait_seconds:-}" in
  ''|*[!0-9]*) wait_seconds=3 ;;
esac
[ "$wait_seconds" -gt 0 ] && sleep "$wait_seconds"

awk '
  /^[[:space:]]*#/ {next}
  /^[[:space:]]*$/ {next}
  {
    pattern=$1; owner=$2; mode=$3
    if (pattern=="" || owner=="" || mode=="") next
    print pattern, owner, mode
  }
' "$CONF_FILE" | while read -r pattern owner mode; do
  matched=0
  for node in $pattern; do
    [ -e "$node" ] || continue
    matched=1
    chown "$owner" "$node" 2>/dev/null || true
    chmod "$mode" "$node" 2>/dev/null || true
  done
  [ "$matched" -eq 1 ] || true
done
