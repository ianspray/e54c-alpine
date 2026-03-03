# Containerized Build Guide (Debian)

This guide documents how to run the full E54C image build in a Debian-based container, with flashing performed manually on the host.

## Scope

- Build main and USB updater images in a reproducible Linux userspace.
- Keep host-side flashing out of scope for the container.
- Support macOS hosts via Docker Desktop or Podman machine.

## Files

- Builder image definition: `Dockerfile.builder`
- Host wrapper: `scripts/run-build-in-container.sh`

## Prerequisites

- Install one container runtime on the host:
  - Docker (`docker`)
  - Podman (`podman`)
- Ensure the host user can run the selected runtime.
- Ensure sufficient disk space:
  - Kernel source/build output
  - Rootfs and image artifacts (`build/`)
  - Container image layers

## Quick Start

From repo root:

```bash
scripts/run-build-in-container.sh
```

This will:

1. Build `e54c-builder:bookworm` from `Dockerfile.builder` if missing.
2. Start a privileged container with the repo bind-mounted at `/workspace`.
3. Run `make images` inside the container.
4. Write artifacts to host `build/` through the bind mount.

## Common Commands

Build main image only:

```bash
scripts/run-build-in-container.sh -- make main-image
```

Force rebuild of builder image:

```bash
scripts/run-build-in-container.sh --rebuild-image
```

Select runtime explicitly:

```bash
scripts/run-build-in-container.sh --runtime docker
scripts/run-build-in-container.sh --runtime podman
```

Use a custom image tag:

```bash
scripts/run-build-in-container.sh --image-tag e54c-builder:local
```

## Why Privileged Mode Is Required

The build pipeline uses Linux-native image and block tooling (`guestfish`, partition/mkfs tooling, loop-backed operations) and runs `podman` for APK repo generation. Running with `--privileged` is the most reliable way to support these operations inside the builder container.

## Ownership and Permissions

By default, the wrapper attempts to `chown` generated output back to the invoking host UID/GID for:

- `build/`
- `assets/reference/alpine/custom-keys/`

Disable this behavior if desired:

```bash
scripts/run-build-in-container.sh --no-fix-perms
```

## Host Flashing (Manual)

Flashing images to USB or NVMe is intentionally excluded from this container workflow. Use host-side tooling after build completion.

Examples:

```bash
sudo scripts/write-image-to-nvme.sh --image build/e54c-alpine-usb-updater.img --device /dev/sdX --yes
sudo scripts/write-image-to-nvme.sh --device /dev/nvme0n1 --yes
```

On macOS, use your preferred native flashing workflow.

## Troubleshooting

- Runtime not found:
  - Install Docker or Podman, then re-run.
- Permission issues in `build/`:
  - Re-run without `--no-fix-perms`, or repair ownership manually.
- Nested Podman/APK build failures:
  - Rebuild builder image: `scripts/run-build-in-container.sh --rebuild-image`
  - Confirm host runtime supports privileged containers.
