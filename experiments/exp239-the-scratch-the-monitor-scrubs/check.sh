#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp239 quick check — scaffold for the scratch the monitor scrubs (TODO).

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=0
LIFELINE="no: no firmware of its own"
presence_check
lifeline_check

USB_IFACE="none"
USB_CARRIES="none"
USB_HOST="none"
USB_RUNS_ON="none"
usb_check

echo "SKIP  exp239: implementation pending (see README.md and docs/micro-monitor/)"
exit "$FAILED"

