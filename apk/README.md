# Custom APK Repository Workflow

This directory holds custom Alpine packages (APK) for board images.

## Layout

- `apk/aports/<namespace>/<package>/APKBUILD`
- `apk/aports/<namespace>/<package>/*` package source files

Current namespaces include `e54c`, `rock5b`, `rock3b`, and `rpi4` for board specific packages, and `alpian` for common ones.

## Build All Packages

```bash
scripts/build-apk-repo.sh
```

This script:

1. Builds or reuses a local Alpine Podman builder image from `containers/apk-builder/Containerfile`.
2. Builds all `APKBUILD` entries under `apk/aports` in that Alpine Podman container.
3. Produces a signed APK repository at `build/apk-repo/v3.23/aarch64` by default.
4. Exports public signing keys to `assets/reference/alpine/custom-keys`.

Set `APK_REBUILD_IMAGE=1` to force a rebuild of the local builder image.
By default, downloaded Alpine packages and `abuild` distfiles are cached in `build/cache/apk/` and `build/cache/distfiles/`.

If the checksums have not changed in the apk tree, then use: `APK_REFRESH_CHECKSUMS=0 ./scripts/build-apk-repo.sh` to skip computing the checksums for a quicker build.

By default, `aarch64` packages are constructed - if a different architecture (ie: `x86_64`) should be built, then: `APK_ARCH="x86_64" ./scripts/build-apk-repo.sh` will do that.

## Serve Repository

```bash
scripts/serve-apk-repo.sh
```

Default URL root is `http://<host>:8080/`.
Repository URL to place in Alpine repositories is typically:

```text
http://<host>:8080/v3.23
```

## Include in Image Builds

1. Add repository URL to `assets/reference/alpine/custom-repositories.txt`.
2. Add shared custom package names to `boards/alpian/alpine/custom-packages.txt`.
3. Add board-specific custom package names to `boards/<board>/alpine/custom-packages.txt` when needed.
4. Rebuild:

```bash
scripts/prepare-alpian-rootfs.sh
scripts/assemble-image.sh
```

`prepare-alpian-rootfs.sh` now reads:

- `assets/reference/alpine/custom-repositories.txt`
- `boards/alpian/alpine/custom-packages.txt`
- `boards/<board>/alpine/custom-packages.txt`
- `assets/reference/alpine/custom-keys/*.pub`
- local repository `build/apk-repo/v3.23` automatically (when present)
- local keys from `build/apk-repo/keys` automatically (when present)

So custom APKs are preinstalled into image builds and not stored in `lbu` overlays.

## Create a New OpenRC Package Skeleton

```bash
scripts/new-openrc-apk.sh <package-name> <service-name>
```

Example:

```bash
scripts/new-openrc-apk.sh e54c-openrc-foo e54c-foo
```
