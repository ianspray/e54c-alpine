#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

export PATH="$PATH:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

UBOOT_ASSETS_DIR="${UBOOT_ASSETS_DIR:-$REPO_ROOT/assets/reference/u-boot}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$REPO_ROOT/build/downloads}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
ALPINE_BRANCH="${ALPINE_BRANCH:-v3.23}"
ALPINE_VERSION="${ALPINE_VERSION:-3.23.3}"
ALPINE_ARCH="${ALPINE_ARCH:-aarch64}"
UBOOT_BUNDLE_NAME="${UBOOT_BUNDLE_NAME:-alpine-uboot-${ALPINE_VERSION}-${ALPINE_ARCH}.tar.gz}"
UBOOT_BUNDLE_URL="${UBOOT_BUNDLE_URL:-${ALPINE_MIRROR}/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/${UBOOT_BUNDLE_NAME}}"
UBOOT_BUNDLE_PATH="${UBOOT_BUNDLE_PATH:-$DOWNLOAD_DIR/$UBOOT_BUNDLE_NAME}"

FORCE_DOWNLOAD=0
FORCE_OVERWRITE=0

usage() {
  cat <<'EOF'
Usage: scripts/fetch-uboot-reference-assets.sh [--force-download] [--force-overwrite]

Downloads Alpine U-Boot bundle and extracts:
  - idbloader.img
  - u-boot.itb
  - rkboot.bin

Destination:
  assets/reference/u-boot/

Environment overrides:
  UBOOT_ASSETS_DIR
  DOWNLOAD_DIR
  ALPINE_MIRROR
  ALPINE_BRANCH
  ALPINE_VERSION
  ALPINE_ARCH
  UBOOT_BUNDLE_NAME
  UBOOT_BUNDLE_URL
  UBOOT_BUNDLE_PATH
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --force-download)
      FORCE_DOWNLOAD=1
      ;;
    --force-overwrite)
      FORCE_OVERWRITE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

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
require_cmd mktemp

mkdir -p "$DOWNLOAD_DIR" "$UBOOT_ASSETS_DIR"

if [ ! -f "$UBOOT_BUNDLE_PATH" ] || [ "$FORCE_DOWNLOAD" -eq 1 ]; then
  echo "Downloading U-Boot bundle:"
  echo "  URL:  $UBOOT_BUNDLE_URL"
  echo "  PATH: $UBOOT_BUNDLE_PATH"
  curl -fL --retry 3 --retry-delay 2 "$UBOOT_BUNDLE_URL" -o "$UBOOT_BUNDLE_PATH"
else
  echo "Using existing bundle: $UBOOT_BUNDLE_PATH"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

find_asset_path_in_tar() {
  local tar_path="$1"
  local asset_name="$2"
  tar -tzf "$tar_path" | awk -v n="$asset_name" '$0 ~ ("(^|/)" n "$") { print; exit }'
}

extract_asset() {
  local asset_name="$1"
  local target_path="$UBOOT_ASSETS_DIR/$asset_name"
  local tar_member=""

  if [ -f "$target_path" ] && [ "$FORCE_OVERWRITE" -ne 1 ]; then
    echo "Keeping existing asset: $target_path"
    return 0
  fi

  tar_member="$(find_asset_path_in_tar "$UBOOT_BUNDLE_PATH" "$asset_name")"
  if [ -z "$tar_member" ]; then
    echo "Asset '$asset_name' not found in $UBOOT_BUNDLE_PATH" >&2
    return 1
  fi

  tar -xzf "$UBOOT_BUNDLE_PATH" -C "$tmp_dir" "$tar_member"
  cp -f "$tmp_dir/$tar_member" "$target_path"
  chmod 0644 "$target_path"
  echo "Installed: $target_path"
}

extract_asset "idbloader.img"
extract_asset "u-boot.itb"
extract_asset "rkboot.bin"

echo "U-Boot reference assets are ready in: $UBOOT_ASSETS_DIR"
