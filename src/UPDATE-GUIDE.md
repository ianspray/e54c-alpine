# E54C Sustainable Update Guide

This document defines a sustainable update model for this repository and device.

## Current Build Model

1. Kernel, DTB, and modules are built by `scripts/build-kernel-e54c.sh`.
2. Alpine userland rootfs is built by `scripts/prepare-alpine-rootfs.sh`.
3. Final image is assembled by `scripts/assemble-e54c-image.sh`.
4. Final image is flashed by `scripts/write-image-to-nvme.sh`.

The current runtime layout is:

1. `p1` (`config`) for persistent config/cache.
2. `p2` (`efi`) for extlinux + kernel + DTB.
3. `p3` (`rootfs`) for Alpine root filesystem.

Current runtime mode:

1. Default boot profile is immutable (`overlaytmpfs=yes`): lower rootfs is read-only and runtime writes are in RAM.
2. `config` and `efi` are mounted read-only by default.
3. Maintenance boot profile is available from extlinux menu with writable rootfs (`rw`, no overlay).
4. Persistent config is saved only when explicitly requested via `lbu commit`.

Current default partition sizing:

1. `p1` `config`: 256 MiB
2. `p2` `efi`: 300 MiB
3. `p3` `rootfs`: remainder

## 1) Updating Alpine Userland to a New Version

Recommended process:

1. Choose target Alpine release values:
   - `ALPINE_BRANCH` (example: `v3.24`)
   - `ALPINE_VERSION` (example: `3.24.0`)
2. Rebuild rootfs and image with explicit env vars:

```bash
ALPINE_BRANCH=v3.24 ALPINE_VERSION=3.24.0 scripts/prepare-alpine-rootfs.sh
scripts/assemble-e54c-image.sh
```

3. Validate image contents before flash:
   - `/etc/apk/repositories` uses target branch.
   - `/usr/sbin/lbu` exists.
   - `/lib/modules/$(uname -r)` exists in image after kernel build.
4. Flash and test boot + networking + serial login on hardware.

Sustainability notes:

1. Always set `ALPINE_BRANCH` and `ALPINE_VERSION` explicitly in CI/release jobs.
2. Keep baseline packages in `assets/reference/alpine/packages.txt` small and intentional.
3. Use `ALPINE_PACKAGES` only for one-off overrides in automated jobs.
4. Keep build-time temporary credentials controllable with env vars:
   - `ROOT_PASSWORD_HASH`
   - `ROOT_PASSWORD_PLAIN`

### Runtime Behavior With Immutable Mode

1. In normal boots, package/config/log writes do not persist to NVMe unless you explicitly commit.
2. For persistent config updates from normal boot:
   - edit config under `/etc`
   - run `lbu commit`
3. `lbu` writes to `config` media and is the explicit persistence action.

## 2) Updating Kernel/Modules/DTB to a New Version

Recommended process:

1. Choose kernel source and branch:
   - `KERNEL_REPO`
   - `KERNEL_BRANCH`
2. Build with full modules:

```bash
KERNEL_BRANCH=linux-6.6-some-branch scripts/build-kernel-e54c.sh
```

3. Rebuild rootfs + image to include matching modules and boot artifacts:

```bash
scripts/prepare-alpine-rootfs.sh
scripts/assemble-e54c-image.sh
```

4. Validate before flash:
   - `build/kernel-artifacts/<release>/boot/Image` exists.
   - `build/kernel-artifacts/<release>/boot/dtbs/rockchip/rk3588s-radxa-e54c-spi.dtb` exists.
   - `build/kernel-artifacts/<release>/rootfs/lib/modules/<release>` exists.
   - Image contains `/lib/modules/<release>`.

Sustainability notes:

1. Treat `assets/reference/radxa/custom-kernel.fragment` as a compatibility contract for E54C features.
2. Keep E54C-critical networking options pinned (DSA + Realtek switch stack).
3. Never ship a new kernel without its matching modules directory in the same image.

## 2b) Updating SPI U-Boot (USB Fix / Boot Policy)

If USB boot probing in U-Boot is broken (`usb start` shows no working controllers), update SPI U-Boot with the E54C USB DTS patch flow:

```bash
scripts/build-uboot-e54c-spi.sh
```

Outputs are placed under `build/u-boot-artifacts/` and include:

1. `spi-u-boot-16MiB.img` (single image for direct write to SPI from offset 0)
2. `u-boot.itb` (patched U-Boot proper)
3. `idbloader.vendor.img` (copied fallback from current repo reference, when present)
4. `build-info.txt` with source commit and DTS evidence

Flash the single SPI image:

```bash
sudo dd if=build/u-boot-artifacts/<stamp>/spi-u-boot-16MiB.img of=/dev/mtdblock0 bs=1M conv=fsync,notrunc status=progress
```

The same image is assembled with Rockchip offsets internally (`idbloader` at LBA 64, `u-boot.itb` at LBA 16384).

## 3) Maintenance Boot Workflow

Use maintenance mode when you intentionally want writes to base storage.

### Enter Maintenance Mode

1. At U-Boot extlinux menu, select:
   - `Alpine Linux (maintenance, writable rootfs)`
2. From a running immutable system (recommended for remote ops):
   - `e54c-boot-mode reboot-maintenance`
2. Or build image with maintenance as default:

```bash
DEFAULT_BOOT_MODE=maintenance scripts/assemble-e54c-image.sh
```

### Typical Maintenance Tasks

