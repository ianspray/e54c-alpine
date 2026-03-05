#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

export PATH="$PATH:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/board-config.sh"
load_board_config

KERNEL_DIR_WAS_SET="${KERNEL_DIR+x}"
OUT_DIR_WAS_SET="${OUT_DIR+x}"
KERNEL_DIR="${KERNEL_DIR:-$REPO_ROOT/src/radxa-kernel-$BOARD}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/build/kernel-out}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$REPO_ROOT/build/kernel-artifacts}"
ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-}"
JOBS="${JOBS:-}"
DEFCONFIG_TARGET="${DEFCONFIG_TARGET:-rockchip_linux_defconfig}"
FRAGMENT_FILE="${FRAGMENT_FILE:-${BOARD_KERNEL_FRAGMENT_FILE:-$REPO_ROOT/assets/reference/radxa/custom-kernel.fragment}}"
KERNEL_DTBS="${KERNEL_DTBS:-${BOARD_KERNEL_DTBS:-rk3588s-radxa-e54c.dtb rk3588s-radxa-e54c-spi.dtb}}"
BUILD_TARGETS="${BUILD_TARGETS:-Image dtbs modules}"
KERNEL_SOURCE_MODE="${KERNEL_SOURCE_MODE:-${BOARD_KERNEL_SOURCE_MODE:-radxa-git}}"

RPI_IMAGE_URL="${RPI_IMAGE_URL:-${BOARD_RPI_RELEASE_IMAGE_URL_DEFAULT:-}}"
RPI_IMAGE_FILENAME="${RPI_IMAGE_FILENAME:-${BOARD_RPI_RELEASE_IMAGE_FILENAME_DEFAULT:-}}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$REPO_ROOT/build/downloads}"

CASE_INSENSITIVE_WORKSPACE=0

is_case_insensitive_dir() {
  local dir="$1" probe_base lower upper
  probe_base=".case-probe-$$-$RANDOM"
  lower="$dir/${probe_base}a"
  upper="$dir/${probe_base}A"
  : >"$lower"
  if [ -e "$upper" ]; then
    rm -f "$lower" "$upper"
    return 0
  fi
  rm -f "$lower" "$upper"
  return 1
}

if [ "$KERNEL_SOURCE_MODE" = "radxa-git" ] && is_case_insensitive_dir "$REPO_ROOT"; then
  CASE_INSENSITIVE_WORKSPACE=1
  echo "Detected case-insensitive workspace filesystem."
  if [ -z "$KERNEL_DIR_WAS_SET" ]; then
    KERNEL_DIR="/tmp/radxa-kernel-$BOARD"
    echo "Using case-sensitive kernel checkout: $KERNEL_DIR"
  fi
  if [ -z "$OUT_DIR_WAS_SET" ]; then
    OUT_DIR="/tmp/${BOARD}-kernel-out"
    echo "Using case-sensitive kernel output dir: $OUT_DIR"
  fi
fi

detect_jobs() {
  local cpu_jobs mem_kb mem_limit jobs_by_mem
  cpu_jobs="$(nproc)"
  mem_kb=""

  if [ -r /sys/fs/cgroup/memory.max ]; then
    mem_limit="$(cat /sys/fs/cgroup/memory.max)"
    if [ "$mem_limit" != "max" ] && [ "$mem_limit" -gt 0 ] 2>/dev/null; then
      mem_kb="$((mem_limit / 1024))"
    fi
  elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    mem_limit="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
    if [ "$mem_limit" -gt 0 ] 2>/dev/null; then
      mem_kb="$((mem_limit / 1024))"
    fi
  fi

  if [ -z "$mem_kb" ] && [ -r /proc/meminfo ]; then
    mem_kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
  fi

  if [ -n "$mem_kb" ] && [ "$mem_kb" -gt 0 ]; then
    # Kernel builds can spike memory usage under heavy parallelism.
    # Budget ~1.5 GiB per parallel job to avoid cgroup OOM kills.
    jobs_by_mem="$((mem_kb / 1572864))"
    if [ "$jobs_by_mem" -lt 1 ]; then
      jobs_by_mem=1
    fi
    if [ "$jobs_by_mem" -lt "$cpu_jobs" ]; then
      echo "$jobs_by_mem"
      return 0
    fi
  fi

  echo "$cpu_jobs"
}

detect_toolchain() {
  case "$ARCH" in
    arm64|aarch64)
      if [ -n "$CROSS_COMPILE" ]; then
        return 0
      fi
      case "$(uname -m)" in
        aarch64|arm64)
          # Native arm64 host/container can use gcc directly.
          ;;
        *)
          if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
            CROSS_COMPILE="aarch64-linux-gnu-"
          else
            echo "ARCH=$ARCH requires an AArch64 toolchain." >&2
            echo "Install gcc-aarch64-linux-gnu (and matching binutils), or set CROSS_COMPILE." >&2
            exit 1
          fi
          ;;
      esac
      ;;
  esac
}

