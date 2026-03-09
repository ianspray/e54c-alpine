#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${KERNEL_DIR:?KERNEL_DIR must be set}"
dts_file="$KERNEL_DIR/arch/arm64/boot/dts/rockchip/rk3566-nanopi-r3-rev01.dts"
marker='/* alpian-r3s-overrides */'

if [ ! -f "$dts_file" ]; then
  echo "FriendlyElec R3S base DTS not found: $dts_file" >&2
  exit 1
fi

if grep -Fq "$marker" "$dts_file"; then
  echo "Alpian R3S DTS overrides already present."
  exit 0
fi

cat >>"$dts_file" <<'EOF'

/* alpian-r3s-overrides */
&chosen {
	stdout-path = "serial2:1500000n8";
	/delete-property/ bootargs;
	/delete-property/ bootargs_ext;
};

&bus_npu {
	/delete-property/ bus-supply;
	status = "disabled";
};

&rknpu {
	status = "disabled";
};

&rknpu_mmu {
	status = "disabled";
};
EOF

echo "Applied Alpian R3S DTS runtime overrides."
