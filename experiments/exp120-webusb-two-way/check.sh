#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp120 quick check — non-interactive verdict.
#
# This experiment has no firmware of its own; it talks to exp118's. What can
# be checked without a browser is the page, the claims it makes, and whether
# the board in front of you is one it can say anything to.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PAGE=two-way.html

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
    || fail "the page carries the agent banner" "an agent should be told to use 'yi26 send' instead"

# The one new call. Everything else on this page is exp116.
grep -q "transferOut(epOut" "$PAGE" \
    && pass "the page writes to the OUT endpoint, which is the experiment" \
    || fail "the page writes to the OUT endpoint" "no transferOut to the bulk OUT endpoint"

# Both endpoints discovered, not remembered. exp121 adds a function to this
# device and moves every number a hard-coded page would rely on.
grep -q "direction === 'out'" "$PAGE" && grep -q "direction === 'in'" "$PAGE" \
    && pass "both endpoints are found in the descriptors, not hard-coded" \
    || fail "both endpoints are found in the descriptors" "an endpoint number is written into the page"

grep -q "const BAUD = 115200" "$PAGE" && ! grep -q "1200," "$PAGE" \
    && pass "the page does not send the 1200-baud reboot signal" \
    || fail "the page does not send the 1200-baud reboot signal" "that is exp117's request, and it would end the conversation"

if command -v node > /dev/null; then
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    # `.js` on purpose: node --check reads the extension, and a bare mktemp
    # name gets ERR_UNKNOWN_FILE_EXTENSION — which reports FAIL against a page
    # that is fine.
    sed -n '/^<script>/,/^<\/script>/p' "$PAGE" | sed '1d;$d' > "$WORK/page.js"
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

# Which firmware is on the board decides whether this page can do anything at
# all, and the failure is silent: any other firmware receives the bytes, never
# collects them, and prints nothing — which looks exactly like a broken page.
#
# All of these are SKIP and none is FAIL, including "some other experiment is
# flashed". That is a board doing something else, not a fault — the same rule
# lib.sh states about `exp_running`, and the reason exp101 stopped reporting
# red lines at people whose hardware was working. What the message has to do
# instead is be loud, because the failure it warns about is silent.
case "$(yi26 state 2>/dev/null)" in
    running)
        if exp_running 118; then
            echo "SKIP  exp118 is flashed but the kernel still owns the interfaces — run 'yi26 detach'"
        else
            echo "SKIP  the board is running a different experiment, so this page has nothing to talk to"
            echo "      Flash exp118 first. Sending to any other firmware here is silent: the"
            echo "      bytes arrive, nothing collects them, and no error appears anywhere —"
            echo "      which looks exactly like this page being broken."
        fi
        ;;
    detached)
        # Nothing can read the serial number while the interfaces are
        # detached, so this is reported rather than asserted.
        echo "SKIP  the interfaces are detached — ready for the browser, but flash exp118 first if you have not"
        ;;
    bootsel) echo "SKIP  the board is in BOOTSEL — flash exp118 first" ;;
    *)       echo "SKIP  no board attached (not an error)" ;;
esac

echo "NOTE  typing into a page and pressing Send is a human's job by design."
echo "      The README's Expected output is a real capture, read back with"
echo "      'yi26 log' from the same board."

exit "$FAILED"
