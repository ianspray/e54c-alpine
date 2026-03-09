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
CURRENT_ARTIFACT_FILE="${CURRENT_ARTIFACT_FILE:-$ARTIFACTS_DIR/current-$BOARD}"
ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-}"
JOBS="${JOBS:-}"
DEFCONFIG_TARGET="${DEFCONFIG_TARGET:-${BOARD_KERNEL_DEFCONFIG_TARGET_DEFAULT:-rockchip_linux_defconfig}}"
DEFCONFIG_EXTRA_TARGETS="${DEFCONFIG_EXTRA_TARGETS:-${BOARD_KERNEL_DEFCONFIG_EXTRA_TARGETS_DEFAULT:-}}"
FRAGMENT_FILE="${FRAGMENT_FILE:-${BOARD_KERNEL_FRAGMENT_FILE:-$REPO_ROOT/assets/reference/radxa/custom-kernel.fragment}}"
KERNEL_CONFIG_MODE="${KERNEL_CONFIG_MODE:-${BOARD_KERNEL_CONFIG_MODE:-radxa-merge}}"
KERNEL_CONFIG_MERGE_FILES="${KERNEL_CONFIG_MERGE_FILES:-${BOARD_KERNEL_CONFIG_MERGE_FILES_DEFAULT:-arch/arm64/configs/rk3588_linux.config}}"
KERNEL_DTBS="${KERNEL_DTBS:-${BOARD_KERNEL_DTBS:-rk3588s-radxa-e54c.dtb rk3588s-radxa-e54c-spi.dtb}}"
KERNEL_DTB_SUBDIR="${KERNEL_DTB_SUBDIR:-${BOARD_DTB_SUBDIR_DEFAULT:-rockchip}}"
BUILD_TARGETS="${BUILD_TARGETS:-Image dtbs modules}"
KERNEL_SOURCE_MODE="${KERNEL_SOURCE_MODE:-${BOARD_KERNEL_SOURCE_MODE:-radxa-git}}"

RPI_IMAGE_URL="${RPI_IMAGE_URL:-${BOARD_RPI_RELEASE_IMAGE_URL_DEFAULT:-}}"
RPI_IMAGE_FILENAME="${RPI_IMAGE_FILENAME:-${BOARD_RPI_RELEASE_IMAGE_FILENAME_DEFAULT:-}}"
RPI_IMAGE_EXTRACT_MODE="${RPI_IMAGE_EXTRACT_MODE:-auto}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$REPO_ROOT/build/downloads}"

FE_IMAGE_ARCHIVE_URL="${FE_IMAGE_ARCHIVE_URL:-${BOARD_FRIENDLYELEC_IMAGE_ARCHIVE_URL:-}}"
FE_IMAGE_ARCHIVE_FILENAME="${FE_IMAGE_ARCHIVE_FILENAME:-${BOARD_FRIENDLYELEC_IMAGE_ARCHIVE_FILENAME:-}}"
FE_IMAGE_KERNEL_MEMBER="${FE_IMAGE_KERNEL_MEMBER:-${BOARD_FRIENDLYELEC_IMAGE_KERNEL_MEMBER:-}}"
FE_IMAGE_RESOURCE_MEMBER="${FE_IMAGE_RESOURCE_MEMBER:-${BOARD_FRIENDLYELEC_IMAGE_RESOURCE_MEMBER:-}}"
FE_IMAGE_ROOTFS_MEMBER="${FE_IMAGE_ROOTFS_MEMBER:-${BOARD_FRIENDLYELEC_IMAGE_ROOTFS_MEMBER:-}}"

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
  if [ "$KERNEL_SOURCE_MODE" = "radxa-git" ]; then
    if [ -z "$KERNEL_DIR_WAS_SET" ]; then
      KERNEL_DIR="/tmp/radxa-kernel-$BOARD"
      echo "Using case-sensitive kernel checkout: $KERNEL_DIR"
    fi
    if [ -z "$OUT_DIR_WAS_SET" ]; then
      OUT_DIR="/tmp/${BOARD}-kernel-out"
      echo "Using case-sensitive kernel output dir: $OUT_DIR"
    fi
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

