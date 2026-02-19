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
ALPINE_PACKAGES="${ALPINE_PACKAGES:-}"
ALPINE_PACKAGE_LIST_FILE="${ALPINE_PACKAGE_LIST_FILE:-$REPO_ROOT/assets/reference/alpine/packages.txt}"
SERIAL_TTY="${SERIAL_TTY:-ttyFIQ0}"
SERIAL_BAUD="${SERIAL_BAUD:-1500000}"
ROOT_AUTHORIZED_KEYS_FILE="${ROOT_AUTHORIZED_KEYS_FILE-__AUTO__}"
ROOT_PASSWORD_HASH="${ROOT_PASSWORD_HASH:-\$6\$e54c\$AvSUgOTK89YCT1RHhqB/SfsK3J5itEI.1QMfd2fRmcUgYla4h4UUBMbCOKPm89stfDAoWvWCA8E0zamUvTN0A/}"
ROOT_PASSWORD_PLAIN="${ROOT_PASSWORD_PLAIN:-}"
ROOT_PASSWORD_SALT="${ROOT_PASSWORD_SALT:-e54c}"
ENABLE_BOOT_NET_BANNER="${ENABLE_BOOT_NET_BANNER:-1}"
BOOT_BANNER_TITLE="${BOOT_BANNER_TITLE:-}"
ENABLE_BOOT_NTP_SYNC="${ENABLE_BOOT_NTP_SYNC:-1}"
BOOT_NTP_SERVERS="${BOOT_NTP_SERVERS:-pool.ntp.org time.cloudflare.com time.google.com}"
E54C_FORCE_DSA_MODULES="${E54C_FORCE_DSA_MODULES:-1}"

DOWNLOAD_DIR="${DOWNLOAD_DIR:-$REPO_ROOT/build/downloads}"
ROOTFS_DIR="${ROOTFS_DIR:-$REPO_ROOT/build/alpine-rootfs}"
ROOTFS_TAR="${ROOTFS_TAR:-$REPO_ROOT/build/alpine-rootfs.tar}"
DEFAULT_ROOT_AUTHORIZED_KEYS_FILE="$REPO_ROOT/assets/reference/alpine/root_authorized_keys"

if [ "$ROOT_AUTHORIZED_KEYS_FILE" = "__AUTO__" ]; then
  if [ -f "$DEFAULT_ROOT_AUTHORIZED_KEYS_FILE" ]; then
    ROOT_AUTHORIZED_KEYS_FILE="$DEFAULT_ROOT_AUTHORIZED_KEYS_FILE"
  else
    ROOT_AUTHORIZED_KEYS_FILE=""
  fi
fi

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

package_args=()
if [ -n "$ALPINE_PACKAGES" ]; then
  read -r -a package_args <<<"$ALPINE_PACKAGES"
elif [ -f "$ALPINE_PACKAGE_LIST_FILE" ]; then
  while IFS= read -r line; do
    line="$(printf '%s' "$line" | sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [ -n "$line" ]; then
      package_args+=("$line")
    fi
  done <"$ALPINE_PACKAGE_LIST_FILE"
fi

if [ "${#package_args[@]}" -eq 0 ]; then
  package_args=(alpine-base alpine-conf openssh)
fi

echo "Installing Alpine packages into rootfs:"
printf '  - %s\n' "${package_args[@]}"
"$APK_STATIC" \
  --usermode \
  --arch "$ALPINE_ARCH" \
  --root "$ROOTFS_DIR" \
  --repositories-file "$ROOTFS_DIR/etc/apk/repositories" \
  --cache-dir "$APK_CACHE_DIR" \
  --no-scripts \
  add "${package_args[@]}"

cat >"$ROOTFS_DIR/etc/fstab" <<'EOF'
# Keep persistent partitions read-only during normal operation.
# lbu temporarily remounts config as writable during commit/revert.
LABEL=config /media/config vfat ro,noatime 0 2
LABEL=efi /boot/efi vfat ro,noatime 0 2
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
BANNER_TITLE="${BOOT_BANNER_TITLE}"

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
  if [ -n "\$BANNER_TITLE" ]; then
    echo "\$BANNER_TITLE"
    echo
  fi
  echo "Network addresses:"
  if [ -n "\$addrs" ]; then
    echo "\$addrs"
  else
    echo "No global DHCP address acquired yet."
  fi
} >/etc/issue

