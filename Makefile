SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := all
.DELETE_ON_ERROR:

REPO_ROOT := $(abspath .)
SCRIPTS_DIR := $(REPO_ROOT)/scripts
ASSETS_DIR := $(REPO_ROOT)/assets/reference
STAMPS_DIR := $(REPO_ROOT)/build/.stamps

DEFAULT_CUSTOM_APK_KEYS_DIR := assets/reference/alpine/custom-keys
DEFAULT_ROOT_AUTHORIZED_KEYS_FILE := assets/reference/alpine/root_authorized_keys

CUSTOM_APK_KEYS_DIR_FOR_HASH := $(if $(filter undefined,$(origin CUSTOM_APK_KEYS_DIR)),$(DEFAULT_CUSTOM_APK_KEYS_DIR),$(CUSTOM_APK_KEYS_DIR))
ROOT_AUTHORIZED_KEYS_FILE_FOR_HASH := $(if $(filter undefined,$(origin ROOT_AUTHORIZED_KEYS_FILE)),$(DEFAULT_ROOT_AUTHORIZED_KEYS_FILE),$(ROOT_AUTHORIZED_KEYS_FILE))

CUSTOM_APK_KEYS_DIR_ENV := $(if $(filter undefined,$(origin CUSTOM_APK_KEYS_DIR)),,CUSTOM_APK_KEYS_DIR=$(CUSTOM_APK_KEYS_DIR))
ROOT_AUTHORIZED_KEYS_FILE_ENV := $(if $(filter undefined,$(origin ROOT_AUTHORIZED_KEYS_FILE)),,ROOT_AUTHORIZED_KEYS_FILE=$(ROOT_AUTHORIZED_KEYS_FILE))
APK_KEYS_EXPORT_DIR_ENV := $(if $(filter undefined,$(origin APK_KEYS_EXPORT_DIR)),,APK_KEYS_EXPORT_DIR=$(APK_KEYS_EXPORT_DIR))

MAIN_IMAGE ?= $(REPO_ROOT)/build/e54c-alpine-custom.img
USB_UPDATER_IMAGE ?= $(REPO_ROOT)/build/e54c-alpine-usb-updater.img

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

UBOOT_ASSETS_DIR ?= $(ASSETS_DIR)/u-boot
UBOOT_REQUIRED_ASSETS := \
  $(UBOOT_ASSETS_DIR)/idbloader.img \
  $(UBOOT_ASSETS_DIR)/u-boot.itb \
  $(UBOOT_ASSETS_DIR)/rkboot.bin

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
	@echo "  make all                Build main and USB updater images (default)."
	@echo "  make apk-repo           Build local custom APK repository."
	@echo "  make uboot-assets       Fetch reference U-Boot artifacts."
	@echo "  make kernel             Build kernel artifacts."
	@echo "  make rootfs             Prepare Alpine rootfs."
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
	    scripts/build-kernel-e54c.sh \
	    scripts/fetch-radxa-kernel.sh \
	    scripts/check-tooling.sh \
	    assets/reference/radxa/custom-kernel.fragment; \
	  if [ -d assets/reference/radxa ]; then \
	    find assets/reference/radxa -maxdepth 1 -type f -name '*defconfig*' -print0; \
	  fi; \
	} | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $$1}' >"$@.tmp"
	@if [ ! -f "$@" ] || ! cmp -s "$@.tmp" "$@"; then mv "$@.tmp" "$@"; else rm -f "$@.tmp"; fi

$(ROOTFS_INPUTS_HASH): FORCE | $(STAMPS_DIR)
	@{ \
	  printf '%s\0' \
	    scripts/prepare-alpine-rootfs.sh \
	    scripts/check-tooling.sh \
	    assets/reference/alpine/packages.txt \
	    assets/reference/alpine/custom-packages.txt \
	    assets/reference/alpine/custom-repositories.txt \
	    assets/reference/alpine/motd-main \
	    assets/reference/alpine/motd-updater; \
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
	    scripts/fetch-uboot-reference-assets.sh \
	    scripts/check-tooling.sh; \
	} | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $$1}' >"$@.tmp"
	@if [ ! -f "$@" ] || ! cmp -s "$@.tmp" "$@"; then mv "$@.tmp" "$@"; else rm -f "$@.tmp"; fi

$(MAIN_IMAGE_INPUTS_HASH): FORCE | $(STAMPS_DIR)
	@{ \
	  printf '%s\0' \
	    scripts/assemble-e54c-image.sh \
	    scripts/check-tooling.sh; \
	} | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $$1}' >"$@.tmp"
	@if [ ! -f "$@" ] || ! cmp -s "$@.tmp" "$@"; then mv "$@.tmp" "$@"; else rm -f "$@.tmp"; fi

$(USB_IMAGE_INPUTS_HASH): FORCE | $(STAMPS_DIR)
	@{ \
	  printf '%s\0' \
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
	@test -f "$(UBOOT_ASSETS_DIR)/rkboot.bin"
	touch "$@"

$(KERNEL_STAMP): $(KERNEL_INPUTS_HASH) | $(STAMPS_DIR)
	"$(SCRIPTS_DIR)/build-kernel-e54c.sh"
	touch "$@"

$(ROOTFS_STAMP): $(ROOTFS_INPUTS_HASH) $(APK_REPO_STAMP) | $(STAMPS_DIR)
	$(ROOT_AUTHORIZED_KEYS_FILE_ENV) $(CUSTOM_APK_KEYS_DIR_ENV) $(SCRIPTS_DIR)/prepare-alpine-rootfs.sh
	touch "$@"

$(MAIN_IMAGE_STAMP): $(MAIN_IMAGE_INPUTS_HASH) $(UBOOT_ASSETS_STAMP) $(KERNEL_STAMP) $(ROOTFS_STAMP) | $(STAMPS_DIR)
	"$(SCRIPTS_DIR)/assemble-e54c-image.sh"
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
		"$(REPO_ROOT)/build/e54c-alpine-custom.img" \
		"$(REPO_ROOT)/build/e54c-alpine-usb-updater.img"
