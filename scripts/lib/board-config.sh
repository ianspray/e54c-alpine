#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

load_board_config() {
  : "${REPO_ROOT:?REPO_ROOT must be set before calling load_board_config}"

  BOARD="${BOARD:-e54c}"
  BOARD_DIR="${BOARD_DIR:-$REPO_ROOT/boards/$BOARD}"
  BOARD_CONFIG_FILE="${BOARD_CONFIG_FILE:-$BOARD_DIR/board.env}"

  if [ ! -d "$BOARD_DIR" ]; then
    echo "Unknown BOARD '$BOARD': missing directory $BOARD_DIR" >&2
    exit 1
  fi

  if [ ! -f "$BOARD_CONFIG_FILE" ]; then
    echo "Board config not found: $BOARD_CONFIG_FILE" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  . "$BOARD_CONFIG_FILE"
}
