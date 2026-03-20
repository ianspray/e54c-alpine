#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

export PATH="$PATH:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/board-config.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/cache.sh"
load_board_config
cache_init

ALPINE_BRANCH="${ALPINE_BRANCH:-v3.23}"
ALPINE_VERSION="${ALPINE_VERSION:-3.23.3}"
ALPINE_ARCH="${ALPINE_ARCH:-aarch64}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
HOST_ARCH="${HOST_ARCH:-$(uname -m)}"
ALPINE_PACKAGES="${ALPINE_PACKAGES:-}"
ALPINE_PACKAGE_LIST_FILE="${ALPINE_PACKAGE_LIST_FILE:-}"
ALPINE_PACKAGE_LIST_FILES="${ALPINE_PACKAGE_LIST_FILES:-}"
COMMON_ALPINE_PACKAGE_LIST_FILE="${COMMON_ALPINE_PACKAGE_LIST_FILE:-$REPO_ROOT/boards/alpian/alpine/packages.txt}"
BOARD_ALPINE_PACKAGE_LIST_FILE="${BOARD_ALPINE_PACKAGE_LIST_FILE:-}"
CUSTOM_APK_REPOSITORIES_FILE="${CUSTOM_APK_REPOSITORIES_FILE:-$REPO_ROOT/assets/reference/alpine/custom-repositories.txt}"
CUSTOM_APK_PACKAGES_FILE="${CUSTOM_APK_PACKAGES_FILE:-}"
CUSTOM_APK_PACKAGES_FILES="${CUSTOM_APK_PACKAGES_FILES:-}"
COMMON_CUSTOM_APK_PACKAGES_FILE="${COMMON_CUSTOM_APK_PACKAGES_FILE:-$REPO_ROOT/boards/alpian/alpine/custom-packages.txt}"
BOARD_CUSTOM_APK_PACKAGES_FILE="${BOARD_CUSTOM_APK_PACKAGES_FILE:-}"
CUSTOM_APK_KEYS_DIR="${CUSTOM_APK_KEYS_DIR:-$REPO_ROOT/assets/reference/alpine/custom-keys}"
LOCAL_CUSTOM_APK_REPO_DIR="${LOCAL_CUSTOM_APK_REPO_DIR:-$REPO_ROOT/build/apk-repo/$ALPINE_BRANCH}"
LOCAL_CUSTOM_APK_KEYS_DIR="${LOCAL_CUSTOM_APK_KEYS_DIR:-$REPO_ROOT/build/apk-repo/keys}"
SERIAL_TTY="${SERIAL_TTY:-${BOARD_SERIAL_TTY:-ttyFIQ0}}"
SERIAL_BAUD="${SERIAL_BAUD:-${BOARD_SERIAL_BAUD:-1500000}}"
# UART links cannot negotiate terminal capabilities, so default to a plain
# ASCII-safe terminal type and let richer clients opt in explicitly.
SERIAL_TERM="${SERIAL_TERM:-${BOARD_SERIAL_TERM:-dumb}}"
ROOT_AUTHORIZED_KEYS_FILE="${ROOT_AUTHORIZED_KEYS_FILE-__AUTO__}"
ROOT_PASSWORD_HASH="${ROOT_PASSWORD_HASH:-\$6\$e54c\$AvSUgOTK89YCT1RHhqB/SfsK3J5itEI.1QMfd2fRmcUgYla4h4UUBMbCOKPm89stfDAoWvWCA8E0zamUvTN0A/}"
ROOT_PASSWORD_PLAIN="${ROOT_PASSWORD_PLAIN:-}"
ROOT_PASSWORD_SALT="${ROOT_PASSWORD_SALT:-${BOARD_ROOT_PASSWORD_SALT:-e54c}}"
ENABLE_BOOT_NET_BANNER="${ENABLE_BOOT_NET_BANNER:-1}"
BOOT_BANNER_TITLE="${BOOT_BANNER_TITLE:-}"
ENABLE_BOOT_NTP_SYNC="${ENABLE_BOOT_NTP_SYNC:-1}"
BOOT_NTP_SERVERS="${BOOT_NTP_SERVERS:-pool.ntp.org time.cloudflare.com time.google.com}"
# Backward compatibility:
# - E54C_FORCE_DSA_MODULES previously controlled writing /etc/modules.
# - FORCE_BOARD_MODULES is the board-agnostic equivalent.
FORCE_BOARD_MODULES="${FORCE_BOARD_MODULES:-${E54C_FORCE_DSA_MODULES:-1}}"
BOARD_ALPINE_INTERFACES_FILE="${BOARD_ALPINE_INTERFACES_FILE:-}"
BOARD_ALPINE_MODULES_FILE="${BOARD_ALPINE_MODULES_FILE:-}"
BOARD_BOOT_SERVICES="${BOARD_BOOT_SERVICES:-${BOARD}-dev-perms ${BOARD}-bootmode-oneshot partition-mount}"
BOARD_IMMUTABLE_ROOT_SERVICE="${BOARD_IMMUTABLE_ROOT_SERVICE:-${BOARD}-root-mode}"
NET_BANNER_SERVICE_NAME="${NET_BANNER_SERVICE_NAME:-${BOARD_NET_BANNER_SERVICE_NAME:-show-net-addrs}}"
BOOT_NTP_SERVICE_NAME="${BOOT_NTP_SERVICE_NAME:-${BOARD_BOOT_NTP_SERVICE_NAME:-${BOARD}-ntp-sync}}"
MOTD_TEMPLATE_FILE="${MOTD_TEMPLATE_FILE:-$REPO_ROOT/assets/reference/alpine/motd-main}"
ENFORCE_IMMUTABLE_ROOT="${ENFORCE_IMMUTABLE_ROOT:-1}"
ALPIAN_DEFAULT_HOSTNAME="${ALPIAN_DEFAULT_HOSTNAME:-alpian-${BOARD}}"

