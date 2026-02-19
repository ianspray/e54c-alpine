#!/usr/bin/env bash
set -euo pipefail

export PATH="$PATH:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ALPINE_BRANCH="${ALPINE_BRANCH:-v3.23}"
ALPINE_VERSION="${ALPINE_VERSION:-3.23.3}"
ALPINE_ARCH="${ALPINE_ARCH:-aarch64}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
HOST_ARCH="${HOST_ARCH:-$(uname -m)}"
APK_CACHE_DIR="${APK_CACHE_DIR:-$REPO_ROOT/build/apk-cache}"
ALPINE_PACKAGES="${ALPINE_PACKAGES:-alpine-base alpine-conf openssh}"
SERIAL_TTY="${SERIAL_TTY:-ttyFIQ0}"
SERIAL_BAUD="${SERIAL_BAUD:-1500000}"
ROOT_AUTHORIZED_KEYS_FILE="${ROOT_AUTHORIZED_KEYS_FILE:-}"
ROOT_PASSWORD_HASH="${ROOT_PASSWORD_HASH:-\$6\$e54c\$AvSUgOTK89YCT1RHhqB/SfsK3J5itEI.1QMfd2fRmcUgYla4h4UUBMbCOKPm89stfDAoWvWCA8E0zamUvTN0A/}"
ROOT_PASSWORD_PLAIN="${ROOT_PASSWORD_PLAIN:-}"
ROOT_PASSWORD_SALT="${ROOT_PASSWORD_SALT:-e54c}"
ENABLE_BOOT_NET_BANNER="${ENABLE_BOOT_NET_BANNER:-1}"
E54C_FORCE_DSA_MODULES="${E54C_FORCE_DSA_MODULES:-1}"

DOWNLOAD_DIR="${DOWNLOAD_DIR:-$REPO_ROOT/build/downloads}"
ROOTFS_DIR="${ROOTFS_DIR:-$REPO_ROOT/build/alpine-rootfs}"
ROOTFS_TAR="${ROOTFS_TAR:-$REPO_ROOT/build/alpine-rootfs.tar}"

mkdir -p "$DOWNLOAD_DIR" "$ROOTFS_DIR" "$APK_CACHE_DIR"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

require_cmd curl
require_cmd tar
require_cmd awk
require_cmd sed

tmp_work="$(mktemp -d)"
trap 'rm -rf "$tmp_work"' EXIT

MINIROOTFS="alpine-minirootfs-${ALPINE_VERSION}-${ALPINE_ARCH}.tar.gz"
MINIROOTFS_URL="${ALPINE_MIRROR}/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/${MINIROOTFS}"
MINIROOTFS_PATH="${DOWNLOAD_DIR}/${MINIROOTFS}"

if [ ! -f "$MINIROOTFS_PATH" ]; then
  echo "Downloading $MINIROOTFS_URL"
  curl -fL "$MINIROOTFS_URL" -o "$MINIROOTFS_PATH"
fi

rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"
tar -xzf "$MINIROOTFS_PATH" -C "$ROOTFS_DIR"

cat >"$ROOTFS_DIR/etc/apk/repositories" <<EOF
${ALPINE_MIRROR}/${ALPINE_BRANCH}/main
${ALPINE_MIRROR}/${ALPINE_BRANCH}/community
EOF

# Install additional Alpine packages from the host using apk.static.
HOST_APKINDEX="${DOWNLOAD_DIR}/APKINDEX-${ALPINE_BRANCH}-${HOST_ARCH}.tar.gz"
if [ ! -f "$HOST_APKINDEX" ]; then
  curl -fL "${ALPINE_MIRROR}/${ALPINE_BRANCH}/main/${HOST_ARCH}/APKINDEX.tar.gz" -o "$HOST_APKINDEX"
fi
tar -xzf "$HOST_APKINDEX" -C "$tmp_work"
APK_TOOLS_STATIC_VERSION="$(awk 'BEGIN{RS="\n\n"} /P:apk-tools-static\n/ {for (i=1; i<=NF; i++) if ($i ~ /^V:/) {print substr($i,3); exit}}' "$tmp_work/APKINDEX")"
if [ -z "$APK_TOOLS_STATIC_VERSION" ]; then
  echo "Unable to determine apk-tools-static version from $HOST_APKINDEX" >&2
  exit 1
fi

