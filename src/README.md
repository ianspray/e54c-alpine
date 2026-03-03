# E54C Custom Kernel Workflow

This repository now contains a reproducible pipeline to:

1. Fetch the Radxa kernel tree with E54C DTS support.
2. Build a custom kernel, modules, and E54C DTBs.
3. Prepare an Alpine aarch64 rootfs with `apk`, `openrc`, `alpine-conf` (`lbu`), and `openssh`.
4. Assemble an NVMe-bootable raw disk image using Radxa bootloader offsets.

## Commands

Run commands from the repository root.

```bash
scripts/check-tooling.sh
scripts/fetch-uboot-reference-assets.sh
scripts/build-apk-repo.sh
scripts/build-kernel-e54c.sh
scripts/prepare-alpine-rootfs.sh
scripts/assemble-e54c-image.sh
```

One-shot pipeline:

```bash
scripts/build-all-e54c.sh
```

Containerized pipeline (recommended for macOS hosts):

```bash
scripts/run-build-in-container.sh
```

Override the build command (example: main image only):

```bash
scripts/run-build-in-container.sh -- make main-image
```

Build USB updater image (boots from USB, flashes NVMe payload, then reboots):

```bash
scripts/build-usb-updater-image.sh
```

Build patched SPI U-Boot for E54C USB host bring-up:

```bash
scripts/build-uboot-e54c-spi.sh
```

Build/sign all custom APK packages in `apk/aports`:

```bash
scripts/build-apk-repo.sh
```

Container notes:

- `scripts/run-build-in-container.sh` builds `Dockerfile.builder` (Debian Bookworm) and runs your build inside it.
- The container is run with `--privileged` so the existing Linux-native tooling (`guestfish`, loop/partition tooling, nested `podman` for APK build) can execute.
- Artifacts are written to the host via bind mount under `build/`.
- Flashing to USB/NVMe is intentionally not done by the container; use your host-side tooling for that step.
- Detailed guide: `src/CONTAINER-BUILD.md`

Serve the generated custom APK repository over HTTP:

```bash
scripts/serve-apk-repo.sh
```

Create a new OpenRC APK skeleton:

```bash
scripts/new-openrc-apk.sh <package-name> <service-name>
```

Write the generated combined SPI image directly to flash (example):

```bash
sudo flashcp -v build/u-boot-artifacts/<stamp>/spi-u-boot-16MiB.img /dev/mtd0
```

Write USB updater image to a USB stick:

```bash
sudo scripts/write-image-to-nvme.sh --image build/e54c-alpine-usb-updater.img --device /dev/sdX --yes
```

Flash the generated image to NVMe:

```bash
sudo scripts/write-image-to-nvme.sh --device /dev/nvme0n1
```

Non-interactive mode:

```bash
sudo scripts/write-image-to-nvme.sh --device /dev/nvme0n1 --yes
```

Safety test without writing:

```bash
sudo scripts/write-image-to-nvme.sh --device /dev/nvme0n1 --dry-run
```

## Script Index

All scripts in `scripts/` and their primary purpose:

- `scripts/check-tooling.sh`
  - Verify required host build tools are installed.
- `scripts/fetch-uboot-reference-assets.sh`
  - Download/extract `idbloader.img`, `u-boot.itb`, and `rkboot.bin` into `assets/reference/u-boot`.
- `scripts/fetch-radxa-kernel.sh`
  - Clone/update the Radxa kernel source tree used by kernel builds.
- `scripts/build-kernel-e54c.sh`
  - Build kernel image, modules, and DTBs for E54C.
- `scripts/prepare-alpine-rootfs.sh`
  - Build and configure Alpine rootfs content.
- `scripts/assemble-e54c-image.sh`
  - Assemble final main NVMe image from build artifacts.
- `scripts/build-usb-updater-image.sh`
  - Build USB updater image that reflashes NVMe and reboots.
- `scripts/build-uboot-e54c-spi.sh`
  - Build SPI U-Boot artifacts (including `spi-u-boot-16MiB.img`).
- `scripts/build-apk-repo.sh`
  - Build/sign local custom APK repository (Podman-based).
- `scripts/serve-apk-repo.sh`
  - Serve local custom APK repository over HTTP for testing.
- `scripts/new-openrc-apk.sh`
  - Scaffold a new OpenRC-service APK package.
