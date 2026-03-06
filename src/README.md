# Board Build Workflow

This repository now contains a reproducible pipeline to:

1. Prepare board-specific kernel/boot artifacts.
2. Build a custom or prebuilt kernel payload, modules, and board DTBs.
3. Prepare an Alpine aarch64 rootfs with `apk`, `openrc`, `alpine-conf` (`lbu`), and `openssh`.
4. Assemble a bootable raw disk image using the selected board boot flow.

## Commands

Run commands from the repository root.  
Select a board with `BOARD=<name>` (default: `e54c`).

Supported board profiles:

- `e54c`
- `rock5b`
- `rock3b`
- `rpi4`

```bash
BOARD=e54c scripts/check-tooling.sh
BOARD=e54c scripts/fetch-uboot-reference-assets.sh
BOARD=e54c scripts/build-apk-repo.sh
BOARD=e54c scripts/build-kernel.sh
BOARD=e54c scripts/prepare-alpian-rootfs.sh
BOARD=e54c scripts/assemble-image.sh
```

Equivalent:

```bash
make BOARD=e54c main-image
make BOARD=rock5b main-image
make BOARD=rock3b main-image
make BOARD=rpi4 main-image
```

One-shot pipeline:

```bash
scripts/build-all.sh
```

Containerized pipeline (recommended for macOS hosts):

```bash
scripts/build-alpian-in-container.sh
```

Override the build command (example: main image only):

```bash
scripts/build-alpian-in-container.sh -- make main-image
```

Build USB updater image (boots from USB, flashes NVMe payload, then reboots):

```bash
scripts/build-usb-updater-image.sh
```

Build patched SPI U-Boot for E54C USB host bring-up:

```bash
scripts/build-uboot-spi.sh
```

Build/sign all custom APK packages in `apk/aports`:

```bash
scripts/build-apk-repo.sh
```

Container notes:

- `scripts/build-alpian-in-container.sh` builds `Dockerfile.builder` (Debian Bookworm) and runs your build inside it.
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
sudo BOARD=e54c scripts/write-image-to-nvme.sh --image build/e54c-alpian-usb-updater.img --device /dev/sdX --yes
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
  - Download board SPI image and extract required `idbloader.img` and `u-boot.itb` into `boards/<board>/u-boot`.
  - Uses board fetch profile defaults from `boards/<board>/u-boot-fetch.env` when present.
- `scripts/fetch-radxa-kernel.sh`
  - Clone/update the Radxa kernel source tree used by Radxa kernel builds.
  - Applies optional board-local patches from `boards/<board>/kernel/patches/*.patch`.
- `scripts/build-kernel.sh`
  - Build or fetch kernel image, modules, and DTBs for the selected board profile.
- `scripts/prepare-alpian-rootfs.sh`
  - Build and configure Alpine rootfs content.
  - Uses shared package defaults from `boards/alpian/alpine/packages.txt`, board overlays from
    `boards/<board>/alpine/packages.txt`, shared custom package defaults from
    `boards/alpian/alpine/custom-packages.txt`, and board custom package overlays from
    `boards/<board>/alpine/custom-packages.txt`.
- `scripts/assemble-image.sh`
  - Assemble final main NVMe image from build artifacts.
- `scripts/build-usb-updater-image.sh`
  - Build USB updater image that reflashes NVMe and reboots.
- `scripts/build-uboot-spi.sh`
  - Build SPI U-Boot artifacts (including `spi-u-boot-16MiB.img`).
- `scripts/build-apk-repo.sh`
  - Build/sign local custom APK repository (Podman-based).
- `scripts/serve-apk-repo.sh`
  - Serve local custom APK repository over HTTP for testing.
- `scripts/new-openrc-apk.sh`
  - Scaffold a new OpenRC-service APK package.
- `scripts/build-all.sh`
  - Run the common full build pipeline in one command.
- `scripts/build-alpian-in-container.sh`
  - Build and run the Debian-based containerized pipeline (useful on macOS hosts).
- `scripts/write-image-to-nvme.sh`
  - Safe writer for raw images to target block devices.

Most common operating sequence:

```bash
scripts/check-tooling.sh
scripts/fetch-uboot-reference-assets.sh
scripts/build-apk-repo.sh
scripts/build-kernel.sh
scripts/prepare-alpian-rootfs.sh
scripts/assemble-image.sh
scripts/build-usb-updater-image.sh
```

## Notes

- Kernel source defaults are aligned across Radxa-source boards (`e54c`, `rock5b`, `rock3b`) to the same
  Radxa branch by default. Board differences should be kept in:
  - `boards/<board>/kernel/custom-kernel.fragment`
  - `boards/<board>/kernel/patches/*.patch` (only when required)

- `rock3b` backports the upstream ROCK 3B device tree into the shared Radxa BSP branch
  and uses `rk3568-rock-3b.dtb` as the default boot DTB.

