# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Ian Spray

VERSION         ?= v3.23
ARCH            ?= aarch64
APK_CACHE_DIR   ?= ./cache/apk-cache
LINUX_CACHE_DIR ?= ./cache/linux
UBOOT_CACHE_DIR ?= ./cache/u-boot
SCAN_DIRS       ?= .

BOARD		?= e25

include boards/$(BOARD)/$(BOARD).env

.PHONY: build-tools image build build-linux build-uboot build-rootfs build-bootfs fetch fetch-apk fetch-linux fetch-uboot clean index help abuild-keys

$(APKFETCH):
	$(MAKE) -C $(APKFETCH_PATH)

# Scan Containerfiles and shell scripts in SCAN_DIRS, resolve deps, download .apk files.
fetch-apk:
	podman run --rm \
		-v $(CURDIR)/cache/apk-cache:/etc/apk/cache \
		-v $(CURDIR):/src:ro \
		-v $(CURDIR)/tools:/tools:ro \
		alpine:3.23.3 \
		/tools/fetch-apks.sh


#build-tools: fetch-apk tools/Containerfile tools/abuild-pkg.sh tools/alpian-build.sh tools/fetch-apks.sh
build-tools:
	podman build \
		-f tools/Containerfile \
		-v $(CURDIR)/cache/apk-cache:/etc/apk/cache \
		-v $(CURDIR)/tools:/tools:ro \
		-t alpian-builder .

build/aports/abuild.rsa:
	openssl genrsa -out build/aports/abuild.rsa 4096

build/aports/abuild.rsa.pub: build/aports/abuild.rsa
	openssl rsa -in build/aports/abuild.rsa -pubout -out build/aports/abuild.rsa.pub

abuild-keys: build/aports/abuild.rsa build/aports/abuild.rsa.pub

# - - - - - -

fetch-linux:
	mkdir -p ./$(LINUX_CACHE_DIR); \
	podman run --rm -it \
		-v i$(CUR_DIR)/$(LINUX_CACHE_DIR):/work \
		alpian-builder \
		/bin/sh -c 'if [ -d $(KERNEL_DIR)/kernel ]; then \
			git -C $(KERNEL_DIR)/kernel fetch origin && \
			git -C $(KERNEL_DIR)/kernel reset --hard origin/$(KERNEL_BRANCH)  && \
			git -C $(KERNEL_DIR)/kernel clean -fdx; \
		else \
			git clone --branch $(KERNEL_BRANCH) $(KERNEL_REPO) $(KERNEL_DIR); \
		fi'

fetch-uboot:
ifdef UBOOT_REPO
	mkdir -p ./$(UBOOT_CACHE_DIR); \
	podman run --rm -it \
		-v ./$(UBOOT_CACHE_DRR):/work \
		alpian-builder \
		/bin/sh -c 'if [ -d $(UBOOT_DIR)/u-boot ]; then \
			git -C $(UBOOT_DIR)/u-boot fetch origin && \
			git -C $(UBOOT_DIR)/u-boot reset --hard $(UBOOT_BRANCH)  && \
			git -C $(UBOOT_DIR)/u-boot clean -fdx; \
		else \
			git clone --branch $(UBOOT_BRANCH) $(UBOOT_REPO) $(UBOOT_DIR)/u-boot; \
		fi'
else
	@echo "UBOOT_REPO not set - skipping"
endif

# FIXME: this should also depend upon build-tools but only when that image creation
# can be skipped by the make rules when nothing has changed in the apk cache, but
# that may end up being circular in that the container image is needed for both
# fetch-linux and fetch-uboot, but the build depends upon fetch-apk
fetch: fetch-apk fetch-linux fetch-uboot

# - - - - - -

build-linux: build-tools
	podman run --rm -it \
		-v $(CURDIR)/cache:/cache \
		-v $(CURDIR)/boards:/boards:ro \
		-v $(CURDIR)/build:/build \
		-v $(CURDIR)/out:/out \
		alpian-builder \
		sh alpian-kernel.sh

build-uboot: build-tools
	podman run --rm -it \
		-v $(CURDIR)/cache:/cache \
		-v $(CURDIR)/boards:/boards:ro \
		-v $(CURDIR)/build:/build \
		-v $(CURDIR)/out:/out \
		alpian-builder \
		sh alpian-uboot.sh

# gather the assets required in order to be able to build a disc image, but
# do not create the final bootable/flashable output binary itself
#build: build-tools build-linux build-uboot abuild-keys
#build: build-tools
		#-v $(CURDIR)/cache/apk-cache:/home/builder/packages/alpian \
build:
	podman run --rm -it \
		-v $(CURDIR)/cache:/cache \
		-v $(CURDIR)/boards:/boards:ro \
		-v $(CURDIR)/cache/apk-cache:/etc/apk/cache \
		-v $(CURDIR)/build:/build \
		-v $(CURDIR)/out:/out \
		-e BOARD=${BOARD} \
		alpian-builder \
		alpian-build.sh

# assemble the rootfs and bootfs into a functional image for a physical device
image: build-tools build
	podman run --rm -it \
		-v $(CURDIR)/cache:/cache \
		-v $(CURDIR)/rootfs:/rootfs \
		-v $(CURDIR)/bootfs:/bootfs \
		-v $(CURDIR)/out:/out \
		alpian-builder \
		sh alpian-image.sh

# - - - - - -

# tidy up the build tooling
clean:
	podman rmi alpian-builder

# tidy up both the build tooling and all local caches (ie: revert to a clean
# 'just checked out' state)
distclean: clean
	rm -rf $(APK_CACHE_DIR) $(LINUX_CACHE_DIR) $(UBOOT_CACHE_DIR)

# FIXME: ALL OF THE HELP TEXT IS INCORRECT
# try to offer guidance without needing a text editor
help:
	@echo "Targets:"
	@echo "  make build        compile apkfetch"
	@echo "  make fetch        scan + download packages to $(CACHE_DIR)"
	@echo "  make clean        remove binary and cache"
	@echo ""
	@echo "Variables:"
	@echo "  VERSION=$(VERSION)   Alpine version"
	@echo "  ARCH=$(ARCH)       target architecture"
	@echo "  CACHE_DIR=$(CACHE_DIR)  output directory"
	@echo "  SCAN_DIRS=$(SCAN_DIRS)   paths to scan"
	@echo ""
	@echo "Example:"
	@echo "  make fetch VERSION=v3.23 SCAN_DIRS='./services/api ./services/worker'"