- `scripts/build-all-e54c.sh`
  - Run the common full build pipeline in one command.
- `scripts/run-build-in-container.sh`
  - Build and run the Debian-based containerized pipeline (useful on macOS hosts).
- `scripts/write-image-to-nvme.sh`
  - Safe writer for raw images to target block devices.

Most common operating sequence:

```bash
scripts/check-tooling.sh
scripts/fetch-uboot-reference-assets.sh
scripts/build-apk-repo.sh
scripts/build-kernel-e54c.sh
scripts/prepare-alpine-rootfs.sh
scripts/assemble-e54c-image.sh
scripts/build-usb-updater-image.sh
```

## Notes

- U-Boot bootloader blobs are written at:
  - `idbloader.img` -> LBA `64`
  - `u-boot.itb` -> LBA `16384`
- `scripts/build-uboot-e54c-spi.sh` also emits a pre-composed SPI image:
  - `spi-u-boot-16MiB.img`
  - built by default from the latest Radxa SPI base image with patched `u-boot.itb` injected
  - ready to write from byte `0` of SPI (to `/dev/mtd0` with `flashcp`)
- Partition layout matches Radxa reference image:
  - `p1` `config` FAT32 at `16 MiB` offset, size `256 MiB`
  - `p2` `efi` FAT32, size `300 MiB`
  - `p3` `rootfs` ext4 uses remainder
- USB updater image details:
  - Includes compressed payload derived from `build/e54c-alpine-custom.img`
  - Boots a true diskless updater profile from USB (`diskless=yes` via initramfs)
  - Auto-runs `e54c-usb-nvme-update` service to flash `/dev/nvme0n1`
  - Disables USB boot entries on both EFI (`/extlinux/extlinux.conf`) and rootfs (`/boot/extlinux/extlinux.conf`) after successful flash
  - Reboots so U-Boot can fall through to NVMe on next boot
- Alpine rootfs defaults:
  - Serial-only login on `ttyFIQ0` at `1500000` baud
  - `openrc` enabled for boot + networking + sshd
  - Non-blocking one-shot NTP sync is triggered at boot after networking (`e54c-ntp-sync`)
  - Default boot DTB is `rk3588s-radxa-e54c-spi.dtb`
  - Initramfs (`/boot/initramfs-e54c.cpio.gz`) is generated during image assembly
- Main image boots a single diskless profile by default (U-Boot option 1 only)
  - Initramfs mounts source root partition read-only, populates tmpfs root, then `switch_root`s into RAM root
  - `mdev` service is not enabled; device discovery is via kernel + `devtmpfs`
  - Template service `e54c-dev-perms` applies optional custom `/dev` permissions at boot from `/etc/conf.d/e54c-dev-perms`
  - One-shot mode switch helper available on target: `/usr/sbin/e54c-boot-mode`
  - E54C network defaults: DHCP client on `wan`; `lan1`/`lan2`/`lan3` set to `manual`
  - E54C DSA/Realtek modules are force-loaded via `/etc/modules` at boot
  - Boot-time console/login banner prints currently assigned global IP addresses
  - `lbu` configured with `LBU_MEDIA=config`
  - `config` and `efi` partitions are mounted read-only in normal operation
  - `/etc/apk/cache` points to `/media/config/cache`; remount `config` read-write for maintenance/package operations
  - Root `authorized_keys` is auto-populated from `assets/reference/alpine/root_authorized_keys` when present
- Temporary root password enabled for serial bring-up: `alpine`
  - Custom OpenRC behavior is shipped as APKs:
    - `e54c-openrc-services` (main image boot/runtime helpers)
    - `e54c-usb-updater-services` (USB updater flash flow)

## Customization

- Override serial device/baud:
  - `SERIAL_TTY=ttyS2 SERIAL_BAUD=1500000 scripts/prepare-alpine-rootfs.sh`
- Override default package set:
  - Edit `assets/reference/alpine/packages.txt` (one package per line)
  - or override ad hoc with `ALPINE_PACKAGES="alpine-base alpine-conf openssh curl" scripts/prepare-alpine-rootfs.sh`
- Add custom package repositories for image builds/runtime:
  - Edit `assets/reference/alpine/custom-repositories.txt`
- Add custom package names from those repositories:
  - Edit `assets/reference/alpine/custom-packages.txt`
