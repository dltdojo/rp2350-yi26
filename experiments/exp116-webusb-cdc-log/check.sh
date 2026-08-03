#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp116 quick check — non-interactive verdict.
#
# No firmware here. What a shell can check is the page's self-containment and
# whether the host is in a state where the page could work; what it cannot is
# anything a browser does, and that is said rather than faked.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=2   # one permission tap, then the page streams the log by itself
presence_check

USB_IFACE="cdc"
USB_CARRIES="log+control"
USB_HOST="webusb"
USB_RUNS_ON="any"
usb_check

PAGE=cdc-log-viewer.html

[[ -f "$PAGE" ]] \
    && pass "the page exists ($(wc -l < "$PAGE") lines, $(stat -c%s "$PAGE") bytes)" \
    || { fail "the page exists" "$PAGE is missing"; exit 1; }

if grep -qE 'src="https?:|href="https?:|@import|fetch\(|importScripts' "$PAGE"; then
    fail "the page is self-contained" "it references something outside itself"
else
    pass "the page is self-contained (no network, no CDN, no build step)"
fi

# The two control transfers are the experiment. Without SET_CONTROL_LINE_STATE
# the page claims everything, reports success, and receives nothing forever,
# because crates/usb-log waits for DTR before it writes a byte.
grep -q '0x20' "$PAGE" && grep -q '0x22' "$PAGE" \
    && pass "both CDC control requests are present (SET_LINE_CODING, SET_CONTROL_LINE_STATE)" \
    || fail "both CDC control requests are present" "0x20 and 0x22 must both appear"

# 1200 is the reboot signal. A page that sent it would drop the board into
# BOOTSEL mid-stream, which is a fine exercise and a terrible default.
if grep -qE 'BAUD *= *1200' "$PAGE"; then
    fail "the page does not send the 1200-baud reboot signal" \
         "BAUD is 1200 — that is exp105's trick, and it will reboot the board on connect"
else
    pass "the page does not send the 1200-baud reboot signal"
fi

# Endpoint numbers are read from the descriptors, not written down. exp118
# adds a function to this device and moves them.
grep -q "endpoints.find" "$PAGE" \
    && pass "endpoints are discovered from the descriptors, not hard-coded" \
    || fail "endpoints are discovered from the descriptors" "a remembered endpoint number breaks at exp118"

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

# ---------------------------------------------------------------------------
# The page emits the same NDJSON `yi26 log --json` does, so that an assistant
# helping from a rented Linux box cannot tell which instrument produced a log
# somebody pasted at it. Two implementations of one format drift unless
# something compares them, and neither of them gets to be the authority: both
# are run over one fixture and diffed against one committed expectation.
FIXTURE=../../tools/yi26/tests/log-format/lines.txt
EXPECTED=../../tools/yi26/tests/log-format/expected.ndjson

grep -q "BEGIN yi26-log-json" "$PAGE" && grep -q "END yi26-log-json" "$PAGE" \
    && pass "the page carries the extractable log-format block" \
    || fail "the page carries the extractable log-format block" "the markers check.sh slices between are gone"

if ! command -v node > /dev/null; then
    echo "SKIP  node is not installed, so the page's script cannot be checked here"
    echo "      (the Rust side is still pinned: cargo test -p yi26)"
elif [[ ! -f "$FIXTURE" || ! -f "$EXPECTED" ]]; then
    fail "the log-format fixture is present" "expected $FIXTURE and $EXPECTED"
else
    EXTRACT="$(mktemp -d)"
    trap 'rm -rf "$EXTRACT"' EXIT

    # Before anything clever: does the whole script even parse? A single typo
    # anywhere in it leaves a page that loads, renders, and does nothing at
    # all, with the reason visible only in a console nobody opened. `node
    # --check` cannot run this — it is full of DOM and WebUSB calls — but it
    # can refuse to accept a syntax error.
    sed -n '/^<script>/,/^<\/script>/p' "$PAGE" | sed '1d;$d' > "$EXTRACT/page.js"
    if node --check "$EXTRACT/page.js" 2>"$EXTRACT/syntax"; then
        pass "the page's script parses"
    else
        fail "the page's script parses" "$(head -3 "$EXTRACT/syntax" | tr '\n' ' ')"
    fi

    sed -n '/BEGIN yi26-log-json/,/END yi26-log-json/p' "$PAGE" > "$EXTRACT/parser.js"
    {
        cat "$EXTRACT/parser.js"
        echo 'process.stdout.write(yi26Ndjson(require("fs").readFileSync(0, "utf8")));'
    } > "$EXTRACT/run.js"

    if node "$EXTRACT/run.js" < "$FIXTURE" > "$EXTRACT/got.ndjson" 2>"$EXTRACT/err"; then
        if diff -q "$EXPECTED" "$EXTRACT/got.ndjson" > /dev/null; then
            pass "the page's parser agrees with yi26 byte for byte"
        else
            fail "the page's parser agrees with yi26" "$(diff "$EXPECTED" "$EXTRACT/got.ndjson" | head -4 | tr '\n' ' ')"
        fi
    else
        fail "the page's parser runs" "$(head -2 "$EXTRACT/err" | tr '\n' ' ')"
    fi
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

# Which of the three host states we are in decides what "correct" looks like,
# so it is reported rather than asserted. All three are legitimate.
if [[ -e /dev/ttyACM0 ]]; then
    echo "SKIP  the kernel still owns the interfaces — run 'yi26 detach' before connecting"
elif [[ "$(yi26 state)" == "detached" ]] && yi26 udev > /dev/null 2>&1; then
    pass "the interfaces are detached — a browser can claim them"
else
    echo "SKIP  no board attached (not an error)"
fi

echo "NOTE  claiming interfaces, sending control transfers and reading an endpoint"
echo "      are things only a browser does. ./run.sh walks through it, and the"
echo "      README's Expected output is a real capture."

exit "$FAILED"
