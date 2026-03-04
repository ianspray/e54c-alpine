#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

export PATH="$PATH:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/board-config.sh"
load_board_config

KERNEL_REPO="${KERNEL_REPO:-${BOARD_KERNEL_REPO_DEFAULT:-https://github.com/radxa/kernel.git}}"
KERNEL_BRANCH="${KERNEL_BRANCH:-${BOARD_KERNEL_BRANCH_DEFAULT:-linux-6.1-stan-rkr5.1}}"
KERNEL_DIR="${KERNEL_DIR:-$REPO_ROOT/src/radxa-kernel-$BOARD}"
KERNEL_EXPECTED_DTS="${KERNEL_EXPECTED_DTS:-$BOARD_KERNEL_EXPECTED_DTS}"

if [ -d "$KERNEL_DIR/.git" ]; then
  echo "Refreshing existing kernel checkout in $KERNEL_DIR"
  git -C "$KERNEL_DIR" fetch --depth 1 origin "$KERNEL_BRANCH"
  git -C "$KERNEL_DIR" checkout -B "$KERNEL_BRANCH" "origin/$KERNEL_BRANCH"
else
  echo "Cloning $KERNEL_REPO ($KERNEL_BRANCH) into $KERNEL_DIR"
  git clone --depth 1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"
fi

EXPECTED_DTS_PATH="$KERNEL_DIR/$KERNEL_EXPECTED_DTS"
if [ ! -f "$EXPECTED_DTS_PATH" ]; then
  echo "Expected DTS is missing for BOARD=$BOARD: $EXPECTED_DTS_PATH" >&2
  exit 1
fi

echo "Kernel source ready: $(git -C "$KERNEL_DIR" rev-parse --short HEAD)"
