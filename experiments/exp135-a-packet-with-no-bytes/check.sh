#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp135 quick check — non-interactive verdict.
#
# There is no firmware here. exp128 is the instrument: it reassembles by hand
# and says what it received, so every question this experiment asks is answered
# by a line in its log.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed
#
# It takes the CDC interfaces from the kernel while it runs and gives them back
# on the way out, including if it fails.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=2   # the browser row needs a person; everything below needs nobody
LIFELINE="no: no firmware of its own"
presence_check
lifeline_check

USB_IFACE="cdc"
USB_CARRIES="log+commands"
USB_HOST="libusb+webusb"
USB_RUNS_ON="exp128"
usb_check

# `yi26 send --end` has no shell equivalent, which is the finding rather than a
# gap. A tty cannot describe a packet with no bytes in it.
if command -v cargo > /dev/null; then
    pass "toolchain present (cargo)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

grep -q 'pub fn cdc_raw_send' ../../tools/yi26/src/board.rs \
    && pass "yi26 can claim the CDC data interface and submit transfers itself" \
    || fail "yi26 can claim the CDC data interface" "board.rs has no cdc_raw_send"

grep -q "zlp" ../../tools/pages/console.html \
    && pass "console.html can end a message too (the browser half of the census)" \
    || fail "console.html can end a message" "the page has no zero-length path"

# The rule, in both implementations: a terminator is appended only when the
# payload is an exact multiple of the packet size.
grep -q 'payload.len() % packet_size == 0' ../../tools/yi26/src/board.rs \
    && pass "yi26 appends the terminator only when the length calls for it" \
    || fail "yi26 appends the terminator only when the length calls for it" "the rule moved"
grep -q 'bytes.length % packetSize === 0' ../../tools/pages/console.html \
    && pass "console.html uses the same rule, read off the descriptors" \
    || fail "console.html uses the same rule" "the page hard-codes or skips the packet size"

if ! exp_running 128 && ! yi26 state 2>/dev/null | grep -q detached; then
    echo "SKIP  board is not running exp128 — flash it from ../exp128-reassemble-by-hand (not an error)"
    exit "$FAILED"
fi

# From here the kernel must not hold the interface. Give it back whatever
# happens, including on a failure exit: leaving somebody without /dev/ttyACM0
# and no message about it is the worst thing this script could do.
yi26 detach > /dev/null 2>&1
trap 'yi26 attach > /dev/null 2>&1' EXIT
pass "the CDC interfaces are detached (an interface has exactly one owner)"

# Clears anything a previous case left buffered. One byte is a short packet, so
# it completes on arrival and takes the held bytes with it — which is exactly
# the silent-merge failure being used here on purpose, as a reset.
flush() { yi26 send --raw 'z' --seconds 1 > /dev/null 2>&1; }

bytes() { printf 'X%.0s' $(seq 1 "$1"); }

flush
OUT="$(yi26 send --raw "$(bytes 63)" --seconds 2 2>&1)"
echo "$OUT" | grep -q 'msg #[0-9]*: 63 bytes' \
    && pass "63 bytes completes on its own — the last packet is already short" \
    || fail "63 bytes completes on its own" "$(echo "$OUT" | tail -2 | tr '\n' ' ')"

flush
OUT="$(yi26 send --raw "$(bytes 64)" --seconds 2 2>&1)"
if echo "$OUT" | grep -q '64 held' && ! echo "$OUT" | grep -q 'msg #'; then
    pass "64 bytes does NOT complete — nothing follows it that means 'over'"
else
    fail "64 bytes does not complete" "$(echo "$OUT" | tail -2 | tr '\n' ' ')"
fi

flush
OUT="$(yi26 send --end "$(bytes 64)" --seconds 2 2>&1)"
echo "$OUT" | grep -q 'ended by a zero-length packet' \
    && pass "64 bytes WITH --end completes, ended by a zero-length packet" \
    || fail "64 bytes with --end completes" "$(echo "$OUT" | tail -2 | tr '\n' ' ')"

# The row two independent host libraries on this machine disagree about.
flush
OUT="$(yi26 send --raw --seconds 3 2>&1)"
echo "$OUT" | grep -q 'zero-length packet' \
    && pass "a lone zero-length transfer reaches the device (nusb submits it)" \
    || fail "a lone zero-length transfer reaches the device" \
            "the firmware saw nothing — see the README on why this row is contested"

echo "NOTE  the browser row is not checked here. Whether Chrome puts the same"
echo "      packet on the wire needs a person, a page and a permission dialog."

exit "$FAILED"
