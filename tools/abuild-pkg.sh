#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Ian Spray
set -e

if [ -z "${1}" ]; then
  echo "ERROR: No package directory specified: '${@}'"
  exit 1
fi

cd "${1}"
HOME="/home/builder" PACKAGER_PRIVKEY="/home/builder/.abuild/abuild.rsa" abuild checksum 2>/dev/null || true
HOME="/home/builder" PACKAGER_PRIVKEY="/home/builder/.abuild/abuild.rsa" abuild -r