- Add custom APK signing keys used by those repositories:
  - Place `.rsa.pub` key files in `assets/reference/alpine/custom-keys/`
  - Or build locally with `scripts/build-apk-repo.sh` (Podman) and use the auto-detected local repo in `build/apk-repo/v3.23`
- Keep keys local (not in git) while using `make`:
  - Store local files under `build/local-secrets/` (already ignored by `.gitignore`), for example:
    - `build/local-secrets/root_authorized_keys`
    - `build/local-secrets/custom-keys/*.rsa.pub`
  - Run make with overrides:
    - `ROOT_AUTHORIZED_KEYS_FILE="$PWD/build/local-secrets/root_authorized_keys" CUSTOM_APK_KEYS_DIR="$PWD/build/local-secrets/custom-keys" APK_KEYS_EXPORT_DIR="$PWD/build/local-secrets/custom-keys" make images`
  - `Makefile` stamp hashing follows these overrides, so changing local key files triggers rebuilds automatically.
- Inject root SSH authorized keys during image build:
  - `ROOT_AUTHORIZED_KEYS_FILE=/path/to/authorized_keys scripts/prepare-alpine-rootfs.sh`
- Disable default key injection:
  - `ROOT_AUTHORIZED_KEYS_FILE= scripts/prepare-alpine-rootfs.sh`
- Disable non-blocking boot NTP sync:
  - `ENABLE_BOOT_NTP_SYNC=0 scripts/prepare-alpine-rootfs.sh`
- Override one-shot NTP servers:
  - `BOOT_NTP_SERVERS='pool.ntp.org time.cloudflare.com' scripts/prepare-alpine-rootfs.sh`
- Disable temporary root password in future builds:
  - `ROOT_PASSWORD_HASH= ROOT_PASSWORD_PLAIN= scripts/prepare-alpine-rootfs.sh`
- Set custom root password at build time:
  - `ROOT_PASSWORD_PLAIN='your-password' scripts/prepare-alpine-rootfs.sh`
- Disable force-loading E54C DSA modules:
  - `E54C_FORCE_DSA_MODULES=0 scripts/prepare-alpine-rootfs.sh`
- Override MOTD template used during image build:
  - `MOTD_TEMPLATE_FILE=assets/reference/alpine/motd-main scripts/prepare-alpine-rootfs.sh`
  - `MOTD_TEMPLATE_FILE=assets/reference/alpine/motd-updater scripts/prepare-alpine-rootfs.sh`
- Override default DTB used by extlinux and `/boot/efi/boot/dtbs/rockchip`:
  - `BOARD_DTB_NAME=rk3588s-radxa-e54c.dtb scripts/assemble-e54c-image.sh`
- Override diskless cmdline:
  - `KERNEL_CMDLINE_IMMUTABLE='root=PARTLABEL=rootfs rootfstype=ext4 rootwait console=ttyFIQ0,1500000n8 earlycon nvme_core.default_ps_max_latency_us=0 pcie_aspm=off ro diskless=yes' scripts/assemble-e54c-image.sh`
- Disable initramfs boot path (falls back to direct kernel root mount):
  - `ENABLE_INITRAMFS_BOOT=0 scripts/assemble-e54c-image.sh`
- Override generated initramfs filename:
  - `INITRAMFS_NAME=initramfs-e54c.cpio.gz scripts/assemble-e54c-image.sh`
- Customize fixed peripheral permissions (on target):
  - edit `/etc/conf.d/e54c-dev-perms` and add rules like:
  - `/dev/ttyUSB* root:dialout 0660`

## On-Device Boot Mode

- Main image now uses a single diskless boot label (`immutable`).
- Standard `reboot`/`shutdown` will always return to that diskless profile.

## USB-First Update Flow

To use USB media as an update carrier, SPI U-Boot must prefer USB before NVMe.

Expected boot target order:

```text
usb0 nvme0
```

Typical U-Boot commands (on the E54C U-Boot console):

```text
setenv boot_targets usb0 nvme0
saveenv
```

If `saveenv` is unavailable/persistent storage is not configured, SPI U-Boot must be rebuilt/reflashed with USB-first default boot order.

## Operations Guide

- See `src/UPDATE-GUIDE.md` for sustainable version update workflows and OTA strategy guidance.
- See `src/UBOOT-USB-FINDINGS.md` for source-backed U-Boot USB findings and rationale for DTS patching.
