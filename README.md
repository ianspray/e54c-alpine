###### SPDX-License-Identifier: MIT
###### Copyright (c) 2026 Ian Spray

![alpian.png]

# About Alpian

# Layout

```
.
├── alpian-build.sh
├── alpian.png
├── boards
│   ├── e25
│   │   ├── e25.env
│   │   └── genimage.e25
│   ├── e52c
│   │   └── e52c.env
│   ├── e54c
│   │   └── e54c.env
│   ├── rock3b
│   │   └── rock3b.env
│   ├── rock5b
│   │   └── rock5b.env
│   ├── rpi4
│   │   └── rpi4.env
│   └── rpi5
│       └── rpi5.env
├── build
│   ├── apk.keys
│   ├── aports
│   │   ├── alpian
│   │   ├── e25
│   │   ├── e52c
│   │   ├── e54c
│   │   ├── r3s
│   │   ├── rock3b
│   │   ├── rock5b
│   │   └── rpi4
│   ├── boot
│   │   └── extlinux
│   ├── mkinitfs
│   │   └── features.d
│   ├── packages.txt
│   └── rootfs-overlay
│       └── etc
├── cache
│   ├── apk-cache
│   │   └── aarch64
│   ├── linux
│   │   └── radxa
│   └── u-boot
│       └── radxa
├── Makefile
├── out
├── README.md
└─── tools
    ├── apkfetch
    │   ├── apkfetch
    │   ├── go.mod
    │   ├── main.go
    │   ├── Makefile
    │   ├── README.md
    │   └── scan_test.go
    ├── Containerfile
    └── Makefile
```
