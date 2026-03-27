# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Ian Spray

.PHONY: all build-% clean distclean container-build container-run help fetch uboot kernel apk root image all-boards

BUILD_DIR := $(shell pwd)
CACHE_DIR := $(BUILD_DIR)/cache
OUTPUT_DIR := $(BUILD_DIR)/output
SCRIPTS_DIR := $(BUILD_DIR)/scripts
CONFIG_DIR := $(BUILD_DIR)/config
ABUILD_DIR := $(BUILD_DIR)/.abuild

BOARDS := rock5b rock5c rock5e rock3b rpi4 rpi5

CONTAINER_RUNTIME ?= podman
CONTAINER_NAME := alpian-builder

IN_CONTAINER := $(shell echo $$IN_CONTAINER)

all: help

help:
	@echo "Alpian Build System"
	@echo ""
	@echo "Available targets:"
	@echo "  container-build   - Build the Docker/Podman container"
	@echo "  container-run     - Run interactive container shell"
	@echo "  fetch             - Fetch all remote assets (kernel, uboot, etc.)"
	@echo "  uboot             - Build U-Boot for target boards"
	@echo "  kernel            - Build Linux kernel for target boards"
	@echo "  apk               - Build custom APK packages"
	@echo "  root              - Build root filesystem"
	@echo "  image             - Build final disk image"
	@echo "  build-<board>     - Build image for specific board"
	@echo "  all-boards        - Build images for all boards"
	@echo "  clean             - Clean build artifacts"
	@echo "  distclean         - Clean everything including cache"
	@echo ""

container-build:
	$(CONTAINER_RUNTIME) build -t $(CONTAINER_NAME) -f build/Dockerfile .

container-run:
	$(CONTAINER_RUNTIME) run -it --rm \
		-e IN_CONTAINER=true \
		-v $(CACHE_DIR):/var/cache/distfiles \
		-v $(OUTPUT_DIR):/output \
		-v $(BUILD_DIR):/build \
		-w /build \
		--privileged \
		$(CONTAINER_NAME)

ifneq ($(IN_CONTAINER),true)
container-spawn = $(CONTAINER_RUNTIME) run --rm \
	-e IN_CONTAINER=true \
	-e CACHE_DIR=/var/cache/distfiles \
	-v $(CACHE_DIR):/var/cache/distfiles \
	-v $(OUTPUT_DIR):/output \
	-v $(BUILD_DIR):/build \
	-v $(ABUILD_DIR):/build/.abuild \
	--tmpfs /tmp/abuild:size=2g,mode=755 \
	-w /build \
	--privileged \
	$(CONTAINER_NAME) \
	make --no-print-directory $(1)

setup-dirs:
	@mkdir -p $(CACHE_DIR)/{kernel,uboot,apk,rootfs} $(OUTPUT_DIR)

setup-abuild-keys:
	@mkdir -p $(ABUILD_DIR)
	@if [ ! -f $(ABUILD_DIR)/abuild.rsa ]; then \
		echo "=== Generating APK signing keys ==="; \
		ssh-keygen -t rsa -b 4096 -m PEM -f $(ABUILD_DIR)/abuild.rsa -N "" -C "build@alpian"; \
	fi

fetch: setup-dirs
	$(call container-spawn,fetch)

uboot: setup-dirs
	$(call container-spawn,uboot)

kernel: setup-dirs
	$(call container-spawn,kernel)

apk: setup-dirs setup-abuild-keys
	$(call container-spawn,apk)
	@echo "Built APKs in output/apk/"

root: setup-dirs
	$(call container-spawn,root)

image: setup-dirs
	$(call container-spawn,image)

build-%: setup-dirs
	$(call container-spawn,build-$(filter-out build-,$(MAKECMDGOALS)))

all-boards: setup-dirs
	$(call container-spawn,all-boards)

else

fetch:
	@echo "=== Stage: Fetch remote assets ==="
	@mkdir -p $(CACHE_DIR)/{kernel,uboot,apk,rootfs}
	@for board in $(BOARDS); do \
		CACHE_DIR=$(CACHE_DIR) $(SCRIPTS_DIR)/fetch/$$board.sh; \
	done

uboot:
	@echo "=== Stage: Build U-Boot ==="
	@for board in $(BOARDS); do \
		CACHE_DIR=$(CACHE_DIR) $(SCRIPTS_DIR)/uboot/$$board.sh; \
	done

kernel:
	@echo "=== Stage: Build Linux kernel ==="
	@for board in $(BOARDS); do \
		CACHE_DIR=$(CACHE_DIR) $(SCRIPTS_DIR)/kernel/$$board.sh; \
	done

apk:
	@echo "=== Stage: Build custom APK packages ==="
	@ABUILD_KEYS=/build/.abuild APORTS_DIR=/build/apk/aports CACHE_DIR=$(CACHE_DIR) $(SCRIPTS_DIR)/apk/run.sh

root:
	@echo "=== Stage: Build root filesystem ==="
	@for board in $(BOARDS); do \
		CACHE_DIR=$(CACHE_DIR) ROOTFS_DIR=$(BUILD_DIR)/rootfs $(SCRIPTS_DIR)/root/$$board.sh; \
	done

image:
	@echo "=== Stage: Build final disk image ==="
	@for board in $(BOARDS); do \
		ROOTFS_DIR=$(BUILD_DIR)/rootfs OUTPUT_DIR=$(OUTPUT_DIR) $(SCRIPTS_DIR)/image/$$board.sh; \
	done

build-%: setup-dirs setup-abuild-keys
	@board=$(filter-out build-,$(MAKECMDGOALS)); \
	for b in $(BOARDS); do \
		if [ "$$b" = "$$board" ]; then \
			CACHE_DIR=$(CACHE_DIR) $(SCRIPTS_DIR)/fetch/$$board.sh; \
			CACHE_DIR=$(CACHE_DIR) $(SCRIPTS_DIR)/uboot/$$board.sh; \
			CACHE_DIR=$(CACHE_DIR) $(SCRIPTS_DIR)/kernel/$$board.sh; \
			ABUILD_KEYS=/build/.abuild APORTS_DIR=/build/apk/aports CACHE_DIR=$(CACHE_DIR) $(SCRIPTS_DIR)/apk/run.sh; \
			CACHE_DIR=$(CACHE_DIR) ROOTFS_DIR=$(BUILD_DIR)/rootfs $(SCRIPTS_DIR)/root/$$board.sh; \
			ROOTFS_DIR=$(BUILD_DIR)/rootfs OUTPUT_DIR=$(OUTPUT_DIR) $(SCRIPTS_DIR)/image/$$board.sh; \
			break; \
		fi; \
	done

all-boards:
	@for board in $(BOARDS); do \
		make build-$$board; \
	done

endif

clean:
	@echo "=== Cleaning build artifacts ==="
	@rm -rf $(OUTPUT_DIR)/*
	@rm -rf $(BUILD_DIR)/rootfs

distclean: clean
	@echo "=== Cleaning cache ==="
	@rm -rf $(CACHE_DIR)/*

.PHONY: help container-build container-run fetch uboot kernel apk root image build-% all-boards clean distclean
