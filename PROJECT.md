# Project: alpian

## Stack
- Different AArch64 Single Board Computers, eg:
  - Radxa E54C
  - Radxa Rock5B
  - Radxa Rock3B
  - FriendlyElec NanoPi R3S
  - Raspberry Pi 4
- Where the hardware supports it:
  - NVMe booting or eMMC booting
  - SPI Flash with uBoot
  - USB for recovery image booting
- Alpine Linux
  - Run from an initrd
  - Restricted amounts of free space in the RAM disc
  - Custom APK builds
  - Additional APK installations in the initrd


## Rules
- Modifications to existing bootable images need to be done in a way that can be scripted
- Care must be taken over the booting details for the Radxa devices
  - Partitions need to be declared at specific offsets
  - There may be binary data in the bootable image that is not inside a partition
- If anything is unclear, pause and await clarification
  - Always clearly present the problem that needs to be addressed
  - Additional discussion may be required after problem presentation before an action can be chosen
- A more modern Linux kernel is always more useful than a stock Radxa one
- Once the build completes, and a summary of the changes has been made, commit all changes to the local repo and ensur
e that the change summary is in the body of the commit message
- When creating a local git repo, use `main` for the primary branch, and NOT `master`

## Architecture
- Use a Debian AArch64 base system for constructing the initial system
  - Also maintain a containerised build mechanism that re-uses the native Linux scripts
- The Alpine Linux releases will always have a more recent kernel than the Radxa ones
- Not all of the Radxa kernel modules may build outside of the Rdaxa tree
- The Alpine Linux build system may be utilised if it is advantageous
  - When rebuilding via the Alpine system, the features of the Radxa kernel should be merged with that of the Alpine one
- Use of userland image manipulation tooling such as guestfish is prererable over 100% custom scripts 
- It is expected that custom scripting will be required
- The ability to take a newer version of Alpine and re-run the system in the future is a primary design aim
- When building a Linux kernel and modules, the modules should be built in a way that allows easy insertion via modprobe
- Ensure there is a formal build process for custom APK images
  - Capture any custom boot scripts into an APK
  - Link the scroipts into the OpenRC startup process
  - Prefer APK capture over modification of the base Alpine image
- Use the Alpine diskless mode (tmpfs RAM execution)
- Maintain both a regular boot (main) image, and a USB Updater image
  - The USB Updater should have an embedded copy of the main image
  - The system u-boot shoudl boot from USB by preference if it has a valid image
  - Once started, the USB updater should emit progress markers to the serial console
  - The Updater must reflash the internal NVMe image with the copy it carries
  - After updating, the USB Updater should make itself non-bootable as far as u-boot is concerned
  - It should then reboot the system, which will then skip the USB drive and contonue on to boot into NVMe
- The E54C SPI u-boot image may need to be updated to enable USB booting
- All code generated for this project is under the MIT licence
  - Each file that is generated that supports comments, must indicate the licence via SPDX
  - The SPDX header line `SPDX-License-Identifier: MIT` should be used
  - For shell scripts, do not break the `#!` first line declaration with SPDX
  - For files that are downloaded, do not claim or modify any licence information

## Development
- After each set of changes, the code should be committed into the local git repository
- Each git commit should have a summary of the changes in the commit
  - If a summary has been displayed in the chat, then this should be used as the basis for the git summary

## Clarifications
- Treat all listed boards as first-class targets from the start
- Assume AArch64 as the target architecture
  - Builds may run natively on Linux
  - Builds may also run in a containerised workflow under macOS
- Kernel selection should prefer the newest practical kernel that still enables board-specific hardware
  - Alpine kernels are slightly preferred when they satisfy the hardware requirements
  - If a Radxa or other vendor kernel is newer than the Alpine option, the newer vendor kernel may be used
  - If board-specific features cannot be ported from the vendor kernel to a newer kernel, pause and ask the user to choose between the two version numbers
- The image filenames listed in this document are operator-supplied reference inputs
  - They are not required to exist in the repository by default
- Commit at the end of every completed task by default
- Open clarification:
  - Define the exact mechanism the USB updater should use after flashing to make itself non-bootable to u-boot

## E54C Guides
- Radxa documentation about the E54C: https://docs.radxa.com/en/e/e54c
- The Radxa guide to booting the E54C from NVMe: https://docs.radxa.com/en/e/e54c/getting-started/install-os/boot_from_nvme

## E54C Files
- The Alpine image that should be booted on the E54C:
  - alpine-standard-3.23.3-aarch64.iso
- An Alpine image that is booted using uBoot, which may be uyseful for reference:
  - alpine-uboot-3.23.3-aarch64.tar.gz
- The official Radxa E54C Debian image:
  - radxa-e54c_bookworm_cli_b2.output.img.xz