build_from_radxa_source() {
  export BOARD
  export KERNEL_DIR

  "$SCRIPT_DIR/check-tooling.sh"
  "$SCRIPT_DIR/fetch-radxa-kernel.sh"

  if [ -z "$JOBS" ]; then
    JOBS="$(detect_jobs)"
  fi

  detect_toolchain

  MAKE_ARGS=(-C "$KERNEL_DIR" O="$OUT_DIR" ARCH="$ARCH")
  if [ -n "$CROSS_COMPILE" ]; then
    MAKE_ARGS+=(CROSS_COMPILE="$CROSS_COMPILE")
  fi

  mkdir -p "$OUT_DIR" "$ARTIFACTS_DIR"

  if [ -n "$CROSS_COMPILE" ]; then
    echo "Kernel toolchain prefix: $CROSS_COMPILE"
  fi
  echo "Generating base kernel config ($DEFCONFIG_TARGET)"
  make "${MAKE_ARGS[@]}" "$DEFCONFIG_TARGET"

  echo "Merging vendor rk3588 config + custom fragment"
  "$KERNEL_DIR/scripts/kconfig/merge_config.sh" \
    -m -O "$OUT_DIR" \
    "$OUT_DIR/.config" \
    "$KERNEL_DIR/arch/arm64/configs/rk3588_linux.config" \
    "$FRAGMENT_FILE"

  make "${MAKE_ARGS[@]}" olddefconfig

  echo "Building kernel targets: $BUILD_TARGETS (jobs=$JOBS)"
  make "${MAKE_ARGS[@]}" -j"$JOBS" $BUILD_TARGETS

  KERNEL_RELEASE="$(make "${MAKE_ARGS[@]}" -s kernelrelease)"
  RELEASE_DIR="$ARTIFACTS_DIR/$KERNEL_RELEASE"

  mkdir -p "$RELEASE_DIR/boot/dtbs/rockchip" "$RELEASE_DIR/rootfs"
  cp "$OUT_DIR/arch/arm64/boot/Image" "$RELEASE_DIR/boot/Image"
  cp "$OUT_DIR/.config" "$RELEASE_DIR/kernel.config"

  for dtb in $KERNEL_DTBS; do
    src="$OUT_DIR/arch/arm64/boot/dts/rockchip/$dtb"
    if [ -f "$src" ]; then
      cp "$src" "$RELEASE_DIR/boot/dtbs/rockchip/$dtb"
    fi
  done

  if [[ " $BUILD_TARGETS " == *" modules "* ]]; then
    if [ "$CASE_INSENSITIVE_WORKSPACE" -eq 1 ]; then
      modules_stage="$(mktemp -d)"
      make "${MAKE_ARGS[@]}" \
        modules_install INSTALL_MOD_PATH="$modules_stage"
      tar -C "$modules_stage" -cf "$RELEASE_DIR/modules-rootfs.tar" lib/modules
      rm -rf "$modules_stage" "$RELEASE_DIR/rootfs"
      echo "Stored modules in $RELEASE_DIR/modules-rootfs.tar for case-insensitive workspace compatibility."
    else
      make "${MAKE_ARGS[@]}" \
        modules_install INSTALL_MOD_PATH="$RELEASE_DIR/rootfs"
    fi
  fi

  echo "Kernel build complete."
  echo "Kernel release: $KERNEL_RELEASE"
  echo "Artifacts: $RELEASE_DIR"
}

