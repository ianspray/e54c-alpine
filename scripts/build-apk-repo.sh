#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APK_APORTS_ROOT="${APK_APORTS_ROOT:-$REPO_ROOT/apk/aports}"
APK_REPO_BRANCH="${APK_REPO_BRANCH:-v3.23}"
APK_ARCH="${APK_ARCH:-aarch64}"
APK_REPO_OUT="${APK_REPO_OUT:-$REPO_ROOT/build/apk-repo}"
APK_KEYS_DIR="${APK_KEYS_DIR:-$REPO_ROOT/build/apk-keys}"
APK_KEYS_EXPORT_DIR="${APK_KEYS_EXPORT_DIR:-$REPO_ROOT/assets/reference/alpine/custom-keys}"
APK_PODMAN_IMAGE="${APK_PODMAN_IMAGE:-docker.io/library/alpine:3.23}"
APK_PODMAN_ARCH="${APK_PODMAN_ARCH:-}"
APK_PODMAN_NETWORK="${APK_PODMAN_NETWORK:-host}"
APK_REFRESH_CHECKSUMS="${APK_REFRESH_CHECKSUMS:-1}"
APK_RETRY_COUNT="${APK_RETRY_COUNT:-5}"
APK_RETRY_DELAY_SEC="${APK_RETRY_DELAY_SEC:-3}"

if [ -z "$APK_PODMAN_ARCH" ]; then
  case "$APK_ARCH" in
    aarch64) APK_PODMAN_ARCH="arm64" ;;
    x86_64) APK_PODMAN_ARCH="amd64" ;;
    *)
      echo "Unsupported APK_ARCH for container mapping: $APK_ARCH" >&2
      echo "Set APK_PODMAN_ARCH explicitly if this arch should be supported." >&2
      exit 1
      ;;
  esac
fi

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

require_cmd podman
require_cmd find
require_cmd sort

retry_cmd() {
  local tries="$1"
  local delay="$2"
  shift 2
  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -ge "$tries" ]; then
      return 1
    fi
    echo "Command failed (attempt ${attempt}/${tries}), retrying in ${delay}s: $*" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

if [ ! -d "$APK_APORTS_ROOT" ]; then
  echo "APK_APORTS_ROOT does not exist: $APK_APORTS_ROOT" >&2
  exit 1
fi

mapfile -t apkbuild_files < <(find "$APK_APORTS_ROOT" -mindepth 3 -maxdepth 3 -type f -name APKBUILD | sort)
if [ "${#apkbuild_files[@]}" -eq 0 ]; then
  echo "No APKBUILD files found under $APK_APORTS_ROOT" >&2
  exit 1
fi

echo "Building custom APK repository"
echo "  APKBUILD count: ${#apkbuild_files[@]}"
echo "  Branch/arch:    ${APK_REPO_BRANCH}/${APK_ARCH}"
echo "  Container arch: ${APK_PODMAN_ARCH}"
echo "  Refresh sums:   ${APK_REFRESH_CHECKSUMS}"
echo "  Output:         ${APK_REPO_OUT}"

mkdir -p "$APK_REPO_OUT" "$APK_KEYS_DIR" "$APK_KEYS_EXPORT_DIR"
chmod 0777 "$APK_REPO_OUT" "$APK_KEYS_DIR"

