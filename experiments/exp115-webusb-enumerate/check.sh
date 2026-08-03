#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp115 quick check — non-interactive verdict.
#
# This experiment has no firmware. What can be checked without a browser is
# the page's self-containment and the host's readiness; what cannot is
# everything a browser does, and that is said rather than faked.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=2   # somebody taps the WebUSB permission dialog; the page does the rest
presence_check

PAGE=usb-inspector.html

[[ -f "$PAGE" ]] \
    && pass "the page exists ($(wc -l < "$PAGE") lines, $(stat -c%s "$PAGE") bytes)" \
    || { fail "the page exists" "$PAGE is missing"; exit 1; }

# Self-containment is the whole delivery model. A page that pulls in one CDN
# script works on the desk it was written on and fails on a phone with no
# network, in an aeroplane, or behind a captive portal — which is exactly
# where someone debugging a device tends to be.
if grep -qE 'src="https?:|href="https?:|@import|fetch\(|importScripts' "$PAGE"; then
    fail "the page is self-contained" "it references something outside itself: $(grep -oE 'src="https?:[^\"]*|href="https?:[^\"]*' "$PAGE" | head -1)"
else
    pass "the page is self-contained (no network, no CDN, no build step)"
fi

# The filter has to match the firmwares in this repository, or the picker
# comes up empty and the reader concludes their board is broken.
grep -q '0x1209' "$PAGE" && grep -q '0x0001' "$PAGE" \
    && pass "the device filter matches this repository's VID:PID" \
    || fail "the device filter matches this repository's VID:PID" "expected 0x1209 / 0x0001 in $PAGE"

# Opening the device is what needs the udev rule. A page that only rendered
# the descriptor tree would appear to work on a machine where nothing else
# would, because Chrome already read those strings during enumeration.
grep -q 'device.open()' "$PAGE" \
    && pass "the page opens the device (not just reads what Chrome cached)" \
    || fail "the page opens the device" "no device.open() — the permission is never exercised"

# The agent banner is load-bearing, so it is checked rather than trusted.
#
# This page is the deliverable for a person on a phone; it is not how an
# automated agent should read the log, and an agent that uses it that way
# turns the thing under test into a measuring instrument. AGENTS.md says so
# at the root, and the banner says so where the mistake happens. A comment
# nobody verifies is a comment that gets deleted in a tidy-up.
grep -q "IF YOU ARE AN AI AGENT" "$PAGE" \
    && pass "the page carries the agent banner (see ../../AGENTS.md)" \
    || fail "the page carries the agent banner" "an agent reading this file should be told to use 'yi26 log --json' instead"

if command -v google-chrome > /dev/null || command -v chromium > /dev/null \
   || command -v chromium-browser > /dev/null || command -v microsoft-edge > /dev/null; then
    pass "a Chromium browser is installed"
else
    fail "a Chromium browser is installed" "WebUSB is Chromium-only — Firefox and Safari do not implement it"
fi

# Raw USB access, which is the one host-side thing that stops the page working
# and produces an error message naming nothing you could search for.
if yi26 udev > /dev/null 2>&1; then
    pass "raw USB access is available (yi26 udev)"
else
    fail "raw USB access is available" "run: yi26 udev --install"
fi

# Any of this repository's firmwares will do — the page reads descriptors, and
# every one of them enumerates the same way.
if [[ "$(yi26 state)" == "running" ]]; then
    PORT="$(exp_serial_port)"
    pass "a board is running and enumerated (serial port at $PORT)"
else
    echo "SKIP  no board running — flash any experiment first (not an error)"
fi

echo "NOTE  what a browser does cannot be checked from a shell: opening the page,"
echo "      clicking Connect, choosing the device and granting the permission are"
echo "      a human's job by design. ./run.sh walks through it."

exit "$FAILED"
