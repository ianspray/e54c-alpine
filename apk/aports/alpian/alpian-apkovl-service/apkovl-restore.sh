#!/bin/sh
# SPDX-License-Identifier: MIT
# apkovl-restore - Restore configuration from apkovl tarball
# This runs during boot to apply persisted configuration

set -e

APKOVL_PATH="${APKOVL_PATH:-/media/config/alpian.apkovl.tar.gz}"
APKOVL_TMP="${APKOVL_TMP:-/tmp/apkovl-extract}"
CONFIG_LABEL="config"
CONFIG_PART_DEV=""

log() {
	echo "[apkovl-restore] $*"
}

find_config_part() {
	if [ -f "$APKOVL_PATH" ]; then
		return 0
	fi

	log "Waiting for config partition..."
	waited=0
	while [ ! -f "$APKOVL_PATH" ] && [ "$waited" -lt 5 ]; do
		sleep 1
		waited=$((waited + 1))
	done

	if [ ! -f "$APKOVL_PATH" ]; then
		if [ -d /media/config ]; then
			hostname_apkovl="$(ls /media/config/*.apkovl.tar.gz 2>/dev/null | head -n1 || true)"
			if [ -n "$hostname_apkovl" ] && [ -f "$hostname_apkovl" ]; then
				log "Using hostname-based apkovl: $hostname_apkovl"
				APKOVL_PATH="$hostname_apkovl"
				return 0
			fi
		fi
		log "Config partition not found, skipping apkovl restore"
		return 0
	fi
}

restore_file() {
	local src="$1"
	local dst="$2"
	local dir

	[ -f "$src" ] || return 1
	dir="$(dirname "$dst")"
	[ -d "$dir" ] || mkdir -p "$dir"
	cp -a "$src" "$dst"
}

log "Starting apkovl restore"
find_config_part

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