repo_arch_dir="$APK_REPO_OUT/$APK_REPO_BRANCH/$APK_ARCH"
mkdir -p "$repo_arch_dir"
rm -f "$repo_arch_dir"/*.apk "$repo_arch_dir"/APKINDEX.tar.gz "$repo_arch_dir"/APKINDEX.tar.gz.sig

CONTAINER_SCRIPT='set -euo pipefail

retry_apk() {
  tries="${APK_RETRY_COUNT:-5}"
  delay="${APK_RETRY_DELAY_SEC:-3}"
  attempt=1
  while true; do
    if apk "$@"; then
      return 0
    fi
    if [ "$attempt" -ge "$tries" ]; then
      return 1
    fi
    echo "apk $* failed (attempt ${attempt}/${tries}), retrying in ${delay}s" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

retry_apk update
retry_apk add alpine-sdk bash

if ! id builder >/dev/null 2>&1; then
  adduser -D builder
fi
addgroup builder abuild >/dev/null 2>&1 || true

install -d -m 700 -o builder -g builder /home/builder/.abuild
install -d -m 0777 /work/out /work/keys

if ls /work/keys/*.rsa >/dev/null 2>&1 && ls /work/keys/*.rsa.pub >/dev/null 2>&1; then
  cp -f /work/keys/*.rsa /home/builder/.abuild/
  cp -f /work/keys/*.rsa.pub /home/builder/.abuild/
  chown builder:builder /home/builder/.abuild/*
else
  su builder -c "abuild-keygen -a -n"
  cp -f /home/builder/.abuild/*.rsa /work/keys/
  cp -f /home/builder/.abuild/*.rsa.pub /work/keys/
fi

key_file="$(ls /home/builder/.abuild/*.rsa | head -n1)"
echo "PACKAGER_PRIVKEY=\"$key_file\"" >/home/builder/.abuild/abuild.conf
chown builder:builder /home/builder/.abuild/abuild.conf

cp -f /home/builder/.abuild/*.rsa.pub /etc/apk/keys/ || true

repo_arch_dir="/work/out/${APK_REPO_BRANCH}/${APK_ARCH}"
mkdir -p "$repo_arch_dir" /work/out/keys
rm -f "$repo_arch_dir"/*.apk "$repo_arch_dir"/APKINDEX.tar.gz "$repo_arch_dir"/APKINDEX.tar.gz.sig

for apkbuild in /work/aports/*/*/APKBUILD; do
  [ -f "$apkbuild" ] || continue
  pkgsrc="$(dirname "$apkbuild")"
  pkgname="$(basename "$pkgsrc")"
  builddir="/tmp/aport-$pkgname"
  rm -rf "$builddir"
  mkdir -p "$builddir"
  cp -a "$pkgsrc"/. "$builddir"/
  chown -R builder:builder "$builddir"
  if [ "${APK_REFRESH_CHECKSUMS:-0}" = "1" ]; then
    su builder -c "cd $builddir && CARCH=$APK_ARCH abuild checksum"
  fi
  su builder -c "cd $builddir && CARCH=$APK_ARCH abuild -r"
done

builder_repo_dir="/home/builder/packages/tmp/${APK_ARCH}"
if [ ! -d "$builder_repo_dir" ]; then
  echo "Builder repository not found: $builder_repo_dir" >&2
  exit 1
fi

if ! ls "$builder_repo_dir"/*.apk >/dev/null 2>&1; then
  echo "No APKs produced for APK_ARCH=$APK_ARCH in $builder_repo_dir" >&2
  echo "Check build logs above for architecture mismatches or package postcheck failures." >&2
  exit 1
fi

cp -f "$builder_repo_dir"/*.apk "$repo_arch_dir"/
cp -f "$builder_repo_dir"/APKINDEX.tar.gz "$repo_arch_dir"/

cp -f /home/builder/.abuild/*.rsa.pub /work/out/keys/
cp -f /home/builder/.abuild/*.rsa.pub /work/keys/
'

retry_cmd "$APK_RETRY_COUNT" "$APK_RETRY_DELAY_SEC" \
  podman run --rm \
    --arch "$APK_PODMAN_ARCH" \
    --network "$APK_PODMAN_NETWORK" \
    -e APK_REPO_BRANCH="$APK_REPO_BRANCH" \
    -e APK_ARCH="$APK_ARCH" \
    -e APK_REFRESH_CHECKSUMS="$APK_REFRESH_CHECKSUMS" \
    -e APK_RETRY_COUNT="$APK_RETRY_COUNT" \
    -e APK_RETRY_DELAY_SEC="$APK_RETRY_DELAY_SEC" \
    -v "$APK_APORTS_ROOT:/work/aports:ro" \
    -v "$APK_REPO_OUT:/work/out" \
    -v "$APK_KEYS_DIR:/work/keys" \
    "$APK_PODMAN_IMAGE" \
    sh -c "$CONTAINER_SCRIPT"

copied_keys=0
while IFS= read -r pubkey; do
  cp -f "$pubkey" "$APK_KEYS_EXPORT_DIR/"
  copied_keys=1
done < <(find "$APK_REPO_OUT/keys" -maxdepth 1 -type f -name '*.rsa.pub' | sort)

if [ "$copied_keys" -eq 1 ]; then
  echo "Exported public signing keys to: $APK_KEYS_EXPORT_DIR"
fi

echo "Custom APK repository ready: $repo_arch_dir"
echo "Add this repository URL/path to: assets/reference/alpine/custom-repositories.txt"
echo "Add shared custom package names to: boards/alpian/alpine/custom-packages.txt"
echo "Add board-specific package names to: boards/<board>/alpine/custom-packages.txt"
echo "  (legacy shared fallback:          assets/reference/alpine/custom-packages.txt)"
echo "Then rebuild rootfs/image with scripts/prepare-alpian-rootfs.sh and scripts/assemble-image.sh"