build_from_alpine_rpi_image() {
  "$SCRIPT_DIR/check-tooling.sh"

  if [ -z "$RPI_IMAGE_URL" ]; then
    echo "RPI_IMAGE_URL (or BOARD_RPI_RELEASE_IMAGE_URL_DEFAULT) must be set for alpine-rpi-image mode." >&2
    exit 1
  fi
  if [ -z "$RPI_IMAGE_FILENAME" ]; then
    RPI_IMAGE_FILENAME="$(basename "$RPI_IMAGE_URL")"
  fi

  mkdir -p "$ARTIFACTS_DIR" "$DOWNLOAD_DIR"

  local compressed_path image_path
  compressed_path="$DOWNLOAD_DIR/$RPI_IMAGE_FILENAME"
  image_path="$compressed_path"
  if [[ "$compressed_path" == *.gz ]]; then
    image_path="${compressed_path%.gz}"
  fi

  if [ ! -f "$compressed_path" ]; then
    echo "Downloading Alpine RPi image: $RPI_IMAGE_URL"
    curl -fL --retry 3 --retry-delay 2 "$RPI_IMAGE_URL" -o "$compressed_path"
  else
    echo "Using existing Alpine RPi image download: $compressed_path"
  fi

  if [[ "$compressed_path" == *.gz ]]; then
    if [ ! -f "$image_path" ] || [ "$compressed_path" -nt "$image_path" ]; then
      echo "Decompressing $compressed_path -> $image_path"
      gzip -dc "$compressed_path" >"$image_path"
    fi
  fi

  if [ ! -f "$image_path" ]; then
    echo "Missing extracted RPi image: $image_path" >&2
    exit 1
  fi

  tmp_work="$(mktemp -d)"
  trap 'rm -rf "$tmp_work"' EXIT
  boot_tar="$tmp_work/boot.tar"
  modules_tar="$tmp_work/modules.tar"
  boot_extract="$tmp_work/boot"
  modules_extract="$tmp_work/modules"

  guestfish <<EOF
add-drive-ro $image_path
run
mount-ro /dev/sda1 /
tar-out / $boot_tar
umount /
mount-ro /dev/sda2 /
tar-out /lib/modules $modules_tar
EOF

  mkdir -p "$boot_extract" "$modules_extract"
  tar -xf "$boot_tar" -C "$boot_extract"
  tar -xf "$modules_tar" -C "$modules_extract"

  modules_root=""
  if [ -d "$modules_extract/lib/modules" ]; then
    modules_root="$modules_extract/lib/modules"
  elif [ -d "$modules_extract/modules" ]; then
    modules_root="$modules_extract/modules"
  else
    maybe_modules_root="$(find "$modules_extract" -maxdepth 4 -type d -name modules | head -n1 || true)"
    if [ -n "$maybe_modules_root" ]; then
      modules_root="$maybe_modules_root"
    fi
  fi

  if [ -z "$modules_root" ] || [ ! -d "$modules_root" ]; then
    echo "Unable to locate /lib/modules in extracted Alpine RPi image." >&2
    exit 1
  fi

  local first_module_dir
  first_module_dir="$(find "$modules_root" -mindepth 1 -maxdepth 1 -type d | sort | head -n1 || true)"
  KERNEL_RELEASE=""
  if [ -n "$first_module_dir" ]; then
    KERNEL_RELEASE="$(basename "$first_module_dir")"
  fi
  if [ -z "$KERNEL_RELEASE" ]; then
    echo "Unable to determine kernel release from extracted modules." >&2
    exit 1
  fi
  RELEASE_DIR="$ARTIFACTS_DIR/$KERNEL_RELEASE"
  rm -rf "$RELEASE_DIR"
  mkdir -p "$RELEASE_DIR/boot" "$RELEASE_DIR/rootfs/lib"

  kernel_src=""
  for candidate in Image kernel8.img vmlinuz-rpi vmlinuz-lts; do
    if [ -f "$boot_extract/$candidate" ]; then
      kernel_src="$boot_extract/$candidate"
      break
    fi
  done
  if [ -z "$kernel_src" ]; then
    kernel_src="$(find "$boot_extract" -maxdepth 2 -type f \( -name 'kernel8.img' -o -name 'Image' -o -name 'vmlinuz*' \) | sort | head -n1 || true)"
  fi
  if [ -z "$kernel_src" ] || [ ! -f "$kernel_src" ]; then
    echo "Unable to locate kernel image inside Alpine RPi boot partition." >&2
    exit 1
  fi
  cp "$kernel_src" "$RELEASE_DIR/boot/Image"

  mkdir -p "$RELEASE_DIR/boot/firmware"
  cp -a "$boot_extract"/. "$RELEASE_DIR/boot/firmware/"

  mkdir -p "$RELEASE_DIR/boot/dtbs"
  if [ -d "$boot_extract/dtbs" ]; then
    cp -a "$boot_extract/dtbs"/. "$RELEASE_DIR/boot/dtbs/"
  elif [ -d "$boot_extract/boot/dtbs" ]; then
    cp -a "$boot_extract/boot/dtbs"/. "$RELEASE_DIR/boot/dtbs/"
  else
    mkdir -p "$RELEASE_DIR/boot/dtbs/broadcom"
    find "$boot_extract" -maxdepth 3 -type f -name '*.dtb' -exec cp {} "$RELEASE_DIR/boot/dtbs/broadcom/" \;
  fi

  cp -a "$modules_root" "$RELEASE_DIR/rootfs/lib/"

  echo "Kernel artifacts prepared from Alpine RPi image."
  echo "Kernel release: $KERNEL_RELEASE"
  echo "Artifacts: $RELEASE_DIR"
}

case "$KERNEL_SOURCE_MODE" in
  radxa-git)
    build_from_radxa_source
    ;;
  alpine-rpi-image)
    build_from_alpine_rpi_image
    ;;
  *)
    echo "Unsupported KERNEL_SOURCE_MODE: $KERNEL_SOURCE_MODE" >&2
    echo "Supported: radxa-git, alpine-rpi-image" >&2
    exit 1
    ;;
esac
