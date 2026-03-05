# Custom APK Repository Workflow

This directory holds custom Alpine packages (APK) for board images.

## Layout

- `apk/aports/<namespace>/<package>/APKBUILD`
- `apk/aports/<namespace>/<package>/*` package source files

Current namespaces include `e54c`, `rock5b`, and `rpi4`.

## Build All Packages

```bash
scripts/build-apk-repo.sh
```

This script:

1. Builds all `APKBUILD` entries under `apk/aports` in an Alpine Podman container.
2. Produces a signed APK repository at `build/apk-repo/v3.23/aarch64` by default.
3. Exports public signing keys to `assets/reference/alpine/custom-keys`.

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
2. Add custom package names to `assets/reference/alpine/custom-packages.txt`.
3. Rebuild:

```bash
scripts/prepare-alpine-rootfs.sh
scripts/assemble-image.sh
```

`prepare-alpine-rootfs.sh` now reads:

- `assets/reference/alpine/custom-repositories.txt`
- `assets/reference/alpine/custom-packages.txt`
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
