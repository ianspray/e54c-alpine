#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

export PATH="$PATH:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/board-config.sh"
load_board_config

UBOOT_FETCH_PROFILE="${UBOOT_FETCH_PROFILE:-${BOARD_UBOOT_FETCH_PROFILE:-$REPO_ROOT/boards/$BOARD/u-boot-fetch.env}}"
if [ -f "$UBOOT_FETCH_PROFILE" ]; then
  # shellcheck disable=SC1090
  source "$UBOOT_FETCH_PROFILE"
fi

UBOOT_ASSETS_DIR="${UBOOT_ASSETS_DIR:-${BOARD_UBOOT_ASSETS_DIR:-$REPO_ROOT/assets/reference/u-boot}}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$REPO_ROOT/build/downloads}"
UBOOT_FETCH_MODE="${UBOOT_FETCH_MODE:-spi-image}"
SPI_BASE_IMAGE_FILENAME="${SPI_BASE_IMAGE_FILENAME:-${BOARD_SPI_BASE_IMAGE_FILENAME_DEFAULT:-radxa-$BOARD-spi-base.img}}"
SPI_BASE_IMAGE_URL="${SPI_BASE_IMAGE_URL:-${BOARD_SPI_BASE_IMAGE_URL_DEFAULT:-}}"
SPI_BASE_IMAGE_PATH="${SPI_BASE_IMAGE_PATH:-$DOWNLOAD_DIR/$SPI_BASE_IMAGE_FILENAME}"
DISK_IMAGE_FILENAME="${DISK_IMAGE_FILENAME:-${BOARD_DISK_IMAGE_FILENAME_DEFAULT:-}}"
DISK_IMAGE_URL="${DISK_IMAGE_URL:-${BOARD_DISK_IMAGE_URL_DEFAULT:-}}"
DISK_IMAGE_PATH="${DISK_IMAGE_PATH:-${DISK_IMAGE_FILENAME:+$DOWNLOAD_DIR/$DISK_IMAGE_FILENAME}}"
SPI_IMAGE_SIZE_BYTES="${SPI_IMAGE_SIZE_BYTES:-${BOARD_SPI_IMAGE_SIZE_BYTES_DEFAULT:-16777216}}"
SPI_IDBLOADER_LBA="${SPI_IDBLOADER_LBA:-${BOARD_SPI_IDBLOADER_LBA_DEFAULT:-64}}"
SPI_UBOOT_ITB_LBA="${SPI_UBOOT_ITB_LBA:-${BOARD_SPI_UBOOT_ITB_LBA_DEFAULT:-16384}}"
IDBLOADER_SIZE_BYTES="${IDBLOADER_SIZE_BYTES:-${BOARD_IDBLOADER_SIZE_BYTES_DEFAULT:-319488}}"
UBOOT_ITB_SIZE_BYTES="${UBOOT_ITB_SIZE_BYTES:-${BOARD_UBOOT_ITB_SIZE_BYTES_DEFAULT:-1484288}}"
UBOOT_ARCHIVE_FILENAME="${UBOOT_ARCHIVE_FILENAME:-${BOARD_UBOOT_ARCHIVE_FILENAME_DEFAULT:-}}"
UBOOT_ARCHIVE_URL="${UBOOT_ARCHIVE_URL:-${BOARD_UBOOT_ARCHIVE_URL_DEFAULT:-}}"
UBOOT_ARCHIVE_PATH="${UBOOT_ARCHIVE_PATH:-${UBOOT_ARCHIVE_FILENAME:+$DOWNLOAD_DIR/$UBOOT_ARCHIVE_FILENAME}}"
UBOOT_ARCHIVE_IDBLOADER_MEMBER="${UBOOT_ARCHIVE_IDBLOADER_MEMBER:-${BOARD_UBOOT_ARCHIVE_IDBLOADER_MEMBER_DEFAULT:-}}"
UBOOT_ARCHIVE_UBOOT_MEMBER="${UBOOT_ARCHIVE_UBOOT_MEMBER:-${BOARD_UBOOT_ARCHIVE_UBOOT_MEMBER_DEFAULT:-}}"
BOOTLOADER_MODE="${BOOTLOADER_MODE:-${BOARD_BOOTLOADER_MODE:-spi-dd}}"

