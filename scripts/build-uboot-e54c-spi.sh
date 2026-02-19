#!/usr/bin/env bash
set -euo pipefail

export PATH="$PATH:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

UBOOT_REPO="${UBOOT_REPO:-https://github.com/radxa/u-boot.git}"
UBOOT_BRANCH="${UBOOT_BRANCH:-next-dev-v2024.10}"
UBOOT_DEFCONFIG="${UBOOT_DEFCONFIG:-radxa-e54c-spi-rk3588s_defconfig}"
UBOOT_WORKDIR="${UBOOT_WORKDIR:-$REPO_ROOT/build/u-boot-src/radxa-u-boot}"
PATCH_FILE="${PATCH_FILE:-$REPO_ROOT/assets/reference/u-boot/patches/0001-e54c-enable-usb-host-in-uboot-dts.patch}"
OUT_ROOT="${OUT_ROOT:-$REPO_ROOT/build/u-boot-artifacts}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"
SPI_IDBLOADER_LBA="${SPI_IDBLOADER_LBA:-64}"
SPI_UBOOT_ITB_LBA="${SPI_UBOOT_ITB_LBA:-16384}"
SPI_IMAGE_SIZE_BYTES="${SPI_IMAGE_SIZE_BYTES:-16777216}"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

for cmd in git make "${CROSS_COMPILE}gcc" dtc awk sed python3 stat; do
  require_cmd "$cmd"
done

if [ ! -f "$PATCH_FILE" ]; then
  echo "Patch file not found: $PATCH_FILE" >&2
  exit 1
fi

mkdir -p "$(dirname "$UBOOT_WORKDIR")" "$OUT_ROOT"

if [ ! -d "$UBOOT_WORKDIR/.git" ]; then
  git clone "$UBOOT_REPO" "$UBOOT_WORKDIR"
fi

git -C "$UBOOT_WORKDIR" fetch --tags origin
git -C "$UBOOT_WORKDIR" checkout -B "$UBOOT_BRANCH" "origin/$UBOOT_BRANCH"

if git -C "$UBOOT_WORKDIR" apply --check "$PATCH_FILE" >/dev/null 2>&1; then
  git -C "$UBOOT_WORKDIR" apply "$PATCH_FILE"
  PATCH_STATE="applied"
elif git -C "$UBOOT_WORKDIR" apply -R --check "$PATCH_FILE" >/dev/null 2>&1; then
  PATCH_STATE="already-applied"
else
  echo "Patch does not apply cleanly against $UBOOT_BRANCH: $PATCH_FILE" >&2
  exit 1
fi

echo "Patch state: $PATCH_STATE"
echo "Building U-Boot ($UBOOT_DEFCONFIG, branch $UBOOT_BRANCH)..."

make -C "$UBOOT_WORKDIR" distclean
make -C "$UBOOT_WORKDIR" CROSS_COMPILE="$CROSS_COMPILE" "$UBOOT_DEFCONFIG"
make -C "$UBOOT_WORKDIR" -j"$JOBS" CROSS_COMPILE="$CROSS_COMPILE" all
make -C "$UBOOT_WORKDIR" -j"$JOBS" CROSS_COMPILE="$CROSS_COMPILE" u-boot.itb

if [ ! -f "$UBOOT_WORKDIR/u-boot.itb" ]; then
  echo "Build did not produce u-boot.itb" >&2
  exit 1
fi

UBOOT_VER="$(make -C "$UBOOT_WORKDIR" -s ubootversion || true)"
SRC_SHA="$(git -C "$UBOOT_WORKDIR" rev-parse --short HEAD)"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
ARTIFACT_DIR="$OUT_ROOT/e54c-spi-usbfix-${STAMP}"
mkdir -p "$ARTIFACT_DIR"

copy_if_exists() {
  local src="$1"
  local dst="$2"
  if [ -f "$src" ]; then
    cp "$src" "$dst"
  fi
}

copy_if_exists "$UBOOT_WORKDIR/u-boot.itb" "$ARTIFACT_DIR/u-boot.itb"
copy_if_exists "$UBOOT_WORKDIR/u-boot.bin" "$ARTIFACT_DIR/u-boot.bin"
copy_if_exists "$UBOOT_WORKDIR/u-boot.dtb" "$ARTIFACT_DIR/u-boot.dtb"
copy_if_exists "$UBOOT_WORKDIR/spl/u-boot-spl.bin" "$ARTIFACT_DIR/u-boot-spl.bin"
copy_if_exists "$UBOOT_WORKDIR/tpl/u-boot-tpl.bin" "$ARTIFACT_DIR/u-boot-tpl.bin"

# Fallback SPL-based idbloader image (some deployments still use vendor idbloader).
if [ -f "$UBOOT_WORKDIR/spl/u-boot-spl.bin" ] && [ -x "$UBOOT_WORKDIR/tools/mkimage" ]; then
  "$UBOOT_WORKDIR/tools/mkimage" -n rk3588 -T rksd -d "$UBOOT_WORKDIR/spl/u-boot-spl.bin" \
    "$ARTIFACT_DIR/idbloader-spl.img" >/dev/null
fi

