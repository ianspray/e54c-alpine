#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

# shellcheck disable=SC1091
[ -f /etc/conf.d/e54c-sample-hook ] && . /etc/conf.d/e54c-sample-hook

msg="${sample_message:-e54c-openrc-sample hook executed}"

echo "$msg" >/dev/console 2>/dev/null || true
logger -t e54c-openrc-sample "$msg" 2>/dev/null || true
touch /run/e54c-openrc-sample.ran