FORCE_DOWNLOAD=0
FORCE_OVERWRITE=0

usage() {
  cat <<'EOF'
Usage: scripts/fetch-uboot-reference-assets.sh [--force-download] [--force-overwrite]

Downloads a board bootloader source image/archive and extracts:
  - idbloader.img
  - u-boot.itb

Destination:
  board-specific UBOOT_ASSETS_DIR

Environment overrides:
  UBOOT_ASSETS_DIR
  DOWNLOAD_DIR
  UBOOT_FETCH_PROFILE
  SPI_BASE_IMAGE_URL
  SPI_BASE_IMAGE_FILENAME
  SPI_BASE_IMAGE_PATH
  DISK_IMAGE_URL
  DISK_IMAGE_FILENAME
  DISK_IMAGE_PATH
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
require_cmd stat

case "$UBOOT_FETCH_MODE" in
  spi-image)
    require_cmd dd
    require_cmd truncate
    ;;
  compressed-disk-image)
    require_cmd dd
    require_cmd truncate
    require_cmd xz
    ;;
  archive-members)
    require_cmd tar
    ;;
  *)
    echo "Unsupported UBOOT_FETCH_MODE: $UBOOT_FETCH_MODE" >&2
    exit 1
    ;;
esac

mkdir -p "$DOWNLOAD_DIR" "$UBOOT_ASSETS_DIR"

if [ "$BOOTLOADER_MODE" = "none" ]; then
  if [ ! -f "$UBOOT_ASSETS_DIR/idbloader.img" ]; then
    : >"$UBOOT_ASSETS_DIR/idbloader.img"
  fi
  if [ ! -f "$UBOOT_ASSETS_DIR/u-boot.itb" ]; then
    : >"$UBOOT_ASSETS_DIR/u-boot.itb"
  fi
  chmod 0644 "$UBOOT_ASSETS_DIR/idbloader.img" "$UBOOT_ASSETS_DIR/u-boot.itb"
  echo "Board $BOARD uses BOOTLOADER_MODE=none; created placeholder assets in $UBOOT_ASSETS_DIR"
  exit 0
fi

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

SOURCE_CHECKED=0
SOURCE_AVAILABLE=0