ROOTFS_DIR_WAS_SET="${ROOTFS_DIR+x}"
ROOTFS_DIR="${ROOTFS_DIR:-$REPO_ROOT/build/alpine-rootfs}"
ROOTFS_TAR="${ROOTFS_TAR:-$REPO_ROOT/build/alpine-rootfs.tar}"
ROOTFS_FALLBACK_ON_EXTRACT_FAILURE="${ROOTFS_FALLBACK_ON_EXTRACT_FAILURE:-1}"
ROOTFS_FALLBACK_DIR="${ROOTFS_FALLBACK_DIR:-/tmp/${BOARD}-alpine-rootfs}"
DEFAULT_ROOT_AUTHORIZED_KEYS_FILE="$REPO_ROOT/assets/reference/alpine/root_authorized_keys"
LEGACY_COMMON_ALPINE_PACKAGE_LIST_FILE="$REPO_ROOT/assets/reference/alpine/packages.txt"
LEGACY_COMMON_CUSTOM_APK_PACKAGES_FILE="$REPO_ROOT/assets/reference/alpine/custom-packages.txt"

# In containerized macOS workflows, bind-mounted /workspace can reject
# extraction/deletion of many rootfs files. Prefer a container-local path.
if [ -z "$ROOTFS_DIR_WAS_SET" ] && [[ "$REPO_ROOT" == /workspace* ]]; then
  ROOTFS_DIR="$ROOTFS_FALLBACK_DIR"
fi

if [ "$ROOT_AUTHORIZED_KEYS_FILE" = "__AUTO__" ]; then
  if [ -f "$DEFAULT_ROOT_AUTHORIZED_KEYS_FILE" ]; then
    ROOT_AUTHORIZED_KEYS_FILE="$DEFAULT_ROOT_AUTHORIZED_KEYS_FILE"
  else
    ROOT_AUTHORIZED_KEYS_FILE=""
  fi
fi

if [ ! -f "$COMMON_ALPINE_PACKAGE_LIST_FILE" ] && [ -f "$LEGACY_COMMON_ALPINE_PACKAGE_LIST_FILE" ]; then
  COMMON_ALPINE_PACKAGE_LIST_FILE="$LEGACY_COMMON_ALPINE_PACKAGE_LIST_FILE"
fi
if [ ! -f "$COMMON_CUSTOM_APK_PACKAGES_FILE" ] && [ -f "$LEGACY_COMMON_CUSTOM_APK_PACKAGES_FILE" ]; then
  COMMON_CUSTOM_APK_PACKAGES_FILE="$LEGACY_COMMON_CUSTOM_APK_PACKAGES_FILE"
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
  download_cached_url "$MINIROOTFS_URL" "$MINIROOTFS_PATH" "Alpine minirootfs"
