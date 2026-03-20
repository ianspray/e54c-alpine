#!/bin/sh
# SPDX-License-Identifier: MIT
# apkovl-restore - Restore configuration from apkovl tarball
# This runs during boot to apply persisted configuration

set -e

APKOVL_PATH="${APKOVL_PATH:-/media/config/alpian.apkovl.tar.gz}"
APKOVL_TMP="${APKOVL_TMP:-/tmp/apkovl-extract}"
CONFIG_PART="${CONFIG_PART:-/dev/disk/by-label/config}"

restore_file() {
	local src="$1"
	local dst="$2"
	local dir

	[ -f "$src" ] || return 1
	dir="$(dirname "$dst")"
	[ -d "$dir" ] || mkdir -p "$dir"
	cp -a "$src" "$dst"
}

log() {
	echo "[apkovl-restore] $*"
}

log "Starting apkovl restore"

# Wait for config partition to be available
if [ ! -e "$CONFIG_PART" ]; then
	log "Waiting for config partition..."
	waited=0
	while [ ! -e "$CONFIG_PART" ] && [ "$waited" -lt 60 ]; do
		sleep 1
		waited=$((waited + 1))
	done
fi

if [ ! -e "$CONFIG_PART" ]; then
	log "Config partition not found, skipping apkovl restore"
	exit 0
fi

if [ ! -f "$APKOVL_PATH" ]; then
	log "No apkovl found at $APKOVL_PATH"
	exit 0
fi

# Extract apkovl to temp location
rm -rf "$APKOVL_TMP"
mkdir -p "$APKOVL_TMP"

log "Extracting apkovl from $APKOVL_PATH"
if ! tar -xzf "$APKOVL_PATH" -C "$APKOVL_TMP"; then
	log "Failed to extract apkovl"
	rm -rf "$APKOVL_TMP"
	exit 1
fi

# Restore hostname
if [ -f "$APKOVL_TMP/etc/hostname" ]; then
	NEW_HOSTNAME="$(cat "$APKOVL_TMP/etc/hostname")"
	CURRENT_HOSTNAME="$(cat /etc/hostname 2>/dev/null || hostname)"
	if [ "$NEW_HOSTNAME" != "$CURRENT_HOSTNAME" ]; then
		log "Updating hostname: $CURRENT_HOSTNAME -> $NEW_HOSTNAME"
		echo "$NEW_HOSTNAME" >/etc/hostname
		hostname "$NEW_HOSTNAME"
		rc-service hostname restart 2>/dev/null || true
		rc-service avahi-daemon restart 2>/dev/null || true
	else
		log "Hostname unchanged: $CURRENT_HOSTNAME"
	fi
fi

# Restore SSH host keys
for key_type in ed25519 ecdsa rsa; do
	key_file="etc/ssh/ssh_host_${key_type}_key"
	pub_file="etc/ssh/ssh_host_${key_type}_key.pub"
	if [ -f "$APKOVL_TMP/$key_file" ] && [ -f "$APKOVL_TMP/$pub_file" ]; then
		if [ ! -f "/$key_file" ] || ! cmp -s "$APKOVL_TMP/$key_file" "/$key_file" 2>/dev/null; then
			log "Restoring SSH $key_type host key"
			restore_file "$APKOVL_TMP/$key_file" "/$key_file"
			restore_file "$APKOVL_TMP/$pub_file" "/$pub_file"
			chmod 0600 "/$key_file" 2>/dev/null || true
			chmod 0644 "/$pub_file" 2>/dev/null || true
		fi
	fi
done

# Restart SSH if keys were restored
if rc-service sshd status >/dev/null 2>&1; then
	rc-service sshd restart 2>/dev/null || true
fi

# Clean up
rm -rf "$APKOVL_TMP"

log "Apkovl restore complete"
