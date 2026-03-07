#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${KERNEL_DIR:?KERNEL_DIR must be set}"

dts_src="$SCRIPT_DIR/rk3566-nanopi-r3s.dts"
dts_dst="$KERNEL_DIR/arch/arm64/boot/dts/rockchip/rk3566-nanopi-r3s.dts"
makefile="$KERNEL_DIR/arch/arm64/boot/dts/rockchip/Makefile"
dtb_line='dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3566-nanopi-r3s.dtb'
insert_after='dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3568-pcie-ep-lp4x-v10-linux.dtb'

if [ ! -f "$dts_src" ]; then
  echo "Missing fallback DTS source: $dts_src" >&2
  exit 1
fi

if [ ! -f "$makefile" ]; then
  echo "Missing Rockchip DTB Makefile: $makefile" >&2
  exit 1
fi

if [ -f "$dts_dst" ]; then
  echo "NanoPi R3S DTS already present in vendor tree."
else
  install -D -m 0644 "$dts_src" "$dts_dst"
  echo "Installed fallback NanoPi R3S DTS into vendor tree."
fi

if grep -Fqx "$dtb_line" "$makefile"; then
  echo "NanoPi R3S DTB Makefile entry already present."
  exit 0
fi

tmp_makefile="$(mktemp)"
inserted=0

while IFS= read -r line; do
  printf '%s\n' "$line" >>"$tmp_makefile"

  if [ "$inserted" -eq 0 ] && [ "$line" = "$insert_after" ]; then
    printf '%s\n' "$dtb_line" >>"$tmp_makefile"
    inserted=1
  fi
done <"$makefile"

if [ "$inserted" -eq 0 ]; then
  printf '%s\n' "$dtb_line" >>"$tmp_makefile"
fi

mv "$tmp_makefile" "$makefile"
echo "Added NanoPi R3S DTB Makefile entry."