resolve_kernel_config_path() {
  local candidate="$1"

  [ -n "$candidate" ] || return 1

  if [ -f "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  if [ -f "$KERNEL_DIR/$candidate" ]; then
    printf '%s\n' "$KERNEL_DIR/$candidate"
    return 0
  fi

  if [ -f "$REPO_ROOT/$candidate" ]; then
    printf '%s\n' "$REPO_ROOT/$candidate"
    return 0
  fi

  return 1
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
  echo "Generating base kernel config ($DEFCONFIG_TARGET${DEFCONFIG_EXTRA_TARGETS:+ $DEFCONFIG_EXTRA_TARGETS})"
  make "${MAKE_ARGS[@]}" "$DEFCONFIG_TARGET" $DEFCONFIG_EXTRA_TARGETS

  case "$KERNEL_CONFIG_MODE" in
    radxa-merge)
      merge_inputs=()
      for merge_file in $KERNEL_CONFIG_MERGE_FILES; do
        resolved_merge_file="$(resolve_kernel_config_path "$merge_file" || true)"
        if [ -z "$resolved_merge_file" ]; then
          echo "Kernel config merge file not found: $merge_file" >&2
          exit 1
        fi
        merge_inputs+=("$resolved_merge_file")
      done
      if [ -n "$FRAGMENT_FILE" ]; then
        resolved_fragment_file="$(resolve_kernel_config_path "$FRAGMENT_FILE" || true)"
        if [ -z "$resolved_fragment_file" ]; then
          echo "Kernel fragment file not found: $FRAGMENT_FILE" >&2
          exit 1
        fi
        merge_inputs+=("$resolved_fragment_file")
      fi

      if [ "${#merge_inputs[@]}" -gt 0 ]; then
        echo "Merging board kernel config fragments"
        "$KERNEL_DIR/scripts/kconfig/merge_config.sh" \
          -m -O "$OUT_DIR" \
          "$OUT_DIR/.config" \
          "${merge_inputs[@]}"
        make "${MAKE_ARGS[@]}" olddefconfig
      fi
      ;;
    defconfig-targets)
      if [ -n "$FRAGMENT_FILE" ]; then
        resolved_fragment_file="$(resolve_kernel_config_path "$FRAGMENT_FILE" || true)"
        if [ -z "$resolved_fragment_file" ]; then
          echo "Kernel fragment file not found: $FRAGMENT_FILE" >&2
          exit 1
        fi
        echo "Merging board kernel fragment"
        "$KERNEL_DIR/scripts/kconfig/merge_config.sh" \
          -m -O "$OUT_DIR" \
          "$OUT_DIR/.config" \
          "$resolved_fragment_file"
        make "${MAKE_ARGS[@]}" olddefconfig
      fi
      ;;
    *)
      echo "Unsupported KERNEL_CONFIG_MODE: $KERNEL_CONFIG_MODE" >&2
      echo "Supported: radxa-merge, defconfig-targets" >&2
      exit 1
      ;;
  esac

  echo "Building kernel targets: $BUILD_TARGETS (jobs=$JOBS)"
  make "${MAKE_ARGS[@]}" -j"$JOBS" $BUILD_TARGETS

  for dtb in $KERNEL_DTBS; do
    dtb_target="$KERNEL_DTB_SUBDIR/$dtb"
    dtb_source="$KERNEL_DIR/arch/arm64/boot/dts/$KERNEL_DTB_SUBDIR/${dtb%.dtb}.dts"
    dtb_output="$OUT_DIR/arch/arm64/boot/dts/$KERNEL_DTB_SUBDIR/$dtb"

    if [ -f "$dtb_output" ] || [ ! -f "$dtb_source" ]; then
      continue
    fi

    echo "Building explicit board DTB target: $dtb"
    make "${MAKE_ARGS[@]}" "$dtb_target"
  done

  KERNEL_RELEASE="$(make "${MAKE_ARGS[@]}" -s kernelrelease)"
  RELEASE_DIR="$ARTIFACTS_DIR/$KERNEL_RELEASE"
  dtb_output_dir="$OUT_DIR/arch/arm64/boot/dts/$KERNEL_DTB_SUBDIR"
  copied_dtbs=0

  mkdir -p "$RELEASE_DIR/boot/dtbs/$KERNEL_DTB_SUBDIR" "$RELEASE_DIR/rootfs"
  cp "$OUT_DIR/arch/arm64/boot/Image" "$RELEASE_DIR/boot/Image"
  cp "$OUT_DIR/.config" "$RELEASE_DIR/kernel.config"

  for dtb in $KERNEL_DTBS; do
    src="$dtb_output_dir/$dtb"
    if [ -f "$src" ]; then
      cp "$src" "$RELEASE_DIR/boot/dtbs/$KERNEL_DTB_SUBDIR/$dtb"
      copied_dtbs=$((copied_dtbs + 1))
    fi
  done

  if [ "$copied_dtbs" -eq 0 ] && [ -d "$dtb_output_dir" ]; then
    while IFS= read -r dtb_src; do
      dtb_name="$(basename "$dtb_src")"
      cp "$dtb_src" "$RELEASE_DIR/boot/dtbs/$KERNEL_DTB_SUBDIR/$dtb_name"
      copied_dtbs=$((copied_dtbs + 1))
    done < <(find "$dtb_output_dir" -maxdepth 1 -type f -name '*.dtb' | sort)
  fi

  if [ "$copied_dtbs" -eq 0 ]; then
    echo "No DTBs were copied from kernel output: $dtb_output_dir" >&2
    exit 1
  fi

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
  printf '%s\n' "$RELEASE_DIR" >"$CURRENT_ARTIFACT_FILE"
}