1. `apk add`/`apk upgrade`
2. Kernel artifact replacement during development
3. One-time filesystem edits that must become part of base rootfs

### Return to Immutable Runtime

1. Reboot and select:
   - `Alpine Linux (immutable root, overlaytmpfs)`
2. Or from maintenance shell:
   - `e54c-boot-mode reboot-immutable`
2. Verify root command line includes `overlaytmpfs=yes`.

### One-Shot Behavior

1. `e54c-boot-mode reboot-maintenance` sets next boot label to maintenance.
2. Early boot service `e54c-bootmode-oneshot` runs in maintenance mode and restores default label to immutable.
3. A second reboot returns to immutable mode automatically.
4. Native `reboot`/`shutdown` commands do not directly select extlinux labels; use the helper script.

## 4) Update Strategy for Running Systems

### Summary Recommendation

Current implementation is a **single-slot immutable runtime + maintenance boot mode**.

For fleet/OTA hardening, evolve to **A/B slots** for kernel + DTB + rootfs.

### Why A/B Is Still the End-State

1. Kernel, DTB, modules, and userspace must stay version-matched.
2. In-place updates are power-loss fragile and harder to roll back safely.
3. A/B allows atomic switch and quick rollback.

### Strategy Comparison

#### Option A: In-place update of active rootfs

Pros:

1. Simplest partition layout.
2. Lowest storage overhead.

Cons:

1. High risk if power loss occurs during update.
2. Hard rollback when kernel or modules mismatch.
3. Requires careful service stop ordering.

Verdict: acceptable for controlled manual maintenance, not best long-term OTA design.

#### Option B: Boot-time “check and copy over active rootfs” (middle ground)

Pros:

1. Keeps single rootfs partition externally.
2. Can stage updates in `config` partition.

Cons:

1. Still rewrites active slot and is interruption-sensitive.
2. If kernel changes, old kernel boots updater logic before new userspace is installed.
3. Recovery complexity grows quickly.

Verdict: workable for prototypes, not ideal for robust field lifecycle.

#### Option C: A/B rootfs (recommended)

Pros:

1. Safe rollback path.
2. Natural health-check and boot-attempt control.
3. Kernel+DTB+modules+rootfs can be switched as one unit.

Cons:

1. Requires extra partition space and boot config logic.

Verdict: best sustainability/correctness tradeoff.

## Practical A/B Design for This Project

1. Keep `config` as shared state/update staging.
2. Use two boot+root slots:
   - Slot A: `boot_a`, `rootfs_a`
   - Slot B: `boot_b`, `rootfs_b`
3. Keep two extlinux entries, one per slot, each with matching:
   - kernel path
   - DTB path
   - `root=PARTLABEL=rootfs_a` or `rootfs_b`
4. Update inactive slot fully, verify files/checksums, then switch default boot entry.
5. Mark “pending” boot in `config` state.
6. On successful service health-check after boot, mark slot healthy.
7. If health-check fails or bootcount exceeds threshold, roll back to previous slot.

## Kernel Update Compatibility Rule

When kernel changes, update these as one versioned bundle:

1. `Image`
2. `rk3588s-radxa-e54c-spi.dtb` (and any needed DTBs)
3. `/lib/modules/<kernel-release>`
4. Userland package set that depends on kernel ABI

Never switch only one of these components.

## Suggested Next Implementation Steps

1. Add an image assembler mode that creates A/B partition layout.
2. Add extlinux generation for dual entries and default-slot selection.
3. Add an updater script that writes inactive slot from a signed bundle in `config`.
4. Add a boot health marker service and rollback logic using state in `config`.

## 5) USB-Carried Update Workflow (Implemented)

This repository now supports building a USB updater image that carries a full NVMe image payload.

Build command:

```bash
scripts/build-usb-updater-image.sh
```

Write updater image to USB media:

```bash
sudo scripts/write-image-to-nvme.sh --image build/e54c-alpine-usb-updater.img --device /dev/sdX --yes
```

Default artifacts:

1. Source NVMe image payload: `build/e54c-alpine-custom.img`
2. USB updater image: `build/e54c-alpine-usb-updater.img`

### Device Boot Prerequisite

SPI U-Boot must try USB before NVMe, for example:

```text
boot_targets=usb0 nvme0
```

If persistent environment is not available, this must be set in the SPI U-Boot build defaults.

### Runtime Update Sequence

1. Insert USB updater stick.
2. Reboot/power-cycle E54C.
3. U-Boot boots USB updater image.
4. OpenRC service `e54c-usb-nvme-update` verifies payload checksum and flashes NVMe.
5. On success, updater renames USB `/extlinux/extlinux.conf` to `.disabled`.
6. Updater reboots.
7. U-Boot no longer sees bootable extlinux on USB and falls through to NVMe.

### Why This Avoids Boot Loops

1. USB media self-disables its own extlinux entry only after successful flash.
2. Leaving the USB stick inserted still results in NVMe boot on the next cycle.

### Key Environment Knobs

1. `NVME_IMAGE_PATH` - payload source image to embed.
2. `USB_UPDATER_IMAGE_PATH` - output updater image path.
3. `UPDATER_TARGET_NVME_DEVICE` - target device inside updater runtime (default `/dev/nvme0n1`).
4. `USB_IMAGE_SIZE` - force updater image size (otherwise auto-calculated from payload size + overhead).
5. `UPDATER_OVERHEAD_MIB` - extra capacity added to payload when auto-sizing.
