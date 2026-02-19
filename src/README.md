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
scripts/build-kernel-e54c.sh
scripts/prepare-alpine-rootfs.sh
scripts/assemble-e54c-image.sh
```

One-shot pipeline:

```bash
scripts/build-all-e54c.sh
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

## Notes

- U-Boot bootloader blobs are written at:
  - `idbloader.img` -> LBA `64`
  - `u-boot.itb` -> LBA `16384`
- Partition layout matches Radxa reference image:
  - `p1` `config` FAT32 at `16 MiB` offset, size `256 MiB`
  - `p2` `efi` FAT32, size `300 MiB`
  - `p3` `rootfs` ext4 uses remainder
- Alpine rootfs defaults:
  - Serial-only login on `ttyFIQ0` at `1500000` baud
  - `openrc` enabled for boot + networking + sshd
  - Immutable runtime mode by default: kernel cmdline uses `overlaytmpfs=yes` and read-only lower root
  - Maintenance boot mode available in extlinux menu with writable rootfs (`rw`, no overlay)
  - One-shot mode switch helper available on target: `/usr/local/sbin/e54c-boot-mode`
  - One-shot reboot workflow auto-restores default boot label to immutable after maintenance boot
  - E54C network defaults: DHCP client on `wan`; `lan1`/`lan2`/`lan3` set to `manual`
  - E54C DSA/Realtek modules are force-loaded via `/etc/modules` at boot
  - Boot-time console/login banner prints currently assigned global IP addresses
  - `lbu` configured with `LBU_MEDIA=config`
  - `config` and `efi` partitions are mounted read-only in normal operation
  - `/etc/apk/cache` points to `/media/config/cache`; remount `config` read-write for maintenance/package operations
  - Temporary root password enabled for serial bring-up: `alpine`

## Customization

- Override serial device/baud:
  - `SERIAL_TTY=ttyS2 SERIAL_BAUD=1500000 scripts/prepare-alpine-rootfs.sh`
- Override default package set:
  - Edit `assets/reference/alpine/packages.txt` (one package per line)
  - or override ad hoc with `ALPINE_PACKAGES="alpine-base alpine-conf openssh curl" scripts/prepare-alpine-rootfs.sh`
- Inject root SSH authorized keys during image build:
  - `ROOT_AUTHORIZED_KEYS_FILE=/path/to/authorized_keys scripts/prepare-alpine-rootfs.sh`
- Disable temporary root password in future builds:
  - `ROOT_PASSWORD_HASH= ROOT_PASSWORD_PLAIN= scripts/prepare-alpine-rootfs.sh`
- Set custom root password at build time:
  - `ROOT_PASSWORD_PLAIN='your-password' scripts/prepare-alpine-rootfs.sh`
- Disable force-loading E54C DSA modules:
  - `E54C_FORCE_DSA_MODULES=0 scripts/prepare-alpine-rootfs.sh`
- Change default boot mode in generated extlinux config:
  - `DEFAULT_BOOT_MODE=maintenance scripts/assemble-e54c-image.sh`
- Override immutable/maintenance cmdlines:
  - `KERNEL_CMDLINE_IMMUTABLE='root=PARTLABEL=rootfs rootfstype=ext4 rootwait console=ttyFIQ0,1500000n8 earlycon ro overlaytmpfs=yes' scripts/assemble-e54c-image.sh`
  - `KERNEL_CMDLINE_MAINTENANCE='root=PARTLABEL=rootfs rootfstype=ext4 rootwait console=ttyFIQ0,1500000n8 earlycon rw' scripts/assemble-e54c-image.sh`

## On-Device Boot Mode Switching

Run on the E54C target as root:

```bash
e54c-boot-mode status
e54c-boot-mode reboot-maintenance
e54c-boot-mode reboot-immutable
```

Additional controls:

```bash
e54c-boot-mode next-maintenance
e54c-boot-mode cancel-next
e54c-boot-mode set-default immutable
e54c-boot-mode set-default maintenance
```

Notes:

- Standard `reboot`/`shutdown` do not natively select an extlinux boot label.
- Use `e54c-boot-mode reboot-maintenance` for a one-shot maintenance boot without serial-console interaction.
- After that maintenance boot, the next reboot returns to immutable by default.

## Operations Guide

- See `src/UPDATE-GUIDE.md` for sustainable version update workflows and OTA strategy guidance.
