##### SPDX-License-Identifier: MIT
##### Copyright (c) 2026 Ian Spray

# apkfetch

Scans Containerfiles, shell scripts, and Makefiles for `apk add` calls, resolves
transitive dependencies against the Alpine package index, and downloads all
required `.apk` files to a local cache directory. Subsequent `podman build`
invocations can use that directory as a local repository — no internet required.

## Usage

```sh
make fetch                          # scan . for apk add calls, cache to ./apk-cache
make fetch VERSION=v3.20            # different Alpine version
make fetch CACHE_DIR=/shared/apks   # shared cache across projects
make fetch SCAN_DIRS="./api ./worker ./scripts"
```

Or call the binary directly:

```sh
./apkfetch [flags] [scan-path ...]

Flags:
  -mirror   string   Alpine mirror base URL (default: https://dl-cdn.alpinelinux.org/alpine)
  -version  string   Alpine version, e.g. v3.23 (default: v3.23)
  -arch     string   target architecture (default: aarch64)
  -cache    string   local cache directory (default: ./apk-cache)
  -pkg      string   comma-separated extra packages to always include
  -no-index          skip APKINDEX generation
  -v                 verbose output
```

Multiple scan paths are accepted as positional arguments. If none are given,
the current directory is scanned recursively.

## What gets scanned

Any file matching these patterns is parsed for `apk add` calls:

- `Dockerfile`, `Dockerfile.*`
- `*.sh`, `*.bash`
- `Makefile`, `makefile`, `*.mk`

Backslash line continuations are joined before parsing. Flags (words starting
with `-`) are ignored. `so:` and `pc:` virtual dependencies are skipped during
dep resolution.

## Using the cache in a Dockerfile

Create a named container volume which holds the APK files that have been
downloaded by the `apkfetch` tool:

```sh
podman volume create apk-cache
podman run --rm \
  -v apk-cache:/dest \
  -v $(pwd)/cache/apk-cache:/src:ro \
  alpine:3.23 \
  cp -r /src/. /dest/
```

Build the container by placing the named container volume at a known path
within the container, and then referencing those directly without checking
for a trust key:

```dockerfile
FROM alpine:3.23.3

COPY cache/apk-cache /apk-cache
RUN apk add --no-network --allow-untrusted \
    --repository /apk-cache \
    alpine-base \
    alpine-sdk \
    abuild \
    mkinitfs \
    genimage \
    e2fsprogs \
    dosfstools \
    mtools \
    busybox \
    util-linux \
    git \
    rsync \
    curl \
    wget \
    linux-lts
```

## Notes

- `apkfetch` always fetches the `main` and `community` repos. `testing` and
  `edge` are not supported — add `-pkg` for anything that requires them and
  download manually.
- Re-running `make fetch` is idempotent: already-cached `.apk` files are not
  re-downloaded.
- For multi-arch builds, run once per arch
