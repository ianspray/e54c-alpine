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
SPI_IMAGE_STRATEGY="${SPI_IMAGE_STRATEGY:-base-image}"
SPI_UBOOT_SOURCE="${SPI_UBOOT_SOURCE:-base}"
SPI_BASE_IMAGE_URL="${SPI_BASE_IMAGE_URL:-https://dl.radxa.com/e/e54c/images/radxa-e54c-spi-flash-image.img}"
SPI_BASE_IMAGE_PATH="${SPI_BASE_IMAGE_PATH:-$REPO_ROOT/build/downloads/radxa-e54c-spi-flash-image.img}"

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
if [ "$SPI_IMAGE_STRATEGY" = "base-image" ]; then
  require_cmd curl
fi
case "$SPI_UBOOT_SOURCE" in
  base|build)
    ;;
  *)
    echo "Invalid SPI_UBOOT_SOURCE=$SPI_UBOOT_SOURCE (expected: base or build)" >&2
    exit 1
    ;;
esac

if [ ! -f "$PATCH_FILE" ]; then
  echo "Patch file not found: $PATCH_FILE" >&2
  exit 1
fi

fit_has_atf() {
  local fit_path="$1"
  local dumpimage_bin="$2"
  "$dumpimage_bin" -l "$fit_path" 2>/dev/null | grep -q "(atf-1)"
}

fit_find_image_index() {
  local fit_path="$1"
  local dumpimage_bin="$2"
  local image_name="$3"
  "$dumpimage_bin" -l "$fit_path" 2>/dev/null | sed -n "s/^ Image \\([0-9]\\+\\) (${image_name}).*/\\1/p" | head -n1
}

