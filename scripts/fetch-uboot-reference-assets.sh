#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

export PATH="$PATH:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/board-config.sh"
load_board_config

UBOOT_ASSETS_DIR="${UBOOT_ASSETS_DIR:-${BOARD_UBOOT_ASSETS_DIR:-$REPO_ROOT/assets/reference/u-boot}}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$REPO_ROOT/build/downloads}"
SPI_BASE_IMAGE_FILENAME="${SPI_BASE_IMAGE_FILENAME:-${BOARD_SPI_BASE_IMAGE_FILENAME_DEFAULT:-radxa-$BOARD-spi-base.img}}"
SPI_BASE_IMAGE_URL="${SPI_BASE_IMAGE_URL:-${BOARD_SPI_BASE_IMAGE_URL_DEFAULT:-}}"
SPI_BASE_IMAGE_PATH="${SPI_BASE_IMAGE_PATH:-$DOWNLOAD_DIR/$SPI_BASE_IMAGE_FILENAME}"
SPI_IMAGE_SIZE_BYTES="${SPI_IMAGE_SIZE_BYTES:-${BOARD_SPI_IMAGE_SIZE_BYTES_DEFAULT:-16777216}}"
SPI_IDBLOADER_LBA="${SPI_IDBLOADER_LBA:-${BOARD_SPI_IDBLOADER_LBA_DEFAULT:-64}}"
SPI_UBOOT_ITB_LBA="${SPI_UBOOT_ITB_LBA:-${BOARD_SPI_UBOOT_ITB_LBA_DEFAULT:-16384}}"
IDBLOADER_SIZE_BYTES="${IDBLOADER_SIZE_BYTES:-${BOARD_IDBLOADER_SIZE_BYTES_DEFAULT:-319488}}"
UBOOT_ITB_SIZE_BYTES="${UBOOT_ITB_SIZE_BYTES:-${BOARD_UBOOT_ITB_SIZE_BYTES_DEFAULT:-1484288}}"

FORCE_DOWNLOAD=0
FORCE_OVERWRITE=0

usage() {
  cat <<'EOF'
Usage: scripts/fetch-uboot-reference-assets.sh [--force-download] [--force-overwrite]

Downloads board SPI image and extracts:
  - idbloader.img
  - u-boot.itb

Destination:
  board-specific UBOOT_ASSETS_DIR

Environment overrides:
  UBOOT_ASSETS_DIR
  DOWNLOAD_DIR
  SPI_BASE_IMAGE_URL
  SPI_BASE_IMAGE_FILENAME
  SPI_BASE_IMAGE_PATH
  SPI_IMAGE_SIZE_BYTES
  SPI_IDBLOADER_LBA
  SPI_UBOOT_ITB_LBA
  IDBLOADER_SIZE_BYTES
  UBOOT_ITB_SIZE_BYTES
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
require_cmd dd
require_cmd truncate
require_cmd stat

mkdir -p "$DOWNLOAD_DIR" "$UBOOT_ASSETS_DIR"

required_assets_ready=1
for asset in idbloader.img u-boot.itb; do
  if [ ! -f "$UBOOT_ASSETS_DIR/$asset" ]; then
    required_assets_ready=0
    break
  fi
done
if [ "$required_assets_ready" -eq 1 ] && [ "$FORCE_OVERWRITE" -ne 1 ]; then
  echo "Required U-Boot assets already present in: $UBOOT_ASSETS_DIR"
  exit 0
fi

SPI_CHECKED=0
SPI_AVAILABLE=0

download_spi_base_if_needed() {
  if [ "$SPI_CHECKED" -eq 1 ]; then
    [ "$SPI_AVAILABLE" -eq 1 ]
    return
  fi
  SPI_CHECKED=1

  if [ ! -f "$SPI_BASE_IMAGE_PATH" ] || [ "$FORCE_DOWNLOAD" -eq 1 ]; then
    if [ -z "$SPI_BASE_IMAGE_URL" ]; then
      echo "SPI_BASE_IMAGE_URL is not set for BOARD=$BOARD and no local SPI_BASE_IMAGE_PATH exists." >&2
      return 1
    fi
    echo "Downloading board SPI base image:"
    echo "  URL:  $SPI_BASE_IMAGE_URL"
    echo "  PATH: $SPI_BASE_IMAGE_PATH"
    if ! curl -fL --retry 3 --retry-delay 2 "$SPI_BASE_IMAGE_URL" -o "$SPI_BASE_IMAGE_PATH"; then
      echo "Failed to download SPI base image: $SPI_BASE_IMAGE_URL" >&2
      SPI_AVAILABLE=0
      return 1
    fi
  else
    echo "Using existing SPI base image: $SPI_BASE_IMAGE_PATH"
  fi

  SPI_AVAILABLE=1
  return 0
}

extract_from_spi_image() {
  local asset_name="$1"
  local lba="$2"
  local size_bytes="$3"
  local target_path="$UBOOT_ASSETS_DIR/$asset_name"
  local sectors=0

  if [ -f "$target_path" ] && [ "$FORCE_OVERWRITE" -ne 1 ]; then
    echo "Keeping existing asset: $target_path"
    return 0
  fi

  if ! download_spi_base_if_needed; then
    return 1
  fi
  if [ "$(stat -c%s "$SPI_BASE_IMAGE_PATH")" -ne "$SPI_IMAGE_SIZE_BYTES" ]; then
    echo "Unexpected SPI image size: $(stat -c%s "$SPI_BASE_IMAGE_PATH") (expected $SPI_IMAGE_SIZE_BYTES)" >&2
    return 1
  fi

  sectors=$(((size_bytes + 511) / 512))
  dd if="$SPI_BASE_IMAGE_PATH" of="$target_path" bs=512 skip="$lba" count="$sectors" status=none
  truncate -s "$size_bytes" "$target_path"
  chmod 0644 "$target_path"
  echo "Installed from SPI image: $target_path"
}

if [ ! -f "$UBOOT_ASSETS_DIR/idbloader.img" ] || [ "$FORCE_OVERWRITE" -eq 1 ]; then
  extract_from_spi_image "idbloader.img" "$SPI_IDBLOADER_LBA" "$IDBLOADER_SIZE_BYTES"
fi

if [ ! -f "$UBOOT_ASSETS_DIR/u-boot.itb" ] || [ "$FORCE_OVERWRITE" -eq 1 ]; then
  extract_from_spi_image "u-boot.itb" "$SPI_UBOOT_ITB_LBA" "$UBOOT_ITB_SIZE_BYTES"
fi

if [ ! -f "$UBOOT_ASSETS_DIR/idbloader.img" ] || [ ! -f "$UBOOT_ASSETS_DIR/u-boot.itb" ]; then
  echo "Failed to prepare required U-Boot assets (idbloader.img, u-boot.itb)." >&2
  exit 1
fi

echo "U-Boot reference assets are ready in: $UBOOT_ASSETS_DIR"