# Preserve vendor idbloader as compatibility fallback for SPI flashing offsets.
if [ -f "$REPO_ROOT/assets/reference/u-boot/idbloader.img" ]; then
  cp "$REPO_ROOT/assets/reference/u-boot/idbloader.img" "$ARTIFACT_DIR/idbloader.vendor.img"
fi

IDBLOADER_FOR_SPI=""
if [ -f "$ARTIFACT_DIR/idbloader.vendor.img" ]; then
  IDBLOADER_FOR_SPI="$ARTIFACT_DIR/idbloader.vendor.img"
elif [ -f "$ARTIFACT_DIR/idbloader-spl.img" ]; then
  IDBLOADER_FOR_SPI="$ARTIFACT_DIR/idbloader-spl.img"
else
  echo "No idbloader image available for SPI image assembly." >&2
  exit 1
fi

SPI_IMAGE_PATH="$ARTIFACT_DIR/spi-u-boot-16MiB.img"
python3 - "$SPI_IMAGE_PATH" "$SPI_IMAGE_SIZE_BYTES" <<'PY'
import pathlib
import sys

out_path = pathlib.Path(sys.argv[1])
size = int(sys.argv[2], 10)
chunk = b"\xff" * (1024 * 1024)
remaining = size
with out_path.open("wb") as f:
    while remaining > 0:
        part = chunk if remaining >= len(chunk) else b"\xff" * remaining
        f.write(part)
        remaining -= len(part)
PY

IDBLOADER_SIZE="$(stat -c%s "$IDBLOADER_FOR_SPI")"
UBOOT_ITB_SIZE="$(stat -c%s "$ARTIFACT_DIR/u-boot.itb")"
IDBLOADER_OFFSET_BYTES="$((SPI_IDBLOADER_LBA * 512))"
UBOOT_ITB_OFFSET_BYTES="$((SPI_UBOOT_ITB_LBA * 512))"

if [ $((IDBLOADER_OFFSET_BYTES + IDBLOADER_SIZE)) -gt "$SPI_IMAGE_SIZE_BYTES" ]; then
  echo "idbloader does not fit in SPI image size ($SPI_IMAGE_SIZE_BYTES bytes)." >&2
  exit 1
fi
if [ $((UBOOT_ITB_OFFSET_BYTES + UBOOT_ITB_SIZE)) -gt "$SPI_IMAGE_SIZE_BYTES" ]; then
  echo "u-boot.itb does not fit in SPI image size ($SPI_IMAGE_SIZE_BYTES bytes)." >&2
  exit 1
fi

dd conv=notrunc if="$IDBLOADER_FOR_SPI" of="$SPI_IMAGE_PATH" bs=512 seek="$SPI_IDBLOADER_LBA" status=none
dd conv=notrunc if="$ARTIFACT_DIR/u-boot.itb" of="$SPI_IMAGE_PATH" bs=512 seek="$SPI_UBOOT_ITB_LBA" status=none

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$SPI_IMAGE_PATH" >"$ARTIFACT_DIR/spi-u-boot-16MiB.img.sha256"
fi

DTS_CHECK="$ARTIFACT_DIR/u-boot.dts.dec"
dtc -I dtb -O dts -o "$DTS_CHECK" "$ARTIFACT_DIR/u-boot.dtb" >/dev/null 2>&1 || true

{
  echo "branch=$UBOOT_BRANCH"
  echo "source_commit=$SRC_SHA"
  echo "u_boot_version=$UBOOT_VER"
  echo "defconfig=$UBOOT_DEFCONFIG"
  echo "patch_file=$PATCH_FILE"
  echo "patch_state=$PATCH_STATE"
  echo "cross_compile=$CROSS_COMPILE"
  echo "spi_idbloader_source=$IDBLOADER_FOR_SPI"
  echo "spi_idbloader_lba=$SPI_IDBLOADER_LBA"
  echo "spi_u_boot_itb_lba=$SPI_UBOOT_ITB_LBA"
  echo "spi_image_size_bytes=$SPI_IMAGE_SIZE_BYTES"
  echo "spi_image_file=$SPI_IMAGE_PATH"
  echo "source_dts_evidence:"
  grep -E "vcc5v0_usb_hub|vcc5v0_usb3_host|u2phy2_host|u2phy3_host|usb_host0_ehci|usb_host1_ehci|usbhost3_0|usbhost_dwc3_0" \
    "$UBOOT_WORKDIR/arch/arm/dts/rk3588s-radxa-e54c.dts" || true
  if [ -f "$DTS_CHECK" ]; then
    echo "decompiled_dtb_evidence:"
    grep -E "vcc5v0_usb_hub|vcc5v0_usb3_host" "$DTS_CHECK" || true
  fi
} >"$ARTIFACT_DIR/build-info.txt"

echo "U-Boot build complete."
echo "Artifacts: $ARTIFACT_DIR"
echo "Key files:"
echo "  - $SPI_IMAGE_PATH"
echo "  - $ARTIFACT_DIR/u-boot.itb"
if [ -f "$ARTIFACT_DIR/idbloader.vendor.img" ]; then
  echo "  - $ARTIFACT_DIR/idbloader.vendor.img"
fi