fi

extract_minirootfs() {
  local target_dir="$1"
  rm -rf "$target_dir"
  mkdir -p "$target_dir"
  if ! tar -xzf "$MINIROOTFS_PATH" -C "$target_dir"; then
    return 1
  fi
}

if ! extract_minirootfs "$ROOTFS_DIR"; then
  if [ "$ROOTFS_FALLBACK_ON_EXTRACT_FAILURE" = "1" ] && [ "$ROOTFS_DIR" != "$ROOTFS_FALLBACK_DIR" ]; then
    echo "Rootfs extraction failed in path: $ROOTFS_DIR" >&2
    echo "Retrying in fallback path: $ROOTFS_FALLBACK_DIR" >&2
    ROOTFS_DIR="$ROOTFS_FALLBACK_DIR"
    mkdir -p "$ROOTFS_DIR"
    if ! extract_minirootfs "$ROOTFS_DIR"; then
      echo "Rootfs extraction failed in fallback path: $ROOTFS_DIR" >&2
      exit 1
    fi
  else
    echo "Rootfs extraction failed for ROOTFS_DIR=$ROOTFS_DIR" >&2
    exit 1
  fi
fi

repo_lines=(
  "${ALPINE_MIRROR}/${ALPINE_BRANCH}/main"
  "${ALPINE_MIRROR}/${ALPINE_BRANCH}/community"
)
custom_repo_count=0
if [ -f "$CUSTOM_APK_REPOSITORIES_FILE" ]; then
  while IFS= read -r line; do
    line="$(printf '%s' "$line" | sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [ -n "$line" ]; then
      repo_lines+=("$line")
      custom_repo_count=$((custom_repo_count + 1))
    fi
  done <"$CUSTOM_APK_REPOSITORIES_FILE"
fi

if [ -f "$LOCAL_CUSTOM_APK_REPO_DIR/$ALPINE_ARCH/APKINDEX.tar.gz" ]; then
  repo_lines+=("$LOCAL_CUSTOM_APK_REPO_DIR")
  custom_repo_count=$((custom_repo_count + 1))
fi

printf '%s\n' "${repo_lines[@]}" >"$ROOTFS_DIR/etc/apk/repositories"

copy_apk_keys() {
  local key_dir="$1"
  [ -d "$key_dir" ] || return 0
  mkdir -p "$ROOTFS_DIR/etc/apk/keys"
  while IFS= read -r key_file; do
    cp "$key_file" "$ROOTFS_DIR/etc/apk/keys/"
  done < <(find "$key_dir" -maxdepth 1 -type f -name '*.pub' | sort)
}

copy_apk_keys "$CUSTOM_APK_KEYS_DIR"
copy_apk_keys "$LOCAL_CUSTOM_APK_KEYS_DIR"

# Keep future mountpoints writable while apk populates the build rootfs.
mkdir -p "$ROOTFS_DIR/opt" "$ROOTFS_DIR/var/lib/docker"

# Install additional Alpine packages from the host using apk.static.
HOST_APKINDEX="${DOWNLOAD_DIR}/APKINDEX-${ALPINE_BRANCH}-${HOST_ARCH}.tar.gz"
if [ ! -f "$HOST_APKINDEX" ]; then
  download_cached_url \
    "${ALPINE_MIRROR}/${ALPINE_BRANCH}/main/${HOST_ARCH}/APKINDEX.tar.gz" \
    "$HOST_APKINDEX" \
    "Alpine host APKINDEX"
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
  download_cached_url \
    "${ALPINE_MIRROR}/${ALPINE_BRANCH}/main/${HOST_ARCH}/${APK_TOOLS_STATIC_PKG}" \
    "$APK_TOOLS_STATIC_PATH" \
    "apk-tools-static"
fi
tar -xzf "$APK_TOOLS_STATIC_PATH" -C "$tmp_work"
APK_STATIC="$tmp_work/sbin/apk.static"
chmod +x "$APK_STATIC"

package_args=()
append_pkg_unique() {
  local pkg="$1"
  local existing=""
  for existing in "${package_args[@]}"; do
    if [ "$existing" = "$pkg" ]; then
      return 0
    fi
  done
  package_args+=("$pkg")
}