fit_find_load_addr() {
  local fit_path="$1"
  local dumpimage_bin="$2"
  local image_name="$3"
  "$dumpimage_bin" -l "$fit_path" 2>/dev/null | awk -v name="$image_name" '
    $0 ~ "\\("name"\\)" {in_image=1; next}
    in_image && /Load Address:/ {print $3; exit}
    in_image && /^ Image [0-9]+ \(/ {in_image=0}
  '
}

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

DUMPIMAGE_BIN="$UBOOT_WORKDIR/tools/dumpimage"
MKIMAGE_BIN="$UBOOT_WORKDIR/tools/mkimage"
if [ ! -x "$DUMPIMAGE_BIN" ] || [ ! -x "$MKIMAGE_BIN" ]; then
  echo "Expected U-Boot tools were not built: $DUMPIMAGE_BIN / $MKIMAGE_BIN" >&2
  exit 1
fi

ATF_REPACKED="0"
FIT_REPACK_REASON=""
if ! fit_has_atf "$UBOOT_WORKDIR/u-boot.itb" "$DUMPIMAGE_BIN"; then
  FIT_REPACK_REASON="missing-atf"
fi
if [ "$SPI_UBOOT_SOURCE" = "base" ]; then
  if [ -n "$FIT_REPACK_REASON" ]; then
    FIT_REPACK_REASON="$FIT_REPACK_REASON,base-uboot"
  else
    FIT_REPACK_REASON="base-uboot"
  fi
fi

if [ -n "$FIT_REPACK_REASON" ]; then
  if [ "$SPI_IMAGE_STRATEGY" != "base-image" ]; then
    echo "FIT repack required ($FIT_REPACK_REASON) but SPI_IMAGE_STRATEGY is not base-image." >&2
    echo "Set SPI_IMAGE_STRATEGY=base-image to repack from Radxa base SPI payloads." >&2
    exit 1
  fi

  mkdir -p "$(dirname "$SPI_BASE_IMAGE_PATH")"
  if [ ! -f "$SPI_BASE_IMAGE_PATH" ]; then
    echo "Downloading base SPI image: $SPI_BASE_IMAGE_URL"
    curl -fL "$SPI_BASE_IMAGE_URL" -o "$SPI_BASE_IMAGE_PATH"
  fi

  repack_dir="$(mktemp -d)"
  trap 'rm -rf "$repack_dir"' EXIT
  BASE_UBOOT_ITB="$repack_dir/base-u-boot.itb"
  dd if="$SPI_BASE_IMAGE_PATH" of="$BASE_UBOOT_ITB" bs=512 skip="$SPI_UBOOT_ITB_LBA" count=8192 status=none

  idx_uboot="$(fit_find_image_index "$BASE_UBOOT_ITB" "$DUMPIMAGE_BIN" "uboot")"
  idx_atf1="$(fit_find_image_index "$BASE_UBOOT_ITB" "$DUMPIMAGE_BIN" "atf-1")"
  idx_atf2="$(fit_find_image_index "$BASE_UBOOT_ITB" "$DUMPIMAGE_BIN" "atf-2")"
  idx_atf3="$(fit_find_image_index "$BASE_UBOOT_ITB" "$DUMPIMAGE_BIN" "atf-3")"
  if [ -z "$idx_uboot" ] || [ -z "$idx_atf1" ] || [ -z "$idx_atf2" ] || [ -z "$idx_atf3" ]; then
    echo "Failed to find required entries in base SPI image FIT." >&2
    exit 1
  fi

  load_uboot="$(fit_find_load_addr "$BASE_UBOOT_ITB" "$DUMPIMAGE_BIN" "uboot")"
  load_atf1="$(fit_find_load_addr "$BASE_UBOOT_ITB" "$DUMPIMAGE_BIN" "atf-1")"
  load_atf2="$(fit_find_load_addr "$BASE_UBOOT_ITB" "$DUMPIMAGE_BIN" "atf-2")"
  load_atf3="$(fit_find_load_addr "$BASE_UBOOT_ITB" "$DUMPIMAGE_BIN" "atf-3")"
  load_uboot="${load_uboot:-0x00200000}"
  load_atf1="${load_atf1:-0x00040000}"
  load_atf2="${load_atf2:-0xff100000}"
  load_atf3="${load_atf3:-0x000f0000}"

  if [ "$SPI_UBOOT_SOURCE" = "base" ]; then
    "$DUMPIMAGE_BIN" -i "$BASE_UBOOT_ITB" -T flat_dt -p "$idx_uboot" -o "$repack_dir/u-boot.bin" "$repack_dir/_extract.bin" >/dev/null
  else
    cp "$UBOOT_WORKDIR/u-boot.bin" "$repack_dir/u-boot.bin"
  fi
  "$DUMPIMAGE_BIN" -i "$BASE_UBOOT_ITB" -T flat_dt -p "$idx_atf1" -o "$repack_dir/atf-1.bin" "$repack_dir/_extract.bin" >/dev/null
  "$DUMPIMAGE_BIN" -i "$BASE_UBOOT_ITB" -T flat_dt -p "$idx_atf2" -o "$repack_dir/atf-2.bin" "$repack_dir/_extract.bin" >/dev/null
  "$DUMPIMAGE_BIN" -i "$BASE_UBOOT_ITB" -T flat_dt -p "$idx_atf3" -o "$repack_dir/atf-3.bin" "$repack_dir/_extract.bin" >/dev/null

  cat >"$repack_dir/u-boot-repack.its" <<EOF
/dts-v1/;
/ {
	description = "FIT Image with ATF/OP-TEE/U-Boot/MCU";
	#address-cells = <1>;
	images {
		uboot {
			description = "U-Boot";
			data = /incbin/("u-boot.bin");
			type = "standalone";
			arch = "arm64";
			os = "U-Boot";
			compression = "none";
			load = <${load_uboot}>;
			hash { algo = "sha256"; };
		};
		atf-1 {
			description = "ARM Trusted Firmware";
			data = /incbin/("atf-1.bin");
			type = "firmware";
			arch = "arm64";
			os = "arm-trusted-firmware";
			compression = "none";
			load = <${load_atf1}>;
			hash { algo = "sha256"; };
		};
		atf-2 {
			description = "ARM Trusted Firmware";
			data = /incbin/("atf-2.bin");
			type = "firmware";
			arch = "arm64";
			os = "arm-trusted-firmware";
			compression = "none";
			load = <${load_atf2}>;
			hash { algo = "sha256"; };
		};
		atf-3 {
			description = "ARM Trusted Firmware";
			data = /incbin/("atf-3.bin");
			type = "firmware";
			arch = "arm64";
			os = "arm-trusted-firmware";
			compression = "none";
			load = <${load_atf3}>;
			hash { algo = "sha256"; };
		};
		fdt {
			description = "U-Boot dtb";
			data = /incbin/("u-boot.dtb");
			type = "flat_dt";
			arch = "arm64";
			compression = "none";
			hash { algo = "sha256"; };
		};
	};
	configurations {
		default = "conf";
		conf {
			description = "rk3588s-radxa-e54c-spi";
			rollback-index = <0x00>;
			firmware = "atf-1";
			loadables = "uboot", "atf-2", "atf-3";
			fdt = "fdt";
		};
	};
};
EOF

  cp "$UBOOT_WORKDIR/u-boot.dtb" "$repack_dir/u-boot.dtb"
  (
    cd "$repack_dir"
    "$MKIMAGE_BIN" -f u-boot-repack.its "$UBOOT_WORKDIR/u-boot.itb" >/dev/null
  )
  if ! fit_has_atf "$UBOOT_WORKDIR/u-boot.itb" "$DUMPIMAGE_BIN"; then
    echo "Repacked u-boot.itb still missing ATF images." >&2
    exit 1
  fi
  ATF_REPACKED="1"
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

SPI_IMAGE_PATH="$ARTIFACT_DIR/spi-u-boot-16MiB.img"
SPI_IMAGE_SOURCE="generated-blank"
SPI_IMAGE_SOURCE_SHA256=""

if [ "$SPI_IMAGE_STRATEGY" = "base-image" ]; then
  mkdir -p "$(dirname "$SPI_BASE_IMAGE_PATH")"
  if [ ! -f "$SPI_BASE_IMAGE_PATH" ]; then
    echo "Downloading base SPI image: $SPI_BASE_IMAGE_URL"
    curl -fL "$SPI_BASE_IMAGE_URL" -o "$SPI_BASE_IMAGE_PATH"
  fi
  base_size="$(stat -c%s "$SPI_BASE_IMAGE_PATH")"
  if [ "$base_size" -ne "$SPI_IMAGE_SIZE_BYTES" ]; then
    echo "Base SPI image has unexpected size: $base_size (expected $SPI_IMAGE_SIZE_BYTES)" >&2
    exit 1
  fi
  cp "$SPI_BASE_IMAGE_PATH" "$SPI_IMAGE_PATH"
  SPI_IMAGE_SOURCE="$SPI_BASE_IMAGE_PATH"
  if command -v sha256sum >/dev/null 2>&1; then
    SPI_IMAGE_SOURCE_SHA256="$(sha256sum "$SPI_BASE_IMAGE_PATH" | awk '{print $1}')"
  fi
elif [ "$SPI_IMAGE_STRATEGY" = "idbloader" ]; then
  IDBLOADER_FOR_SPI=""
  if [ -f "$ARTIFACT_DIR/idbloader.vendor.img" ]; then
    IDBLOADER_FOR_SPI="$ARTIFACT_DIR/idbloader.vendor.img"
  elif [ -f "$ARTIFACT_DIR/idbloader-spl.img" ]; then
    IDBLOADER_FOR_SPI="$ARTIFACT_DIR/idbloader-spl.img"
  else
    echo "No idbloader image available for SPI image assembly." >&2
    exit 1
  fi

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
  IDBLOADER_OFFSET_BYTES="$((SPI_IDBLOADER_LBA * 512))"
  if [ $((IDBLOADER_OFFSET_BYTES + IDBLOADER_SIZE)) -gt "$SPI_IMAGE_SIZE_BYTES" ]; then
    echo "idbloader does not fit in SPI image size ($SPI_IMAGE_SIZE_BYTES bytes)." >&2
    exit 1
  fi
  dd conv=notrunc if="$IDBLOADER_FOR_SPI" of="$SPI_IMAGE_PATH" bs=512 seek="$SPI_IDBLOADER_LBA" status=none
  SPI_IMAGE_SOURCE="$IDBLOADER_FOR_SPI + blank"
else
  echo "Unsupported SPI_IMAGE_STRATEGY: $SPI_IMAGE_STRATEGY (expected base-image|idbloader)" >&2
  exit 1
fi

UBOOT_ITB_SIZE="$(stat -c%s "$ARTIFACT_DIR/u-boot.itb")"
UBOOT_ITB_OFFSET_BYTES="$((SPI_UBOOT_ITB_LBA * 512))"
if [ $((UBOOT_ITB_OFFSET_BYTES + UBOOT_ITB_SIZE)) -gt "$SPI_IMAGE_SIZE_BYTES" ]; then
  echo "u-boot.itb does not fit in SPI image size ($SPI_IMAGE_SIZE_BYTES bytes)." >&2
  exit 1
fi
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
  echo "spi_uboot_source=$SPI_UBOOT_SOURCE"
  echo "fit_atf_repacked=$ATF_REPACKED"
  echo "fit_repack_reason=${FIT_REPACK_REASON:-none}"
  echo "spi_image_strategy=$SPI_IMAGE_STRATEGY"
  echo "spi_image_source=$SPI_IMAGE_SOURCE"
  echo "spi_image_source_sha256=$SPI_IMAGE_SOURCE_SHA256"
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