APK_TOOLS_STATIC_PKG="apk-tools-static-${APK_TOOLS_STATIC_VERSION}.apk"
APK_TOOLS_STATIC_PATH="${DOWNLOAD_DIR}/${APK_TOOLS_STATIC_PKG}"
if [ ! -f "$APK_TOOLS_STATIC_PATH" ]; then
  curl -fL "${ALPINE_MIRROR}/${ALPINE_BRANCH}/main/${HOST_ARCH}/${APK_TOOLS_STATIC_PKG}" -o "$APK_TOOLS_STATIC_PATH"
fi
tar -xzf "$APK_TOOLS_STATIC_PATH" -C "$tmp_work"
APK_STATIC="$tmp_work/sbin/apk.static"
chmod +x "$APK_STATIC"

"$APK_STATIC" \
  --usermode \
  --arch "$ALPINE_ARCH" \
  --root "$ROOTFS_DIR" \
  --repositories-file "$ROOTFS_DIR/etc/apk/repositories" \
  --cache-dir "$APK_CACHE_DIR" \
  --no-scripts \
  add $ALPINE_PACKAGES

cat >"$ROOTFS_DIR/etc/fstab" <<'EOF'
LABEL=config /media/config vfat defaults 0 2
LABEL=efi /boot/efi vfat defaults 0 2
LABEL=rootfs / ext4 defaults 0 1
EOF

mkdir -p "$ROOTFS_DIR/media/config" "$ROOTFS_DIR/etc/apk"
ln -snf /media/config/cache "$ROOTFS_DIR/etc/apk/cache"

if [ -f "$ROOTFS_DIR/etc/lbu/lbu.conf" ]; then
  if grep -Eq '^[# ]*LBU_MEDIA=' "$ROOTFS_DIR/etc/lbu/lbu.conf"; then
    sed -E -i 's|^[# ]*LBU_MEDIA=.*|LBU_MEDIA=config|' "$ROOTFS_DIR/etc/lbu/lbu.conf"
  else
    echo "LBU_MEDIA=config" >>"$ROOTFS_DIR/etc/lbu/lbu.conf"
  fi
fi

mkdir -p "$ROOTFS_DIR/etc/network"
cat >"$ROOTFS_DIR/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

# Radxa E54C uses DSA port names from DT:
# wan, lan1, lan2, lan3
# WAN is DHCP client; LAN ports are manual for local services (e.g. DHCP server).
auto wan
iface wan inet dhcp

auto lan1
iface lan1 inet manual

auto lan2
iface lan2 inet manual

auto lan3
iface lan3 inet manual
EOF

if [ "$E54C_FORCE_DSA_MODULES" = "1" ]; then
  cat >"$ROOTFS_DIR/etc/modules" <<'EOF'
# Base networking modules
af_packet
ipv6

# Radxa E54C DSA switch stack (front-panel ports wan/lan1/lan2/lan3)
dsa_core
tag_rtl4_a
tag_rtl8_4
realtek-mdio
realtek-smi
rtl8365mb
rtl8366
EOF
fi

# Serial-only login for headless operation.
cat >"$ROOTFS_DIR/etc/inittab" <<EOF
# /etc/inittab

::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

${SERIAL_TTY}::respawn:/sbin/getty -L ${SERIAL_BAUD} ${SERIAL_TTY} vt100

::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

if ! grep -qx "$SERIAL_TTY" "$ROOTFS_DIR/etc/securetty"; then
  echo "$SERIAL_TTY" >>"$ROOTFS_DIR/etc/securetty"
fi

enable_service() {
  local service="$1"
  local level="$2"
  if [ ! -e "$ROOTFS_DIR/etc/init.d/$service" ]; then
    return 0
  fi
  mkdir -p "$ROOTFS_DIR/etc/runlevels/$level"
  ln -snf "/etc/init.d/$service" "$ROOTFS_DIR/etc/runlevels/$level/$service"
}

for svc in devfs dmesg mdev procfs sysfs; do
  enable_service "$svc" sysinit
done
for svc in modules sysctl hostname bootmisc swclock localmount; do
  enable_service "$svc" boot
done
for svc in networking sshd; do
  enable_service "$svc" default
done

# Optional: preload root authorized_keys for headless SSH access.
if [ -n "$ROOT_AUTHORIZED_KEYS_FILE" ]; then
  if [ ! -f "$ROOT_AUTHORIZED_KEYS_FILE" ]; then
    echo "ROOT_AUTHORIZED_KEYS_FILE does not exist: $ROOT_AUTHORIZED_KEYS_FILE" >&2
    exit 1
  fi
  mkdir -p "$ROOTFS_DIR/root/.ssh"
  chmod 700 "$ROOTFS_DIR/root/.ssh"
  cp "$ROOT_AUTHORIZED_KEYS_FILE" "$ROOTFS_DIR/root/.ssh/authorized_keys"
  chmod 600 "$ROOTFS_DIR/root/.ssh/authorized_keys"
