# AGENTS.md - Agent Coding Guidelines for alpian

## Project Overview

alpian is a build system for creating custom Alpine Linux images for various AArch64 single-board computers (Radxa E54C/E52C/E25, Rock5B, Rock3B, FriendlyElec NanoPi R3S, Raspberry Pi 4). The project consists of shell scripts, Makefiles, and custom APK package definitions.

## Build Commands

### Standard Build (Makefile)

```bash
# Build main and USB updater images (default board: e54c)
make all
make images

# Build individual components
make apk-repo       # Build local custom APK repository
make uboot-assets   # Fetch reference U-Boot artifacts
make kernel         # Build kernel artifacts
make rootfs         # Prepare the Alpian rootfs
make main-image     # Assemble main image
make usb-updater-image  # Build USB updater image

# Clean build artifacts
make clean          # Remove stamps only
make distclean      # Remove all generated artifacts
```

### Board Selection

```bash
BOARD=e54c make images     # Default
BOARD=rock5b make images
BOARD=rpi4 make images
# Supported: e54c, e52c, e25, rock5b, rock3b, r3s, rpi4
```

### Individual Scripts

```bash
# Full pipeline (runs all steps in sequence)
scripts/build-all.sh

# Individual build steps
scripts/check-tooling.sh              # Verify required host tools
scripts/fetch-uboot-reference-assets.sh
scripts/build-apk-repo.sh
scripts/build-kernel.sh
scripts/prepare-alpian-rootfs.sh
scripts/assemble-image.sh
scripts/build-usb-updater-image.sh

# Containerized build (recommended for macOS)
scripts/build-alpian-in-container.sh
scripts/build-alpian-in-container.sh -- make images

# Write image to device
sudo scripts/write-image-to-nvme.sh --device /dev/nvme0n1 --yes
```

### Environment Variables

Key variables for customization:
- `BOARD` - Target board (e54c, rock5b, etc.)
- `KERNEL_DIR` - Custom kernel source directory
- `OUT_DIR` - Kernel build output directory
- `CROSS_COMPILE` - Cross-compilation toolchain prefix
- `JOBS` - Parallel make jobs
- `CACHE_ROOT` - Override shared cache location
- `ROOT_AUTHORIZED_KEYS_FILE` - SSH keys for root
- `CUSTOM_APK_KEYS_DIR` - APK signing keys directory

## Code Style Guidelines

### Shell Scripts

All shell scripts in this project follow strict conventions:

1. **Shebang and License Header**
   ```bash
   #!/usr/bin/env bash
   # SPDX-License-Identifier: MIT
   ```

2. **Strict Error Handling**
   ```bash
   set -euo pipefail
   ```
   - `-e`: Exit on error
   - `-u`: Exit on undefined variable
   - `-o pipefail`: Pipeline fails if any command fails

3. **Script Directory Resolution**
   ```bash
   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
   ```

4. **Variable Naming**
   - Use uppercase for constants/environment variables
   - Use lowercase for local variables in functions
   - Prefix with meaningful category (e.g., `KERNEL_`, `BOARD_`, `APK_`)

5. **Functions**
   - Define functions before use (or source libraries at top)
   - Use `local` for function-scope variables
   - Use `local` for function parameters
   ```bash
   my_function() {
     local arg1="$1"
     local optional_arg="${2:-default}"
   }
   ```

6. **Error Reporting**
   - Use `>&2` for error messages
   - Include descriptive error context
   ```bash
   echo "Failed to find kernel config: $candidate" >&2
   exit 1
   ```

7. **ShellCheck Compliance**
   - The project uses shellcheck for linting
   - Add disable directives only when necessary
   ```bash
   # shellcheck disable=SC1090
   source "$BOARD_CONFIG_FILE"
   ```

8. **Conditional Expressions**
   - Use `[[ ]]` for bash conditionals (not `[ ]` for string comparisons)
   - Quote variables to handle spaces
   ```bash
   if [[ "$var" == "value" ]]; then
   if [ -f "$file" ]; then
   ```

9. **Arrays**
   - Use arrays for lists of items
   ```bash
   required_cmds=(
     git make gcc bc
   )
   for cmd in "${required_cmds[@]}"; do
   ```

10. **Trap and Cleanup**
    ```bash
    cleanup() {
      rm -rf "$tmp_work"
    }
    trap cleanup EXIT
    ```

### Makefiles

- Use `$(abspath .)` for absolute paths
- Use `.PHONY` for non-file targets
- Include dependency tracking with stamp files
- Use `$(if ...)` for conditional values

### Board Configuration Files

Board-specific configurations live in `boards/<board>/`:
- `board.env` - Main board configuration
- `alpine/packages.txt` - Board-specific APK packages
- `alpine/custom-packages.txt` - Custom APK packages for board
- `kernel/custom-kernel.fragment` - Kernel config fragment
- `kernel/patches/*.patch` - Kernel patches
- `u-boot/idbloader.img`, `u-boot/u-boot.itb` - Bootloader assets

### Python Code

- Used inline in shell scripts for data extraction
- Follow PEP 8 basics (4-space indent)

## Error Handling

- Always validate prerequisites before running main logic
- Use informative error messages with context
- Exit with appropriate error codes (1 for errors, unless specific code needed)
- Clean up temporary resources with traps

## Testing

There is currently no formal test suite in this project. If adding tests:
- Place test files in `tests/` directory
- Use bats-core or similar shell testing framework
- Follow naming: `<script-name>.test.sh`

## Git Conventions

- Primary branch: `main` (not `master`)
- Commit message format: Summary line + blank line + body
- Commit after each completed task
- Include summary of changes in commit body

## File Organization

```
scripts/           - Build and utility scripts
  lib/             - Shared libraries (board-config.sh, cache.sh)
boards/            - Board-specific configurations
  alpian/          - Shared Alpine package lists
  <board>/         - Per-board overrides
apk/aports/        - Custom APK package sources (APKBUILD)
assets/            - Reference inputs (configs, keys, templates)
build/             - Generated artifacts (gitignored)
src/               - Kernel checkouts and documentation
```

## Important Notes

- This is a build system, not an application - no runtime code execution
- Most operations require root/sudo for writing images and block devices
- The project is MIT licensed - add SPDX headers to new files
- When modifying image assembly, be aware of partition offsets and GPT layout
- U-Boot bootloader blobs must be at specific LBA positions (64, 16384)
