#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp117 quick check — non-interactive verdict.
#
# This experiment has no firmware. What can be checked without a browser is
# the page's self-containment, the claims it makes, and the host's readiness.
# Pressing the button is a human's job by design, and that is said rather than
# faked.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PAGE=reboot.html

[[ -f "$PAGE" ]] \
    && pass "the page exists ($(wc -l < "$PAGE") lines, $(stat -c%s "$PAGE") bytes)" \
    || { fail "the page exists" "$PAGE is missing"; exit 1; }

if grep -qE 'src="https?:|href="https?:|@import|fetch\(|importScripts' "$PAGE"; then
    fail "the page is self-contained" "it references something outside itself"
else
    pass "the page is self-contained (no network, no CDN, no build step)"
fi

grep -q "IF YOU ARE AN AI AGENT" "$PAGE" \
    && pass "the page carries the agent banner (see ../../AGENTS.md)" \
    || fail "the page carries the agent banner" "an agent should be told to use 'yi26 bootsel' instead"

# The whole experiment is one number. If it stops being 1200 the page becomes
# an elaborate way to set a baud rate.
grep -q "MAGIC_BAUD = 1200" "$PAGE" \
    && pass "the page sends 1200 baud, which is the entire experiment" \
    || fail "the page sends 1200 baud" "MAGIC_BAUD is not 1200"

# One request. The two-step dance a serial API needs does not apply here, and
# a page that opened and closed anything would be teaching the wrong thing.
[[ "$(grep -c 'controlTransferOut' "$PAGE")" == "1" ]] \
    && pass "exactly one control transfer, not the serial API's two steps" \
    || fail "exactly one control transfer" "found $(grep -c 'controlTransferOut' "$PAGE")"

# The disconnect listener is the only unambiguous evidence the page has. A
# version that reported the transfer's own outcome would be right about half
# the time.
grep -q "addEventListener('disconnect'" "$PAGE" \
    && pass "success is judged by the disconnect event, not by the transfer" \
    || fail "success is judged by the disconnect event" "no disconnect listener"

if command -v node > /dev/null; then
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    # The `.js` matters: `node --check` decides how to parse a file from its
    # extension, and a bare mktemp name gets ERR_UNKNOWN_FILE_EXTENSION. The
    # first version of this check used one and reported FAIL against a page
    # that was perfectly fine — a check that fails for its own reasons is
    # worse than no check, which is a lesson this repository keeps re-learning.
    sed -n '/^<script>/,/^<\/script>/p' "$PAGE" | sed '1d;$d' > "$WORK/page.js"
    # node cannot run this — it is all DOM and WebUSB — but it can refuse a
    # syntax error, and a syntax error here leaves a page that loads, renders
    # and does nothing, with the reason in a console nobody opened.
    if node --check "$WORK/page.js" 2>"$WORK/err"; then
        pass "the page's script parses"
    else
        fail "the page's script parses" "$(head -3 "$WORK/err" | tr '\n' ' ')"
    fi
else
    echo "SKIP  node is not installed, so the page's script cannot be syntax-checked"
fi

if command -v google-chrome > /dev/null || command -v chromium > /dev/null \
   || command -v chromium-browser > /dev/null || command -v microsoft-edge > /dev/null; then
    pass "a Chromium browser is installed"
else
    fail "a Chromium browser is installed" "WebUSB is Chromium-only"
fi

if yi26 udev > /dev/null 2>&1; then
    pass "raw USB access is available (yi26 udev)"
else
    fail "raw USB access is available" "run: yi26 udev --install"
fi

# Which host state we are in decides what "ready" means. All of these are
# legitimate and none of them is a failure of this experiment.
case "$(yi26 state 2>/dev/null)" in
    detached) pass "the interface is detached — a browser can claim it" ;;
    running)  echo "SKIP  the kernel still owns the interface — run 'yi26 detach' before connecting" ;;
    bootsel)  echo "SKIP  the board is already in BOOTSEL — flash something before trying again" ;;
    *)        echo "SKIP  no board attached (not an error)" ;;
esac

echo "NOTE  pressing the button is a human's job: the WebUSB picker is a native"
echo "      dialog behind a required user gesture, and no tool here can click it."
echo "      The README's Expected output is a real capture, checked against"
echo "      'yi26 state' and lsusb at the same moment."

exit "$FAILED"
