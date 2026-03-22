SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := all
.DELETE_ON_ERROR:

REPO_ROOT := $(abspath .)
SCRIPTS_DIR := $(REPO_ROOT)/scripts
ASSETS_DIR := $(REPO_ROOT)/assets/reference
STAMPS_DIR := $(REPO_ROOT)/build/.stamps
BOARD ?= e54c
export BOARD
BOARD_DIR := boards/$(BOARD)

DEFAULT_CUSTOM_APK_KEYS_DIR := assets/reference/alpine/custom-keys
DEFAULT_ROOT_AUTHORIZED_KEYS_FILE := assets/reference/alpine/root_authorized_keys

CUSTOM_APK_KEYS_DIR_FOR_HASH := $(if $(filter undefined,$(origin CUSTOM_APK_KEYS_DIR)),$(DEFAULT_CUSTOM_APK_KEYS_DIR),$(CUSTOM_APK_KEYS_DIR))
ROOT_AUTHORIZED_KEYS_FILE_FOR_HASH := $(if $(filter undefined,$(origin ROOT_AUTHORIZED_KEYS_FILE)),$(DEFAULT_ROOT_AUTHORIZED_KEYS_FILE),$(ROOT_AUTHORIZED_KEYS_FILE))

CUSTOM_APK_KEYS_DIR_ENV := $(if $(filter undefined,$(origin CUSTOM_APK_KEYS_DIR)),,CUSTOM_APK_KEYS_DIR=$(CUSTOM_APK_KEYS_DIR))
ROOT_AUTHORIZED_KEYS_FILE_ENV := $(if $(filter undefined,$(origin ROOT_AUTHORIZED_KEYS_FILE)),,ROOT_AUTHORIZED_KEYS_FILE=$(ROOT_AUTHORIZED_KEYS_FILE))
APK_KEYS_EXPORT_DIR_ENV := $(if $(filter undefined,$(origin APK_KEYS_EXPORT_DIR)),,APK_KEYS_EXPORT_DIR=$(APK_KEYS_EXPORT_DIR))

MAIN_IMAGE ?= $(REPO_ROOT)/build/$(BOARD)-alpian-custom.img
USB_UPDATER_IMAGE ?= $(REPO_ROOT)/build/$(BOARD)-alpian-usb-updater.img

APK_INPUTS_HASH := $(STAMPS_DIR)/apk-inputs.sha256
KERNEL_INPUTS_HASH := $(STAMPS_DIR)/kernel-inputs.sha256
ROOTFS_INPUTS_HASH := $(STAMPS_DIR)/rootfs-inputs.sha256
UBOOT_INPUTS_HASH := $(STAMPS_DIR)/uboot-inputs.sha256
MAIN_IMAGE_INPUTS_HASH := $(STAMPS_DIR)/main-image-inputs.sha256
USB_IMAGE_INPUTS_HASH := $(STAMPS_DIR)/usb-image-inputs.sha256

APK_REPO_STAMP := $(STAMPS_DIR)/apk-repo.stamp
UBOOT_ASSETS_STAMP := $(STAMPS_DIR)/uboot-assets.stamp
KERNEL_STAMP := $(STAMPS_DIR)/kernel.stamp
ROOTFS_STAMP := $(STAMPS_DIR)/rootfs.stamp
MAIN_IMAGE_STAMP := $(STAMPS_DIR)/main-image.stamp
USB_IMAGE_STAMP := $(STAMPS_DIR)/usb-image.stamp

UBOOT_ASSETS_DIR ?= $(REPO_ROOT)/boards/$(BOARD)/u-boot
UBOOT_REQUIRED_ASSETS := \
  $(UBOOT_ASSETS_DIR)/idbloader.img \
  $(UBOOT_ASSETS_DIR)/u-boot.itb

.PHONY: all images apk-repo uboot-assets kernel rootfs main-image usb-updater-image \
	help clean clean-stamps distclean FORCE

all: images

images: main-image usb-updater-image

apk-repo: $(APK_REPO_STAMP)

uboot-assets: $(UBOOT_ASSETS_STAMP)

kernel: $(KERNEL_STAMP)

rootfs: $(ROOTFS_STAMP)

main-image: $(MAIN_IMAGE_STAMP)

usb-updater-image: $(USB_IMAGE_STAMP)

help:
	@echo "Targets:"
	@echo "  (set BOARD=<name>, default: e54c; options: e54c, e52c, e25, rock5b, rock3b, r3s, rpi4)"
	@echo "  make all                Build main and USB updater images (default)."
	@echo "  make apk-repo           Build local custom APK repository."
	@echo "  make uboot-assets       Fetch reference U-Boot artifacts."
	@echo "  make kernel             Build kernel artifacts."
	@echo "  make rootfs             Prepare the Alpian rootfs."
	@echo "  make main-image         Assemble main image."
	@echo "  make usb-updater-image  Build USB updater image."
	@echo "  make clean-stamps       Remove dependency stamps only."
	@echo "  make clean              Alias of clean-stamps."
	@echo "  make distclean          Remove generated build artifacts and stamps."

$(STAMPS_DIR):
	mkdir -p "$@"