- `rpi4` uses Alpine's published Raspberry Pi image as the kernel/firmware/modules source
  (configured in `boards/rpi4/board.env`) and boots via Pi firmware
  (`config.txt` + `cmdline.txt`) without SPI U-Boot injection.

- U-Boot bootloader blobs are written at:
  - `idbloader.img` -> LBA `64`
  - `u-boot.itb` -> LBA `16384`
- `scripts/build-uboot-spi.sh` also emits a pre-composed SPI image:
  - `spi-u-boot-16MiB.img`
  - built by default from the latest Radxa SPI base image with patched `u-boot.itb` injected
  - ready to write from byte `0` of SPI (to `/dev/mtd0` with `flashcp`)
- Partition layout matches Radxa reference image:
  - `p1` `config` FAT32 at `16 MiB` offset, size `256 MiB`
  - `p2` `efi` FAT32, size `300 MiB`
  - `p3` `rootfs` ext4 uses remainder
- USB updater image details:
  - Includes compressed payload derived from `build/<board>-alpian-custom.img`
  - Boots a true diskless updater profile from USB (`diskless=yes` via initramfs)
  - Auto-runs `e54c-usb-nvme-update` service to flash `/dev/nvme0n1`
  - Disables USB boot entries on both EFI (`/extlinux/extlinux.conf`) and rootfs (`/boot/extlinux/extlinux.conf`) after successful flash
  - Reboots so U-Boot can fall through to NVMe on next boot
- Alpine rootfs defaults:
  - Serial-only login on `ttyFIQ0` at `1500000` baud
  - `openrc` enabled for boot + networking + sshd
  - Non-blocking one-shot NTP sync is triggered at boot after networking (`e54c-ntp-sync`)
  - Default boot DTB is `rk3588s-radxa-e54c-spi.dtb`
  - Initramfs (`/boot/initramfs-<board>.cpio.gz`) is generated during image assembly
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
  - `SERIAL_TTY=ttyS2 SERIAL_BAUD=1500000 scripts/prepare-alpian-rootfs.sh`
- Override default package set:
  - Edit `boards/alpian/alpine/packages.txt` for common packages
  - Edit `boards/<board>/alpine/packages.txt` for board-specific overlays
  - or override ad hoc with `ALPINE_PACKAGES="alpine-base alpine-conf openssh curl" scripts/prepare-alpian-rootfs.sh`
- Add custom package repositories for image builds/runtime:
  - Edit `assets/reference/alpine/custom-repositories.txt`
- Add custom package names from those repositories:
  - Edit `boards/alpian/alpine/custom-packages.txt` for shared custom packages
  - Edit `boards/<board>/alpine/custom-packages.txt` for board-specific custom packages
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
  - `ROOT_AUTHORIZED_KEYS_FILE=/path/to/authorized_keys scripts/prepare-alpian-rootfs.sh`
- Disable default key injection:
  - `ROOT_AUTHORIZED_KEYS_FILE= scripts/prepare-alpian-rootfs.sh`
- Disable non-blocking boot NTP sync:
  - `ENABLE_BOOT_NTP_SYNC=0 scripts/prepare-alpian-rootfs.sh`
- Override one-shot NTP servers:
  - `BOOT_NTP_SERVERS='pool.ntp.org time.cloudflare.com' scripts/prepare-alpian-rootfs.sh`
- Disable temporary root password in future builds:
  - `ROOT_PASSWORD_HASH= ROOT_PASSWORD_PLAIN= scripts/prepare-alpian-rootfs.sh`
- Set custom root password at build time:
  - `ROOT_PASSWORD_PLAIN='your-password' scripts/prepare-alpian-rootfs.sh`
- Disable force-loading E54C DSA modules:
  - `E54C_FORCE_DSA_MODULES=0 scripts/prepare-alpian-rootfs.sh`
- Override MOTD template used during image build:
  - `MOTD_TEMPLATE_FILE=assets/reference/alpine/motd-main scripts/prepare-alpian-rootfs.sh`
  - `MOTD_TEMPLATE_FILE=assets/reference/alpine/motd-updater scripts/prepare-alpian-rootfs.sh`
- Override default DTB used by extlinux and `/boot/efi/boot/dtbs/rockchip`:
  - `BOARD_DTB_NAME=rk3588s-radxa-e54c.dtb scripts/assemble-image.sh`
- Override diskless cmdline:
  - `KERNEL_CMDLINE_IMMUTABLE='root=PARTLABEL=rootfs rootfstype=ext4 rootwait console=ttyFIQ0,1500000n8 earlycon nvme_core.default_ps_max_latency_us=0 pcie_aspm=off ro diskless=yes' scripts/assemble-image.sh`
- Disable initramfs boot path (falls back to direct kernel root mount):
  - `ENABLE_INITRAMFS_BOOT=0 scripts/assemble-image.sh`
- Override generated initramfs filename:
  - `INITRAMFS_NAME=initramfs-e54c.cpio.gz scripts/assemble-image.sh`
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