download_source_if_needed() {
  local url="$1"
  local path="$2"
  local label="$3"

  if [ "$SOURCE_CHECKED" -eq 1 ]; then
    [ "$SOURCE_AVAILABLE" -eq 1 ]
    return
  fi
  SOURCE_CHECKED=1

  if [ ! -f "$path" ] || [ "$FORCE_DOWNLOAD" -eq 1 ]; then
    if [ -z "$url" ]; then
      echo "$label URL is not set for BOARD=$BOARD and no local source path exists." >&2
      return 1
    fi
    echo "Downloading board bootloader source:"
    echo "  KIND: $label"
    echo "  URL:  $url"
    echo "  PATH: $path"
    if ! curl -fL --retry 3 --retry-delay 2 "$url" -o "$path"; then
      echo "Failed to download bootloader source: $url" >&2
      SOURCE_AVAILABLE=0
      return 1
    fi
  else
    echo "Using existing bootloader source: $path"
  fi

  SOURCE_AVAILABLE=1
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

  if ! download_source_if_needed "$SPI_BASE_IMAGE_URL" "$SPI_BASE_IMAGE_PATH" "spi-image"; then
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

extract_from_compressed_disk_image() {
  local asset_name="$1"
  local lba="$2"
  local size_bytes="$3"
  local target_path="$UBOOT_ASSETS_DIR/$asset_name"
  local sectors=0
  local saved_shellopts=""

  if [ -f "$target_path" ] && [ "$FORCE_OVERWRITE" -ne 1 ]; then
    echo "Keeping existing asset: $target_path"
    return 0
  fi

  if [ -z "$DISK_IMAGE_PATH" ]; then
    echo "Compressed disk image mode requires DISK_IMAGE_PATH or DISK_IMAGE_FILENAME for BOARD=$BOARD." >&2
    return 1
  fi

  if ! download_source_if_needed "$DISK_IMAGE_URL" "$DISK_IMAGE_PATH" "compressed-disk-image"; then
    return 1
  fi

  sectors=$(((size_bytes + 511) / 512))
  saved_shellopts="$(set +o)"
  set +o pipefail
  if ! xz -dc "$DISK_IMAGE_PATH" | dd of="$target_path" bs=512 skip="$lba" count="$sectors" status=none; then
    eval "$saved_shellopts"
    echo "Failed to extract $asset_name from compressed disk image: $DISK_IMAGE_PATH" >&2
    return 1
  fi
  eval "$saved_shellopts"
  truncate -s "$size_bytes" "$target_path"
  chmod 0644 "$target_path"
  echo "Installed from compressed disk image: $target_path"
}

extract_from_archive_member() {
  local asset_name="$1"
  local archive_member="$2"
  local expected_size="$3"
  local target_path="$UBOOT_ASSETS_DIR/$asset_name"

  if [ -f "$target_path" ] && [ "$FORCE_OVERWRITE" -ne 1 ]; then
    echo "Keeping existing asset: $target_path"
    return 0
  fi

  if [ -z "$UBOOT_ARCHIVE_PATH" ] || [ -z "$archive_member" ]; then
    echo "Archive fetch mode requires UBOOT_ARCHIVE_PATH and member names for BOARD=$BOARD." >&2
    return 1
  fi

  if ! download_source_if_needed "$UBOOT_ARCHIVE_URL" "$UBOOT_ARCHIVE_PATH" "archive-members"; then
    return 1
  fi

  tar -xOf "$UBOOT_ARCHIVE_PATH" "$archive_member" >"$target_path"
  chmod 0644 "$target_path"

  if [ -n "$expected_size" ] && [ "$(stat -c%s "$target_path")" -ne "$expected_size" ]; then
    echo "Unexpected extracted asset size for $asset_name: $(stat -c%s "$target_path") (expected $expected_size)" >&2
    return 1
  fi

  echo "Installed from archive member: $target_path"
}

case "$UBOOT_FETCH_MODE" in
  spi-image)
    if [ ! -f "$UBOOT_ASSETS_DIR/idbloader.img" ] || [ "$FORCE_OVERWRITE" -eq 1 ]; then
      extract_from_spi_image "idbloader.img" "$SPI_IDBLOADER_LBA" "$IDBLOADER_SIZE_BYTES"
    fi

    if [ ! -f "$UBOOT_ASSETS_DIR/u-boot.itb" ] || [ "$FORCE_OVERWRITE" -eq 1 ]; then
      extract_from_spi_image "u-boot.itb" "$SPI_UBOOT_ITB_LBA" "$UBOOT_ITB_SIZE_BYTES"
    fi
    ;;
  compressed-disk-image)
    if [ ! -f "$UBOOT_ASSETS_DIR/idbloader.img" ] || [ "$FORCE_OVERWRITE" -eq 1 ]; then
      extract_from_compressed_disk_image "idbloader.img" "$SPI_IDBLOADER_LBA" "$IDBLOADER_SIZE_BYTES"
    fi

    if [ ! -f "$UBOOT_ASSETS_DIR/u-boot.itb" ] || [ "$FORCE_OVERWRITE" -eq 1 ]; then
      extract_from_compressed_disk_image "u-boot.itb" "$SPI_UBOOT_ITB_LBA" "$UBOOT_ITB_SIZE_BYTES"
    fi
    ;;
  archive-members)
    if [ ! -f "$UBOOT_ASSETS_DIR/idbloader.img" ] || [ "$FORCE_OVERWRITE" -eq 1 ]; then
      extract_from_archive_member "idbloader.img" "$UBOOT_ARCHIVE_IDBLOADER_MEMBER" "$IDBLOADER_SIZE_BYTES"
    fi

    if [ ! -f "$UBOOT_ASSETS_DIR/u-boot.itb" ] || [ "$FORCE_OVERWRITE" -eq 1 ]; then
      extract_from_archive_member "u-boot.itb" "$UBOOT_ARCHIVE_UBOOT_MEMBER" "$UBOOT_ITB_SIZE_BYTES"
    fi
    ;;
esac

if [ ! -f "$UBOOT_ASSETS_DIR/idbloader.img" ] || [ ! -f "$UBOOT_ASSETS_DIR/u-boot.itb" ]; then
  echo "Failed to prepare required U-Boot assets (idbloader.img, u-boot.itb)." >&2
  exit 1
fi

echo "U-Boot reference assets are ready in: $UBOOT_ASSETS_DIR"