FORCE:

$(APK_INPUTS_HASH): FORCE | $(STAMPS_DIR)
	@{ \
	  find apk/aports -type f -print0; \
	  printf '%s\0' \
	    scripts/build-apk-repo.sh \
	    scripts/check-tooling.sh \
	    scripts/lib/cache.sh \
	    containers/apk-builder/Containerfile \
	    assets/reference/alpine/custom-packages.txt \
	    assets/reference/alpine/custom-repositories.txt; \
	  if [ -d "$(CUSTOM_APK_KEYS_DIR_FOR_HASH)" ]; then \
	    find "$(CUSTOM_APK_KEYS_DIR_FOR_HASH)" -type f -print0; \
	  fi; \
	} | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $$1}' >"$@.tmp"
	@if [ ! -f "$@" ] || ! cmp -s "$@.tmp" "$@"; then mv "$@.tmp" "$@"; else rm -f "$@.tmp"; fi

$(KERNEL_INPUTS_HASH): FORCE | $(STAMPS_DIR)
	@{ \
	  printf '%s\0' \
	    $(BOARD_DIR)/board.env \
	    scripts/build-kernel.sh \
	    scripts/fetch-radxa-kernel.sh \
	    scripts/check-tooling.sh \
	    scripts/lib/cache.sh; \
	  if [ -f "$(BOARD_DIR)/kernel/custom-kernel.fragment" ]; then \
	    printf '%s\0' "$(BOARD_DIR)/kernel/custom-kernel.fragment"; \
	  fi; \
	  if [ -d "$(BOARD_DIR)/kernel/patches" ]; then \
	    find "$(BOARD_DIR)/kernel/patches" -type f -name '*.patch' -print0; \
	  fi; \
	  if [ -d assets/reference/radxa ]; then \
	    find assets/reference/radxa -maxdepth 1 -type f -name '*defconfig*' -print0; \
	  fi; \
	} | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $$1}' >"$@.tmp"
	@if [ ! -f "$@" ] || ! cmp -s "$@.tmp" "$@"; then mv "$@.tmp" "$@"; else rm -f "$@.tmp"; fi

$(ROOTFS_INPUTS_HASH): FORCE | $(STAMPS_DIR)
	@{ \
	  printf '%s\0' \
	    $(BOARD_DIR)/board.env \
	    scripts/prepare-alpian-rootfs.sh \
	    scripts/check-tooling.sh \
	    scripts/lib/cache.sh \
	    assets/reference/alpine/custom-repositories.txt \
	    assets/reference/alpine/motd-main \
	    assets/reference/alpine/motd-updater; \
	  if [ -f "boards/alpian/alpine/packages.txt" ]; then \
	    printf '%s\0' "boards/alpian/alpine/packages.txt"; \
	  elif [ -f "assets/reference/alpine/packages.txt" ]; then \
	    printf '%s\0' "assets/reference/alpine/packages.txt"; \
	  fi; \
	  if [ -f "boards/alpian/alpine/custom-packages.txt" ]; then \
	    printf '%s\0' "boards/alpian/alpine/custom-packages.txt"; \
	  elif [ -f "assets/reference/alpine/custom-packages.txt" ]; then \
	    printf '%s\0' "assets/reference/alpine/custom-packages.txt"; \
	  fi; \
	  if [ -f "$(BOARD_DIR)/alpine/interfaces" ]; then \
	    printf '%s\0' "$(BOARD_DIR)/alpine/interfaces"; \
	  fi; \
	  if [ -f "$(BOARD_DIR)/alpine/modules" ]; then \
	    printf '%s\0' "$(BOARD_DIR)/alpine/modules"; \
	  fi; \
	  if [ -f "$(BOARD_DIR)/alpine/packages.txt" ]; then \
	    printf '%s\0' "$(BOARD_DIR)/alpine/packages.txt"; \
	  fi; \
	  if [ -f "$(BOARD_DIR)/alpine/custom-packages.txt" ]; then \
	    printf '%s\0' "$(BOARD_DIR)/alpine/custom-packages.txt"; \
	  fi; \
	  if [ -n "$(ROOT_AUTHORIZED_KEYS_FILE_FOR_HASH)" ] && [ -f "$(ROOT_AUTHORIZED_KEYS_FILE_FOR_HASH)" ]; then \
	    printf '%s\0' "$(ROOT_AUTHORIZED_KEYS_FILE_FOR_HASH)"; \
	  fi; \
	  if [ -d "$(CUSTOM_APK_KEYS_DIR_FOR_HASH)" ]; then \
	    find "$(CUSTOM_APK_KEYS_DIR_FOR_HASH)" -type f -print0; \
	  fi; \
	} | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $$1}' >"$@.tmp"
	@if [ ! -f "$@" ] || ! cmp -s "$@.tmp" "$@"; then mv "$@.tmp" "$@"; else rm -f "$@.tmp"; fi

