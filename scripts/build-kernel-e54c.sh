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

if is_case_insensitive_dir "$REPO_ROOT"; then
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

export BOARD
export KERNEL_DIR

"$SCRIPT_DIR/check-tooling.sh"
"$SCRIPT_DIR/fetch-radxa-kernel.sh"

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

if [ -z "$JOBS" ]; then
  JOBS="$(detect_jobs)"
fi

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