fi

# Optional root password setup for serial bring-up.
# To disable password login in future builds, set ROOT_PASSWORD_HASH="" and ROOT_PASSWORD_PLAIN="".
if [ -n "$ROOT_PASSWORD_PLAIN" ]; then
  require_cmd openssl
  ROOT_PASSWORD_HASH="$(openssl passwd -6 -salt "$ROOT_PASSWORD_SALT" "$ROOT_PASSWORD_PLAIN")"
fi
if [ -n "$ROOT_PASSWORD_HASH" ] && [ -f "$ROOTFS_DIR/etc/shadow" ]; then
  tmp_shadow="$(mktemp)"
  awk -F: -v OFS=: -v hash="$ROOT_PASSWORD_HASH" '($1=="root"){$2=hash}1' \
    "$ROOTFS_DIR/etc/shadow" >"$tmp_shadow"
  mv "$tmp_shadow" "$ROOTFS_DIR/etc/shadow"
  chmod 640 "$ROOTFS_DIR/etc/shadow"
fi

if [ "$ENABLE_BOOT_NET_BANNER" = "1" ]; then
  mkdir -p "$ROOTFS_DIR/usr/local/sbin"
  cat >"$ROOTFS_DIR/usr/local/sbin/show-net-addrs" <<EOF
#!/bin/sh
set -eu

SERIAL_TTY="${SERIAL_TTY}"
WAIT_SECONDS="\${NET_ADDR_WAIT_SECONDS:-40}"

collect_addrs() {
  ip -o -4 addr show scope global 2>/dev/null | awk '{print "IPv4 " \$2 " " \$4}'
  ip -o -6 addr show scope global 2>/dev/null | awk '{print "IPv6 " \$2 " " \$4}'
}

start_ts=\$(date +%s)
addrs=""
while :; do
  addrs="\$(collect_addrs | sort -u || true)"
  [ -n "\$addrs" ] && break
  now=\$(date +%s)
  [ \$((now - start_ts)) -ge "\$WAIT_SECONDS" ] && break
  sleep 1
done

issue_base_file="/etc/issue.base"
[ -f "\$issue_base_file" ] || cp /etc/issue "\$issue_base_file" 2>/dev/null || true
{
  if [ -f "\$issue_base_file" ]; then
    cat "\$issue_base_file"
  else
    echo "Alpine Linux"
  fi
  echo
  echo "Network addresses:"
  if [ -n "\$addrs" ]; then
    echo "\$addrs"
  else
    echo "No global DHCP address acquired yet."
  fi
} >/etc/issue

{
  echo
  echo "=== Network Addresses ==="
  if [ -n "\$addrs" ]; then
    echo "\$addrs"
  else
    echo "No global DHCP address acquired yet."
  fi
  echo "========================="
  echo
} >/run/network-addresses.banner

cat /run/network-addresses.banner >/dev/console 2>/dev/null || true
if [ -c "/dev/\$SERIAL_TTY" ]; then
  cat /run/network-addresses.banner >"/dev/\$SERIAL_TTY" 2>/dev/null || true
fi
EOF
  chmod 0755 "$ROOTFS_DIR/usr/local/sbin/show-net-addrs"

  cat >"$ROOTFS_DIR/etc/init.d/show-net-addrs" <<'EOF'
#!/sbin/openrc-run

name="show-net-addrs"
description="Show network addresses on console and login banner"

depend() {
  need networking
  after sshd
}

start() {
  ebegin "Updating login banner with network addresses"
  /usr/local/sbin/show-net-addrs >/dev/null 2>&1 || true
  eend 0
}
EOF
  chmod 0755 "$ROOTFS_DIR/etc/init.d/show-net-addrs"
  enable_service show-net-addrs default
fi

# busybox-suid installs bbsuid as execute-only in usermode; make it readable for tar packaging.
if [ -f "$ROOTFS_DIR/bin/bbsuid" ]; then
  chmod 4755 "$ROOTFS_DIR/bin/bbsuid"
fi

# Normalize ownership in archive for target root filesystem extraction.
tar --numeric-owner --owner=0 --group=0 -C "$ROOTFS_DIR" -cf "$ROOTFS_TAR" .

echo "Alpine rootfs prepared:"
echo "  Rootfs dir: $ROOTFS_DIR"
echo "  Rootfs tar: $ROOTFS_TAR"