build_from_alpine_rpi_image() {
  extract_with_mtools() {
    local image_path="$1"
    local boot_extract="$2"
    local modules_extract="$3"
    local boot_offset modloop_path

    boot_offset="$(parted -m -s "$image_path" unit B print | awk -F: '$1=="1"{gsub(/B/, "", $2); print $2; exit}')"
    if [ -z "$boot_offset" ]; then
      echo "Unable to determine the boot partition offset for the Alpine RPi image." >&2
      return 1
    fi

    mkdir -p "$boot_extract" "$modules_extract"
    mcopy -i "$image_path@@$boot_offset" -s :: "$boot_extract"

    modloop_path="$boot_extract/boot/modloop-rpi"
    if [ ! -f "$modloop_path" ]; then
      echo "Missing boot/modloop-rpi in extracted Alpine RPi image." >&2
      return 1
    fi

    unsquashfs -d "$modules_extract" "$modloop_path" >/dev/null
  }

  extract_image_contents() {
    local image_path="$1"
    local boot_extract="$2"
    local modules_extract="$3"
    local mode="$RPI_IMAGE_EXTRACT_MODE"

    case "$mode" in
      auto|mtools)
        echo "Extracting Alpine RPi image via mtools and modloop."
        extract_with_mtools "$image_path" "$boot_extract" "$modules_extract"
        ;;
      *)
        echo "Unsupported RPI_IMAGE_EXTRACT_MODE: $mode" >&2
        echo "Supported: auto, mtools" >&2
        return 1
        ;;
    esac
  }

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
  cleanup_tmp_work() {
    rm -rf "$tmp_work"
  }
  trap cleanup_tmp_work EXIT
  boot_extract="$tmp_work/boot"
  modules_extract="$tmp_work/modules"

  extract_image_contents "$image_path" "$boot_extract" "$modules_extract"

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
    echo "Unable to locate kernel modules in extracted Alpine RPi image." >&2
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

  if [ "$CASE_INSENSITIVE_WORKSPACE" -eq 1 ]; then
    modules_stage="$(mktemp -d)"
    cp -a "$modules_root" "$modules_stage/"
    tar -C "$modules_stage" -cf "$RELEASE_DIR/modules-rootfs.tar" modules
    rm -rf "$modules_stage" "$RELEASE_DIR/rootfs"
    echo "Stored modules in $RELEASE_DIR/modules-rootfs.tar for case-insensitive workspace compatibility."
  else
    cp -a "$modules_root" "$RELEASE_DIR/rootfs/lib/"
  fi

  echo "Kernel artifacts prepared from Alpine RPi image."
  echo "Kernel release: $KERNEL_RELEASE"
  echo "Artifacts: $RELEASE_DIR"
  printf '%s\n' "$RELEASE_DIR" >"$CURRENT_ARTIFACT_FILE"
}

