#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp155 has no source. This script exists because every experiment directory
# has a check.sh and because the declarations below are checked against the
# index — so a record of a lost experiment is registered the same way a real
# one is, rather than being a directory the guards do not know about.
#
# It cannot fail on anything the firmware does, because nothing here can build
# it. What it does assert is that this directory is still what it says it is.
#
#   ./check.sh        exit 0 = the record is intact

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=3   # a person with a phone, tethering turned on — exp153's cost, and nothing here can lower it
presence_check

# Read off the board's own log on 2026-08-18, not off source, because there is
# no source. The README says which line each token came from.
USB_IFACE="cdc+ncm+msc"
USB_CARRIES="log+frames+files"
USB_HOST="cdc_acm+cdc_ncm+usb-storage"
USB_RUNS_ON="own"
usb_check

if [[ -d src ]]; then
    fail "this experiment has no source" "src/ exists — if it has been recovered, this file needs rewriting"
else
    pass "no source, as recorded (the binary on the board is the only copy)"
fi

grep -q 'session_014mFHSDdRKeQ2fbmxbx99yN' README.md \
    && pass "the record still names the session it came from" \
    || fail "the record still names the session it came from" "README.md lost the session id"

exit "$FAILED"
