###### SPDX-License-Identifier: MIT
###### Copyright (c) 2026 Ian Spray

![alpian logo](alpian.png "alpian logo")

# About Alpian

This project is based on [Alpine Linux](https://alpinelinux.org) and extends the basic ramdisc deployment to also include u-boot and Linux kernel build helpers for multiple AArch64 SBC's.  The Rdaxa devices in particular often have outadted or odd build frameworks, and each SBC often gets an a different framework with no backporting.

Rather than fight with the manufacturer tooling, this project has been created to offer a very similar base O/S experience across a range of accessible AArch64 SBC's, and to make it easier to configure the O/S via custom APK's so that creating a tailored O/S is potentially easier than trying to cut down a more fully featured Linux system to fit on smaller install media.

The focus is on long-term headless reliability in deployments where power supplies and networking at not provided with any guarantees - by utilising a ramdisc base system, and by offering an easier way in to wrangling OverlayFS tool deployments, the SBC's can survive unexpected outages without risk of file system corruption.  By utilising the Alpine Linux `lbu` command, customisation can be kept for a specific machine, wven with an ephemeral root image.

## Layout
Key directories and files, with the entries that are marked `...` varying in content based on the board type being built, and what user customisations may have been applied:

```
.
├── alpian.png
├── boards
│   ├── common
│   │   └── ...
│   ├── e25
│   │   └── ...
│   ├── e52c
│   │   └── ...
│   ├── e54c
│   │   └── ...
│   ├── r3s
│   │   └── ...
│   ├── rock3b
│   │   └── ...
│   ├── rock5b
│   │   └── ...
│   ├── rpi4
│   │   └── ...
│   └── rpi5
│       └── ...
├── build
│   ├── apk
│   │   ├── alpian
│   │   │   └── aarch64
│   │   │       └── ...
│   │   ├── e25
│   │   │   └── aarch64
│   │   │       └── ...
│   │   ├── e52c
│   │   │   └── aarch64
│   │   │       └── ...
│   │   ├── e54c
│   │   │   └── aarch64
│   │   │       └── ...
│   │   ├── r3s
│   │   │   └── aarch64
│   │   │       └── ...
│   │   ├── rock3b
│   │   │   └── aarch64
│   │   │       └── ...
│   │   ├── rock5b
│   │   │   └── aarch64
│   │   │       └── ...
│   │   ├── rpi4
│   │   │   └── aarch64
│   │   │       └── ...
│   │   └── rpi5
│   │       └── aarch64
│   │           └── ...
│   ├── aports
│   │   ├── abuild.rsa
│   │   ├── abuild.rsa.pub
│   │   ├── alpian
│   │   │   └── ...
│   │   ├── e25
│   │   │   └── ...
│   │   ├── e52c
│   │   │   └── ...
│   │   ├── e54c
│   │   │   └── ...
│   │   ├── r3s
│   │   │   └── ...
│   │   ├── rock3b
│   │   │   └── ...
│   │   ├── rock5b
│   │   │   └── ...
│   │   ├─── rpi4
│   │   │   └── ...
│   │   └── rp5i
│   │       └── ...
│   ├── bootfs
│   │   └── ...
│   └── rootfs-overlay
│       └── ...
├── cache
│   ├── apk
│   ├── apk-cache
│   │   └── ...
│   ├── linux
│   │   └── ...
│   └── u-boot
│       └── ...
├── LICENCE.md
├── Makefile
├── NOTES_FROM_A_HUMAN.md
├── out
│    └─── ...
├── README.md
└── tools
    ├── abuild-pkg.sh
    ├── alpian-build.sh
    └── Containerfile
```

# Copyright and Licence

Code created by the project &copy; 2026 Ian Spray and is MIT licenced (see [LICENCE.md](LICENCE.md) for details).

There may be significant amounts of non-project code present as this tool modifies many other projects, and for those portions the original licence of that code still applies.
