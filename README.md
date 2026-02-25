# e54c-alpine

Top-level orientation for the repository and cleanup behavior.

For full build/run details, see `src/README.md`.

## Directory Layout

- `scripts/`
  - Build and packaging entry points (kernel, rootfs, image assembly, APK repo, SPI U-Boot, USB updater).
- `assets/`
  - Version-controlled reference inputs (configs, DTS patches, package lists, MOTD templates, keys).
- `apk/`
  - Custom Alpine APK package sources (`APKBUILD` + service payload files).
- `src/`
  - Project documentation and (optionally) local kernel checkout(s).
- `tests/`
  - Test helpers/placeholders.
- `build/`
  - Generated artifacts and temporary build state.
- `work/`
  - Scratch area (legacy/manual workflows), not required by the default scripted pipeline.
- `.git/`
  - Git metadata.

## Auto-Populated / Safe-To-Delete Directories

These can be removed and will be recreated by scripts when needed.

- `build/`
  - Recreated by all build scripts (`scripts/build-*.sh`, `scripts/prepare-alpine-rootfs.sh`, `scripts/assemble-e54c-image.sh`).
  - Contains outputs like kernel artifacts, rootfs tarball, image files, APK repo, U-Boot build trees.
- `src/radxa-kernel-e54c/`
  - Recreated by `scripts/fetch-radxa-kernel.sh` (called by `scripts/build-kernel-e54c.sh`).
  - This is a local git clone of the Radxa kernel branch.

## Safe-To-Delete But Not Script-Critical

- `work/`
  - Safe to remove.
  - Not part of the default build path; current main scripts do not require it.

## Most Common Operating Sequence

```bash
scripts/check-tooling.sh
scripts/build-apk-repo.sh
scripts/build-kernel-e54c.sh
scripts/prepare-alpine-rootfs.sh
scripts/assemble-e54c-image.sh
scripts/build-usb-updater-image.sh
```

## Notes

- `.gitignore` already marks generated trees (`build/`, `work/`, `src/radxa-kernel/`, `src/radxa-kernel-e54c/`) as non-tracked.
- If disk space cleanup is needed, deleting `build/` is the highest-impact safe reset.
