#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-}"
BUILDER_IMAGE_TAG="${BUILDER_IMAGE_TAG:-radxa-builder:bookworm}"
BUILDER_DOCKERFILE="${BUILDER_DOCKERFILE:-$REPO_ROOT/Dockerfile.builder}"
REBUILD_IMAGE=0
FIX_PERMS=1

usage() {
  cat <<'EOF'
Usage:
  scripts/run-build-in-container.sh [options] [-- <build command...>]

Options:
  --runtime <docker|podman>   Container runtime to use.
  --image-tag <tag>           Builder image tag (default: radxa-builder:bookworm).
  --dockerfile <path>         Dockerfile path (default: ./Dockerfile.builder).
  --rebuild-image             Force image rebuild.
  --no-fix-perms              Skip post-build chown of generated files.
  -h, --help                  Show this help.

Default build command:
  make images

Environment:
  BOARD                       Board profile to build (default: e54c; options: e54c, rock5b, rpi4).

Examples:
  scripts/run-build-in-container.sh
  BOARD=rock5b scripts/run-build-in-container.sh -- make main-image
  BOARD=rpi4 scripts/run-build-in-container.sh -- make main-image
  scripts/run-build-in-container.sh -- make main-image
  scripts/run-build-in-container.sh --rebuild-image -- scripts/build-all.sh
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

runtime_usable() {
  local runtime="$1"
  case "$runtime" in
    docker)
      docker info >/dev/null 2>&1
      ;;
    podman)
      podman info >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

auto_detect_runtime() {
  if command -v docker >/dev/null 2>&1 && runtime_usable docker; then
    echo docker
    return
  fi
  if command -v podman >/dev/null 2>&1 && runtime_usable podman; then
    echo podman
    return
  fi
  echo ""
}

BUILD_CMD=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --runtime)
      CONTAINER_RUNTIME="${2:-}"
      shift 2
      ;;
    --image-tag)
      BUILDER_IMAGE_TAG="${2:-}"
      shift 2
      ;;
    --dockerfile)
      BUILDER_DOCKERFILE="${2:-}"
      shift 2
      ;;
    --rebuild-image)
      REBUILD_IMAGE=1
      shift
      ;;
    --no-fix-perms)
      FIX_PERMS=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      BUILD_CMD=("$@")
      break
      ;;
    *)
      BUILD_CMD=("$@")
      break
      ;;
  esac
done

if [ "${#BUILD_CMD[@]}" -eq 0 ]; then
  BUILD_CMD=(make images)
fi

if [ -z "$CONTAINER_RUNTIME" ]; then
  CONTAINER_RUNTIME="$(auto_detect_runtime)"
fi
if [ -z "$CONTAINER_RUNTIME" ]; then
  echo "Unable to find a container runtime. Install docker or podman." >&2
  exit 1
fi

if [ "$CONTAINER_RUNTIME" != "docker" ] && [ "$CONTAINER_RUNTIME" != "podman" ]; then
  echo "Unsupported runtime: $CONTAINER_RUNTIME" >&2
  echo "Use docker or podman." >&2
  exit 1
fi

require_cmd "$CONTAINER_RUNTIME"

if ! runtime_usable "$CONTAINER_RUNTIME"; then
  echo "Selected runtime '$CONTAINER_RUNTIME' is installed but not reachable." >&2
  if [ "$CONTAINER_RUNTIME" = "docker" ]; then
    echo "Tip: your docker CLI may point to a different socket/context (for example OrbStack)." >&2
    echo "Try: ./scripts/run-build-in-container.sh --runtime podman" >&2
  fi
  exit 1
fi

if [ ! -f "$BUILDER_DOCKERFILE" ]; then
  echo "Builder Dockerfile does not exist: $BUILDER_DOCKERFILE" >&2
  exit 1
fi

if [ "$REBUILD_IMAGE" -eq 1 ] || ! "$CONTAINER_RUNTIME" image inspect "$BUILDER_IMAGE_TAG" >/dev/null 2>&1; then
  echo "Building builder image: $BUILDER_IMAGE_TAG"
  "$CONTAINER_RUNTIME" build \
    -f "$BUILDER_DOCKERFILE" \
    -t "$BUILDER_IMAGE_TAG" \
    "$REPO_ROOT"
fi

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
BOARD="${BOARD:-e54c}"
BUILD_CMD_QUOTED="$(printf '%q ' "${BUILD_CMD[@]}")"

echo "Running build in container with runtime: $CONTAINER_RUNTIME"
echo "Container image: $BUILDER_IMAGE_TAG"
echo "Build command: ${BUILD_CMD[*]}"

"$CONTAINER_RUNTIME" run --rm --privileged \
  -e HOST_UID="$HOST_UID" \
  -e HOST_GID="$HOST_GID" \
  -e BOARD="$BOARD" \
  -e FIX_PERMS="$FIX_PERMS" \
  -v "$REPO_ROOT:/workspace" \
  -w /workspace \
  "$BUILDER_IMAGE_TAG" \
  bash -lc "set -euo pipefail; ${BUILD_CMD_QUOTED}; if [ \"\$FIX_PERMS\" = \"1\" ]; then chown -R \"\$HOST_UID:\$HOST_GID\" /workspace/build /workspace/assets/reference/alpine/custom-keys || true; fi"