$(UBOOT_INPUTS_HASH): FORCE | $(STAMPS_DIR)
	@{ \
	  printf '%s\0' \
	    $(BOARD_DIR)/board.env \
	    scripts/fetch-uboot-reference-assets.sh \
	    scripts/check-tooling.sh \
	    scripts/lib/cache.sh; \
	  if [ -f "$(BOARD_DIR)/u-boot-fetch.env" ]; then \
	    printf '%s\0' "$(BOARD_DIR)/u-boot-fetch.env"; \
	  fi; \
	} | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $$1}' >"$@.tmp"
	@if [ ! -f "$@" ] || ! cmp -s "$@.tmp" "$@"; then mv "$@.tmp" "$@"; else rm -f "$@.tmp"; fi

$(MAIN_IMAGE_INPUTS_HASH): FORCE | $(STAMPS_DIR)
	@{ \
	  printf '%s\0' \
	    $(BOARD_DIR)/board.env \
	    scripts/assemble-image.sh \
	    scripts/check-tooling.sh; \
	} | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $$1}' >"$@.tmp"
	@if [ ! -f "$@" ] || ! cmp -s "$@.tmp" "$@"; then mv "$@.tmp" "$@"; else rm -f "$@.tmp"; fi

$(USB_IMAGE_INPUTS_HASH): FORCE | $(STAMPS_DIR)
	@{ \
	  printf '%s\0' \
	    $(BOARD_DIR)/board.env \
	    scripts/build-usb-updater-image.sh \
	    scripts/check-tooling.sh; \
	} | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $$1}' >"$@.tmp"
	@if [ ! -f "$@" ] || ! cmp -s "$@.tmp" "$@"; then mv "$@.tmp" "$@"; else rm -f "$@.tmp"; fi

$(APK_REPO_STAMP): $(APK_INPUTS_HASH) | $(STAMPS_DIR)
	$(APK_KEYS_EXPORT_DIR_ENV) $(SCRIPTS_DIR)/build-apk-repo.sh
	touch "$@"

$(UBOOT_ASSETS_STAMP): $(UBOOT_INPUTS_HASH) | $(STAMPS_DIR)
	"$(SCRIPTS_DIR)/fetch-uboot-reference-assets.sh"
	@test -f "$(UBOOT_ASSETS_DIR)/idbloader.img"
	@test -f "$(UBOOT_ASSETS_DIR)/u-boot.itb"
	touch "$@"

$(KERNEL_STAMP): $(KERNEL_INPUTS_HASH) | $(STAMPS_DIR)
	"$(SCRIPTS_DIR)/build-kernel.sh"
	touch "$@"

$(REPO_ROOT)/build/.build_info: | $(STAMPS_DIR)
	@mkdir -p $(REPO_ROOT)/build && \
	n=$$(cat $(REPO_ROOT)/build/.build_number 2>/dev/null || echo 0) && \
	n=$$((n + 1)) && \
	echo "$$n" > $(REPO_ROOT)/build/.build_number && \
	echo "ALPIAN_BUILD_INFO=build #$$n $$(date +'%Y-%m-%d %H:%M:%S')" > "$@"

$(ROOTFS_STAMP): $(ROOTFS_INPUTS_HASH) $(APK_REPO_STAMP) $(REPO_ROOT)/build/.build_info | $(STAMPS_DIR)
	@build_info=$$(cat $(REPO_ROOT)/build/.build_info 2>/dev/null); \
	build_val=$$(echo "$$build_info" | sed 's/ALPIAN_BUILD_INFO=//'); \
	$(ROOT_AUTHORIZED_KEYS_FILE_ENV) $(CUSTOM_APK_KEYS_DIR_ENV) \
	ALPIAN_BUILD_INFO="$$build_val" \
	"$(SCRIPTS_DIR)/prepare-alpian-rootfs.sh"
	touch "$@"

$(MAIN_IMAGE_STAMP): $(MAIN_IMAGE_INPUTS_HASH) $(UBOOT_ASSETS_STAMP) $(KERNEL_STAMP) $(ROOTFS_STAMP) | $(STAMPS_DIR)
	"$(SCRIPTS_DIR)/assemble-image.sh"
	@test -f "$(MAIN_IMAGE)"
	touch "$@"

$(USB_IMAGE_STAMP): $(USB_IMAGE_INPUTS_HASH) $(APK_REPO_STAMP) $(MAIN_IMAGE_STAMP) | $(STAMPS_DIR)
	"$(SCRIPTS_DIR)/build-usb-updater-image.sh"
	@test -f "$(USB_UPDATER_IMAGE)"
	touch "$@"

clean-stamps:
	rm -rf "$(STAMPS_DIR)"

clean: clean-stamps

distclean: clean-stamps
	rm -rf "$(REPO_ROOT)/build/alpine-rootfs" \
		"$(REPO_ROOT)/build/alpine-rootfs.tar" \
		"$(REPO_ROOT)/build/apk-keys" \
		"$(REPO_ROOT)/build/apk-repo" \
		"$(REPO_ROOT)/build/kernel-artifacts" \
		"$(REPO_ROOT)/build/kernel-out" \
		"$(REPO_ROOT)/build/usb-updater" \
		"$(REPO_ROOT)/build/$(BOARD)-alpian-custom.img" \
		"$(REPO_ROOT)/build/$(BOARD)-alpian-usb-updater.img"