build_from_friendlyelec_image() {
  local fe_archive_url fe_archive_filename fe_kernel_member fe_resource_member fe_rootfs_member
  fe_archive_url="${FE_IMAGE_ARCHIVE_URL}"
  fe_archive_filename="${FE_IMAGE_ARCHIVE_FILENAME}"
  fe_kernel_member="${FE_IMAGE_KERNEL_MEMBER}"
  fe_resource_member="${FE_IMAGE_RESOURCE_MEMBER}"
  fe_rootfs_member="${FE_IMAGE_ROOTFS_MEMBER}"

  if [ -z "$fe_archive_url" ]; then
    echo "FE_IMAGE_ARCHIVE_URL (or BOARD_FRIENDLYELEC_IMAGE_ARCHIVE_URL) must be set for friendlyelec-image mode." >&2
    exit 1
  fi
  if [ -z "$fe_kernel_member" ] || [ -z "$fe_resource_member" ] || [ -z "$fe_rootfs_member" ]; then
    echo "BOARD_FRIENDLYELEC_IMAGE_KERNEL_MEMBER, _RESOURCE_MEMBER, and _ROOTFS_MEMBER must all be set." >&2
    exit 1
  fi
  if [ -z "$fe_archive_filename" ]; then
    fe_archive_filename="$(basename "$fe_archive_url")"
  fi

  mkdir -p "$ARTIFACTS_DIR" "$DOWNLOAD_DIR"

  local archive_path="$DOWNLOAD_DIR/$fe_archive_filename"
  if [ ! -f "$archive_path" ]; then
    echo "Downloading FriendlyElec image assets: $fe_archive_url"
    curl -fL --retry 3 --retry-delay 2 "$fe_archive_url" -o "$archive_path"
  else
    echo "Using existing FriendlyElec image archive: $archive_path"
  fi

  local tmp_work
  tmp_work="$(mktemp -d)"
  cleanup_fe_tmp() { rm -rf "$tmp_work"; }
  trap cleanup_fe_tmp EXIT

  # Extract kernel Image (KRNL header = 8 bytes, followed by raw ARM64 Image)
  echo "Extracting kernel Image from archive member: $fe_kernel_member"
  local kernel_img="$tmp_work/kernel.img"
  tar -xOf "$archive_path" "$fe_kernel_member" >"$kernel_img"

  local magic_bytes
  magic_bytes="$(dd if="$kernel_img" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  if [ "$magic_bytes" != "4b524e4c" ]; then
    echo "Unexpected kernel.img magic: $magic_bytes (expected 4b524e4c = KRNL)" >&2
    exit 1
  fi
  # Skip the 8-byte KRNL header to produce the raw ARM64 Image
  tail -c +9 "$kernel_img" >"$tmp_work/Image"
  echo "Extracted kernel Image: $(stat -c%s "$tmp_work/Image") bytes"

  # Extract DTBs from resource.img using Rockchip RSCE format
  echo "Extracting resource image from archive member: $fe_resource_member"
  local resource_img="$tmp_work/resource.img"
  tar -xOf "$archive_path" "$fe_resource_member" >"$resource_img"

  local dtb_dir="$tmp_work/dtbs"
  mkdir -p "$dtb_dir"
  echo "Extracting DTBs from resource image: $KERNEL_DTBS"
  python3 - "$resource_img" "$KERNEL_DTBS" "$dtb_dir" <<'PYEOF'
import struct, sys, os
resource_path, dtb_names_str, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
dtb_names = dtb_names_str.split()
os.makedirs(out_dir, exist_ok=True)
with open(resource_path, 'rb') as f:
    data = f.read()
if data[0:4] != b'RSCE':
    print(f'Not an RSCE resource image: magic={data[0:4]!r}', file=sys.stderr)
    sys.exit(1)
header_blocks = data[8]
entry_size_blocks = data[9]
entry_count = struct.unpack('<I', data[12:16])[0]
found = set()
for i in range(entry_count):
    off = (header_blocks + i * entry_size_blocks) * 512
    if off + 268 > len(data) or data[off:off+4] != b'ENTR':
        continue
    name_bytes = data[off+4:off+260]
    nul = name_bytes.find(b'\x00')
    name = (name_bytes[:nul] if nul >= 0 else name_bytes).decode('utf-8', errors='replace')
    if name in dtb_names:
        addr = struct.unpack('<I', data[off+260:off+264])[0]
        size = struct.unpack('<I', data[off+264:off+268])[0]
        with open(os.path.join(out_dir, name), 'wb') as out:
            out.write(data[addr * 512:addr * 512 + size])
        print(f'Extracted {name} ({size} bytes)')
        found.add(name)
missing = [n for n in dtb_names if n not in found]
if missing:
    print(f'ERROR: DTBs not found in resource image: {missing}', file=sys.stderr)
    sys.exit(1)
PYEOF

  # Extract kernel modules from the nested rootfs.tgz in the archive
  echo "Extracting rootfs archive from: $fe_rootfs_member"
  local rootfs_tgz="$tmp_work/rootfs.tgz"
  tar -xOf "$archive_path" "$fe_rootfs_member" >"$rootfs_tgz"

  local modules_stage="$tmp_work/modules_stage"
  mkdir -p "$modules_stage"
  echo "Extracting kernel modules from rootfs archive"
  tar -xzf "$rootfs_tgz" -C "$modules_stage" --strip-components=1 rootfs/lib/modules

  KERNEL_RELEASE=""
  for kdir in "$modules_stage/lib/modules"/*/; do
    [ -d "$kdir" ] || continue
    KERNEL_RELEASE="$(basename "$kdir")"
    break
  done
  if [ -z "$KERNEL_RELEASE" ]; then
    echo "Unable to determine kernel release from extracted modules." >&2
    exit 1
  fi

  RELEASE_DIR="$ARTIFACTS_DIR/$KERNEL_RELEASE"
  rm -rf "$RELEASE_DIR"
  mkdir -p "$RELEASE_DIR/boot/dtbs/$KERNEL_DTB_SUBDIR" "$RELEASE_DIR/rootfs/lib"
  cp "$tmp_work/Image" "$RELEASE_DIR/boot/Image"

  local copied_dtbs=0
  for dtb in $KERNEL_DTBS; do
    if [ -f "$dtb_dir/$dtb" ]; then
      cp "$dtb_dir/$dtb" "$RELEASE_DIR/boot/dtbs/$KERNEL_DTB_SUBDIR/$dtb"
      copied_dtbs=$((copied_dtbs + 1))
    fi
  done
  if [ "$copied_dtbs" -eq 0 ]; then
    echo "No DTBs were copied to artifact directory." >&2
    exit 1
  fi

  if [ "$CASE_INSENSITIVE_WORKSPACE" -eq 1 ]; then
    tar -C "$modules_stage" -cf "$RELEASE_DIR/modules-rootfs.tar" lib/modules
    rm -rf "$RELEASE_DIR/rootfs"
    echo "Stored modules in $RELEASE_DIR/modules-rootfs.tar (case-insensitive workspace)."
  else
    cp -a "$modules_stage/lib/modules" "$RELEASE_DIR/rootfs/lib/"
  fi

  echo "Kernel artifacts prepared from FriendlyElec image archive."
  echo "Kernel release: $KERNEL_RELEASE"
  echo "Artifacts: $RELEASE_DIR"
  printf '%s\n' "$RELEASE_DIR" >"$CURRENT_ARTIFACT_FILE"
}

case "$KERNEL_SOURCE_MODE" in
  radxa-git)
    build_from_radxa_source
    ;;
  alpine-rpi-image)
    build_from_alpine_rpi_image
    ;;
  friendlyelec-image)
    build_from_friendlyelec_image
    ;;
  *)
    echo "Unsupported KERNEL_SOURCE_MODE: $KERNEL_SOURCE_MODE" >&2
    echo "Supported: radxa-git, alpine-rpi-image, friendlyelec-image" >&2
    exit 1
    ;;
esac
