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
KERNEL_PATCH_DIR="${KERNEL_PATCH_DIR:-${BOARD_KERNEL_PATCH_DIR:-$REPO_ROOT/boards/$BOARD/kernel/patches}}"
KERNEL_PREPARE_SCRIPT="${KERNEL_PREPARE_SCRIPT:-${BOARD_KERNEL_PREPARE_SCRIPT:-}}"

if [ -d "$KERNEL_DIR/.git" ]; then
  echo "Refreshing existing kernel checkout in $KERNEL_DIR"
  git -C "$KERNEL_DIR" fetch --depth 1 origin "$KERNEL_BRANCH"
  git -C "$KERNEL_DIR" checkout -f -B "$KERNEL_BRANCH" "origin/$KERNEL_BRANCH"
else
  echo "Cloning $KERNEL_REPO ($KERNEL_BRANCH) into $KERNEL_DIR"
  git clone --depth 1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"
fi

if [ -d "$KERNEL_PATCH_DIR" ]; then
  shopt -s nullglob
  kernel_patches=("$KERNEL_PATCH_DIR"/*.patch)
  shopt -u nullglob

  if [ "${#kernel_patches[@]}" -gt 0 ]; then
    echo "Applying board kernel patches from $KERNEL_PATCH_DIR"
    for patch_file in "${kernel_patches[@]}"; do
      patch_name="$(basename "$patch_file")"
      if git -C "$KERNEL_DIR" apply --check "$patch_file" >/dev/null 2>&1; then
        git -C "$KERNEL_DIR" apply "$patch_file"
        echo "  applied: $patch_name"
      elif git -C "$KERNEL_DIR" apply -R --check "$patch_file" >/dev/null 2>&1; then
        echo "  already applied: $patch_name"
      else
        echo "Kernel patch failed to apply cleanly: $patch_file" >&2
        exit 1
      fi
    done
  fi
fi

if [ -n "$KERNEL_PREPARE_SCRIPT" ]; then
  if [ ! -x "$KERNEL_PREPARE_SCRIPT" ]; then
    echo "Kernel prepare script is not executable: $KERNEL_PREPARE_SCRIPT" >&2
    exit 1
  fi

  echo "Running board kernel prepare script: $KERNEL_PREPARE_SCRIPT"
  BOARD="$BOARD" KERNEL_DIR="$KERNEL_DIR" REPO_ROOT="$REPO_ROOT" \
    "$KERNEL_PREPARE_SCRIPT"
fi

EXPECTED_DTS_PATH="$KERNEL_DIR/$KERNEL_EXPECTED_DTS"
if [ ! -f "$EXPECTED_DTS_PATH" ]; then
  echo "Expected DTS is missing for BOARD=$BOARD: $EXPECTED_DTS_PATH" >&2
  exit 1
fi

kernel_head="$(git -C "$KERNEL_DIR" rev-parse --short HEAD)"
if ! git -C "$KERNEL_DIR" diff --quiet; then
  kernel_head="${kernel_head}+local-patches"
fi
echo "Kernel source ready: $kernel_head"
