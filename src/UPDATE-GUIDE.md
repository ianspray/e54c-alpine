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
   - `build/kernel-artifacts/<release>/boot/dtbs/rockchip/rk3588s-radxa-e54c.dtb` exists.
   - `build/kernel-artifacts/<release>/rootfs/lib/modules/<release>` exists.
   - Image contains `/lib/modules/<release>`.

Sustainability notes:

1. Treat `assets/reference/radxa/custom-kernel.fragment` as a compatibility contract for E54C features.
2. Keep E54C-critical networking options pinned (DSA + Realtek switch stack).
3. Never ship a new kernel without its matching modules directory in the same image.

## 3) Update Strategy for Running Systems

### Summary Recommendation

Use **A/B slots** for kernel + DTB + rootfs updates.  
Do not update the active rootfs in place for normal OTA workflow.

### Why A/B Is Best Here

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

Verdict: acceptable only for manual maintenance windows, not best long-term OTA design.

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
2. `rk3588s-radxa-e54c.dtb` (and any needed DTBs)
3. `/lib/modules/<kernel-release>`
4. Userland package set that depends on kernel ABI

Never switch only one of these components.

## Suggested Next Implementation Steps

1. Add an image assembler mode that creates A/B partition layout.
2. Add extlinux generation for dual entries and default-slot selection.
3. Add an updater script that writes inactive slot from a signed bundle in `config`.
4. Add a boot health marker service and rollback logic using state in `config`.