{
  echo
  if [ -n "\$BANNER_TITLE" ]; then
    echo "=== \$BANNER_TITLE ==="
  fi
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

if [ "$ENABLE_BOOT_NTP_SYNC" = "1" ]; then
  cat >"$ROOTFS_DIR/etc/conf.d/e54c-ntp-sync" <<EOF
# Space-separated list of NTP servers for one-shot boot sync.
servers="${BOOT_NTP_SERVERS}"
EOF

  cat >"$ROOTFS_DIR/etc/init.d/e54c-ntp-sync" <<'EOF'
#!/sbin/openrc-run

name="e54c-ntp-sync"
description="Run one-shot NTP sync in background"

depend() {
  need networking
  before sshd
}

start() {
  ebegin "Triggering background NTP sync"
  (
    if [ -f /run/e54c-ntp-sync.done ]; then
      exit 0
    fi
    : "${servers:=pool.ntp.org}"
    ntp_cmd="$(command -v ntpd || true)"
    if [ -n "$ntp_cmd" ]; then
      ntp_invoke="$ntp_cmd"
    else
      ntp_invoke="/bin/busybox ntpd"
    fi
    args=""
    for s in $servers; do
      args="$args -p $s"
    done
    # One-shot sync; run detached so boot/login is never blocked.
    sh -c "$ntp_invoke -q -n $args >/run/e54c-ntp-sync.log 2>&1 || true"
    touch /run/e54c-ntp-sync.done
  ) &
  eend 0
}
EOF
  chmod 0755 "$ROOTFS_DIR/etc/init.d/e54c-ntp-sync"
  enable_service e54c-ntp-sync default
fi

mkdir -p "$ROOTFS_DIR/usr/local/sbin"
cat >"$ROOTFS_DIR/usr/local/sbin/e54c-boot-mode" <<'EOF'
#!/bin/sh
set -eu

EFI_MOUNT="/boot/efi"
CONFIG_MOUNT="/media/config"
EXTLINUX_CONF="$EFI_MOUNT/extlinux/extlinux.conf"
NEXT_FILE="$CONFIG_MOUNT/boot-mode.next"

usage() {
  cat <<'USAGE'
Usage:
  e54c-boot-mode status
  e54c-boot-mode next-maintenance
  e54c-boot-mode cancel-next
  e54c-boot-mode set-default immutable|maintenance
  e54c-boot-mode reboot-maintenance
  e54c-boot-mode reboot-immutable
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
  if grep -qw 'overlaytmpfs=yes' /proc/cmdline; then
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
EOF
chmod 0755 "$ROOTFS_DIR/usr/local/sbin/e54c-boot-mode"

cat >"$ROOTFS_DIR/usr/local/sbin/e54c-bootmode-oneshot-apply" <<'EOF'
#!/bin/sh
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

# Clear one-shot only after we have successfully booted the maintenance profile.
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

tmp="$(mktemp)"
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
EOF
chmod 0755 "$ROOTFS_DIR/usr/local/sbin/e54c-bootmode-oneshot-apply"

cat >"$ROOTFS_DIR/etc/init.d/e54c-bootmode-oneshot" <<'EOF'
#!/sbin/openrc-run

name="e54c-bootmode-oneshot"
description="Apply one-shot maintenance boot mode and restore immutable default"

depend() {
  need localmount
  before networking
}

start() {
  ebegin "Applying one-shot boot mode state"
  /usr/local/sbin/e54c-bootmode-oneshot-apply >/dev/null 2>&1 || true
  eend 0
}
EOF
chmod 0755 "$ROOTFS_DIR/etc/init.d/e54c-bootmode-oneshot"
enable_service e54c-bootmode-oneshot boot

# busybox-suid installs bbsuid as execute-only in usermode; make it readable for tar packaging.
if [ -f "$ROOTFS_DIR/bin/bbsuid" ]; then
  chmod 4755 "$ROOTFS_DIR/bin/bbsuid"
fi

# Normalize ownership in archive for target root filesystem extraction.
tar --numeric-owner --owner=0 --group=0 -C "$ROOTFS_DIR" -cf "$ROOTFS_TAR" .

echo "Alpine rootfs prepared:"
echo "  Rootfs dir: $ROOTFS_DIR"
echo "  Rootfs tar: $ROOTFS_TAR"
