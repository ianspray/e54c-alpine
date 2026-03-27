# Alpian Build System
<!-- SPDX-License-Identifier: MIT -->
<!-- Copyright (c) 2026 Ian Spray -->

![alpian logo](alpian.png "alpian logo")

A custom Alpine Linux distribution for AArch64 SBC appliances.

## Overview

This project is based on [Alpine Linux](https://alpinelinux.org) and extends the basic ramdisc deployment to also include u-boot and Linux kern
el build helpers for multiple AArch64 SBC's.  The Rdaxa devices in particular often have outadted or odd build frameworks, and each SBC often g
ets an a different framework with no backporting.

Rather than fight with the manufacturer tooling, this project has been created to offer a very similar base O/S experience across a range of ac
cessible AArch64 SBC's, and to make it easier to configure the O/S via custom APK's so that creating a tailored O/S is potentially easier than
trying to cut down a more fully featured Linux system to fit on smaller install media.

## Target Boards

- Radxa Rock 5B, 5C, 5E, Rock 3B
- Raspberry Pi 4, Pi 5

## Prerequisites

- Docker or Podman installed
- At least 20GB free disk space
- Internet connection for initial build (subsequent builds can work offline with cached assets)

## Quick Start

### 1. Build the container

```bash
make container-build CONTAINER_RUNTIME=podman  # or docker
```

### 2. Run the container

```bash
make container-run CONTAINER_RUNTIME=podman
```

### 3. Inside the container, build for a specific board

```bash
make build-rock5b
```

Or build all boards:

```bash
make all-boards
```

## Build Stages

1. **fetch** - Downloads kernel, U-Boot, rootfs from remote sources
2. **uboot** - Builds U-Boot for target board
3. **kernel** - Builds Linux kernel (per-board configuration)
4. **apk** - Builds custom APK packages
5. **root** - Creates root filesystem with all components
6. **image** - Generates final disk image with genimage

## Output

Built images are located in:
- `output/images/` - Final disk images
- `output/kernel/` - Kernel and modules
- `output/uboot/` - U-Boot binaries
- `output/apk/` - Custom APK packages
- `output/initramfs/` - Initramfs images

## Custom Packages

Add custom APKBUILD files to `packages/<package-name>/` directory. The build system will automatically include them in the build.

## Configuration

- Edit `ALPIAN.md` for distro configuration
- Board-specific genimage configs in `boards/<board>/genimage.config`
- Per-board package lists in `config/packages.conf`

## Clean

```bash
make clean    # Remove build artifacts
make distclean # Remove everything including cache
```

# Licence

All code generated as part of the project is MIT licenced (see LICENCE.md).  Code that has been used from external projects will honour that licence, and those projects should be consulted for details.
