#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp241 quick check — scaffold (TODO). See README.md and ../../docs/zkp-rv32/single-board-experiment-plan-zh-tw.md.

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

echo "SKIP  exp241: implementation pending (see README.md)"
exit "$FAILED"