read_package_file() {
  local package_file="$1"
  [ -f "$package_file" ] || return 0
  while IFS= read -r line; do
    line="$(printf '%s' "$line" | sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [ -n "$line" ]; then
      append_pkg_unique "$line"
    fi
  done <"$package_file"
}

decompress_realtek_firmware() {
  local compressed_firmware=""
  local firmware_file=""
  local firmware_target=""
  local firmware_basename=""

  compressed_firmware="$(find "$ROOTFS_DIR" -type f -path '*/rtl_nic/*.fw.zst' | sort || true)"
  [ -n "$compressed_firmware" ] || return 0

  require_cmd zstd
  while IFS= read -r firmware_file; do
    [ -n "$firmware_file" ] || continue
    firmware_target="${firmware_file%.zst}"
    zstd -d -q -f -o "$firmware_target" "$firmware_file"

    case "$firmware_target" in
      "$ROOTFS_DIR"/lib/firmware/*|"$ROOTFS_DIR"/usr/lib/firmware/*)
        ;;
      *)
        firmware_basename="$(basename "$firmware_target")"
        mkdir -p "$ROOTFS_DIR/lib/firmware/rtl_nic"
        cp -f "$firmware_target" "$ROOTFS_DIR/lib/firmware/rtl_nic/$firmware_basename"
        ;;
    esac
  done <<EOF
$compressed_firmware
EOF
}

package_file_has_entries() {
  local package_file="$1"
  [ -f "$package_file" ] || return 1
  grep -Eq '^[[:space:]]*[^#[:space:]]' "$package_file"
}

package_list_files=()
if [ -n "$ALPINE_PACKAGE_LIST_FILES" ]; then
  read -r -a package_list_files <<<"$ALPINE_PACKAGE_LIST_FILES"
elif [ -n "$ALPINE_PACKAGE_LIST_FILE" ]; then
  package_list_files=("$ALPINE_PACKAGE_LIST_FILE")
else
  package_list_files=("$COMMON_ALPINE_PACKAGE_LIST_FILE")
  if [ -n "$BOARD_ALPINE_PACKAGE_LIST_FILE" ]; then
    package_list_files+=("$BOARD_ALPINE_PACKAGE_LIST_FILE")
  fi
fi

custom_package_files=()
if [ -n "$CUSTOM_APK_PACKAGES_FILES" ]; then
  read -r -a custom_package_files <<<"$CUSTOM_APK_PACKAGES_FILES"
elif [ -n "$CUSTOM_APK_PACKAGES_FILE" ]; then
  custom_package_files=("$CUSTOM_APK_PACKAGES_FILE")
else
  custom_package_files=("$COMMON_CUSTOM_APK_PACKAGES_FILE")
  if [ -n "$BOARD_CUSTOM_APK_PACKAGES_FILE" ]; then
    custom_package_files+=("$BOARD_CUSTOM_APK_PACKAGES_FILE")
  fi
fi

if [ -n "$ALPINE_PACKAGES" ]; then
  read -r -a _user_package_args <<<"$ALPINE_PACKAGES"
  for pkg in "${_user_package_args[@]}"; do
    append_pkg_unique "$pkg"
  done
else
  for package_file in "${package_list_files[@]}"; do
    read_package_file "$package_file"
  done
fi

if [ "$custom_repo_count" -gt 0 ]; then
  for package_file in "${custom_package_files[@]}"; do
    read_package_file "$package_file"
  done
else
  configured_custom_package_files=()
  for package_file in "${custom_package_files[@]}"; do
    if package_file_has_entries "$package_file"; then
      configured_custom_package_files+=("$package_file")
    fi
  done
  if [ "${#configured_custom_package_files[@]}" -gt 0 ]; then
    echo "Custom packages are configured in:" >&2
    printf '  - %s\n' "${configured_custom_package_files[@]}" >&2
    echo "but no custom APK repository is available." >&2
    echo "Run scripts/build-apk-repo.sh first, or configure CUSTOM_APK_REPOSITORIES_FILE." >&2
    exit 1
  fi
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
  --keys-dir "$ROOTFS_DIR/etc/apk/keys" \
  --repositories-file "$ROOTFS_DIR/etc/apk/repositories" \
  --cache-dir "$APK_CACHE_DIR" \
  --no-scripts \
  add "${package_args[@]}"

# Alpine firmware subpackages commonly ship compressed .fw.zst blobs. The
# FriendlyElec/Radxa vendor kernels used here request plain .fw names and can
# stall in the sysfs fallback path if only compressed Realtek blobs are present.
decompress_realtek_firmware

if [ -n "$MOTD_TEMPLATE_FILE" ]; then
  if [ ! -f "$MOTD_TEMPLATE_FILE" ]; then
    echo "MOTD template does not exist: $MOTD_TEMPLATE_FILE" >&2
    exit 1
  fi
  install -m 0644 "$MOTD_TEMPLATE_FILE" "$ROOTFS_DIR/etc/motd"
fi

cat >"$ROOTFS_DIR/etc/fstab" <<'EOF'
# Keep persistent partitions read-only during normal operation.
# lbu temporarily remounts config as writable during commit/revert.
LABEL=config /media/config vfat ro,noatime 0 2
LABEL=efi /boot/efi vfat ro,noatime 0 2
LABEL=opt /opt ext4 ro,noatime 0 2
LABEL=docker /var/lib/docker ext4 ro,noatime 0 2
LABEL=rootfs / ext4 defaults 0 1
EOF

mkdir -p "$ROOTFS_DIR/media/config" "$ROOTFS_DIR/etc/apk" "$ROOTFS_DIR/opt" "$ROOTFS_DIR/var/lib/docker"
ln -snf /media/config/cache "$ROOTFS_DIR/etc/apk/cache"

if [ -f "$ROOTFS_DIR/etc/lbu/lbu.conf" ]; then
  if grep -Eq '^[# ]*LBU_MEDIA=' "$ROOTFS_DIR/etc/lbu/lbu.conf"; then
    sed -E -i 's|^[# ]*LBU_MEDIA=.*|LBU_MEDIA=config|' "$ROOTFS_DIR/etc/lbu/lbu.conf"
  else
    echo "LBU_MEDIA=config" >>"$ROOTFS_DIR/etc/lbu/lbu.conf"
  fi
  if grep -Eq '^[# ]*LBU_BACKUPDIR=' "$ROOTFS_DIR/etc/lbu/lbu.conf"; then
    sed -E -i 's|^[# ]*LBU_BACKUPDIR=.*|LBU_BACKUPDIR=/media/config|' "$ROOTFS_DIR/etc/lbu/lbu.conf"
  else
    echo "LBU_BACKUPDIR=/media/config" >>"$ROOTFS_DIR/etc/lbu/lbu.conf"
  fi
  if ! grep -Eq '^[# ]*ALPIAN_APKOVL=' "$ROOTFS_DIR/etc/lbu/lbu.conf"; then
    echo "ALPIAN_APKOVL=/media/config/alpian.apkovl.tar.gz" >>"$ROOTFS_DIR/etc/lbu/lbu.conf"
  fi
fi

echo "$ALPIAN_DEFAULT_HOSTNAME" >"$ROOTFS_DIR/etc/hostname"

mkdir -p "$ROOTFS_DIR/etc/avahi/services"
if [ -f "$ROOTFS_DIR/etc/avahi/avahi-daemon.conf" ]; then
  sed -i 's/.*enable-dbus=.*/enable-dbus=no/' "$ROOTFS_DIR/etc/avahi/avahi-daemon.conf"
fi
if [ -f "$ROOTFS_DIR/etc/init.d/avahi-daemon" ]; then
  sed -i 's/need dbus hostname/need hostname/' "$ROOTFS_DIR/etc/init.d/avahi-daemon"
fi

chroot "$ROOTFS_DIR" addgroup -S avahi 2>/dev/null || true
chroot "$ROOTFS_DIR" adduser -S -G avahi avahi 2>/dev/null || true

cat >"$ROOTFS_DIR/etc/avahi/services/ssh.service" <<'EOF'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">%h SSH</name>
  <service>
    <type>_ssh._tcp</type>
    <port>22</port>
  </service>
</service-group>
EOF

cat >"$ROOTFS_DIR/etc/avahi/services/device-info.service" <<'EOF'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">%h Device Info</name>
  <service>
    <type>_device-info._tcp</type>
    <port>0</port>
    <txt-record>model=Alpian Linux on AArch64</txt-record>
  </service>
</service-group>
EOF

if [ -f "$ROOTFS_DIR/etc/nsswitch.conf" ]; then
  if ! grep -Eq '^hosts:.*mdns4_minimal' "$ROOTFS_DIR/etc/nsswitch.conf"; then
    sed -i 's/^hosts:[[:space:]]*/hosts:          files mdns4_minimal dns /' "$ROOTFS_DIR/etc/nsswitch.conf"
  fi
fi

mkdir -p "$ROOTFS_DIR/media/config"
ALPIAN_APKOVL_PATH="$ROOTFS_DIR/media/config/alpian.apkovl.tar.gz"
if [ ! -f "$ALPIAN_APKOVL_PATH" ]; then
  tmp_apkovl_dir="$(mktemp -d)"
  mkdir -p "$tmp_apkovl_dir/etc"
  cp "$ROOTFS_DIR/etc/hostname" "$tmp_apkovl_dir/etc/"
  tar -C "$tmp_apkovl_dir" -czf "$ALPIAN_APKOVL_PATH" etc/
  rm -rf "$tmp_apkovl_dir"
fi

mkdir -p "$ROOTFS_DIR/etc/network"
if [ -n "$BOARD_ALPINE_INTERFACES_FILE" ] && [ -f "$BOARD_ALPINE_INTERFACES_FILE" ]; then
  install -m 0644 "$BOARD_ALPINE_INTERFACES_FILE" "$ROOTFS_DIR/etc/network/interfaces"
else
  cat >"$ROOTFS_DIR/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
fi

if [ "$FORCE_BOARD_MODULES" = "1" ]; then
  if [ -n "$BOARD_ALPINE_MODULES_FILE" ] && [ -f "$BOARD_ALPINE_MODULES_FILE" ]; then
    install -m 0644 "$BOARD_ALPINE_MODULES_FILE" "$ROOTFS_DIR/etc/modules"
  fi
fi

# Serial-only login for headless operation.
cat >"$ROOTFS_DIR/etc/inittab" <<EOF
# /etc/inittab

::sysinit:/bin/sh -c 'echo "<6>[userspace] pid1 reached sysinit" >/dev/kmsg 2>/dev/null || true; echo "[userspace] pid1 reached sysinit" >/dev/console 2>/dev/null || true; if [ -c /dev/${SERIAL_TTY} ]; then echo "[userspace] pid1 reached sysinit" >/dev/${SERIAL_TTY} 2>/dev/null || true; fi'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

::once:/bin/sh -c 'if [ -c /dev/${SERIAL_TTY} ] && [ -f /etc/motd ]; then cat /etc/motd > /dev/${SERIAL_TTY} 2>/dev/null || true; printf "\n" > /dev/${SERIAL_TTY} 2>/dev/null || true; fi'
${SERIAL_TTY}::respawn:/sbin/getty -L ${SERIAL_BAUD} ${SERIAL_TTY} ${SERIAL_TERM}

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

for svc in devfs dmesg procfs sysfs; do
  enable_service "$svc" sysinit
done
for svc in modules sysctl hostname bootmisc swclock localmount; do
  enable_service "$svc" boot
done
enable_service apkovl-restore boot
for svc in networking sshd avahi-daemon; do
  enable_service "$svc" default
done
for svc in $BOARD_BOOT_SERVICES; do
  enable_service "$svc" boot
done
if [ "$ENFORCE_IMMUTABLE_ROOT" = "1" ] && [ -n "$BOARD_IMMUTABLE_ROOT_SERVICE" ]; then
  enable_service "$BOARD_IMMUTABLE_ROOT_SERVICE" boot
fi

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
  mkdir -p "$ROOTFS_DIR/etc/conf.d"
  cat >"$ROOTFS_DIR/etc/conf.d/$NET_BANNER_SERVICE_NAME" <<EOF
serial_tty="${SERIAL_TTY}"
wait_seconds=40
banner_title="${BOOT_BANNER_TITLE}"
EOF
  enable_service "$NET_BANNER_SERVICE_NAME" default
fi

if [ "$ENABLE_BOOT_NTP_SYNC" = "1" ]; then
  mkdir -p "$ROOTFS_DIR/etc/conf.d"
  cat >"$ROOTFS_DIR/etc/conf.d/$BOOT_NTP_SERVICE_NAME" <<EOF
# Space-separated list of NTP servers for one-shot boot sync.
servers="${BOOT_NTP_SERVERS}"
EOF
  enable_service "$BOOT_NTP_SERVICE_NAME" default
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
