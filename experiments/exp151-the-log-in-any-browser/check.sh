#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp151 quick check — non-interactive verdict.
#
# PRESENCE 3: the claim is that somebody with a phone and no WebUSB can read
# this board's log, and nothing here can hold a phone.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=3
presence_check

USB_IFACE="cdc+ncm"
USB_CARRIES="log+frames"
USB_HOST="cdc_acm+cdc_ncm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp151-the-log-in-any-browser
UF2=target/exp151.uf2
SRC=src/main.rs
LOGSRC=../../crates/usb-log/src/lib.rs

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"; exit 1
fi

if cargo build --release --quiet 2>/dev/null && elf2flash convert -b rp2350 "$ELF" "$UF2" > /dev/null 2>&1; then
    pass "builds ($(stat -c%s "$UF2") byte .uf2)"
else
    fail "builds" "cargo build --release"; exit "$FAILED"
fi

readelf -S "$ELF" 2>/dev/null | grep -qE '\.vector_table +PROGBITS +10000000' \
    && pass "linked at 0x10000000 — an ordinary image" \
    || fail "linked at 0x10000000" "a moved image is the exp139 dark-board bug"

reboot_watcher_check "$SRC"

crate_test ../../crates/log-ring "crates/log-ring passes its own tests"

# ---- the crate this experiment was most at risk of breaking ----------------
#
# `usb-log` is the one instrument everything here is debugged with. The rule
# for touching it was that a build without `retain` must be what it always was.
if grep -q 'retain = \["dep:log-ring"\]' ../../crates/usb-log/Cargo.toml; then
    pass "the retained ring is behind a feature — off by default"
else
    fail "the ring is behind a feature" "usb-log must be unchanged for every other experiment"
fi
if grep -q '#\[cfg(feature = "retain")\]' "$LOGSRC"; then
    pass "every ring touchpoint in usb-log is cfg-gated"
else
    fail "the ring is cfg-gated in usb-log" "an ungated ring costs every firmware here 6 KiB"
fi

# ---- the bug a board found -------------------------------------------------
#
# Reading the log over HTTP logs lines about reading the log over HTTP, and the
# page refreshes itself. Measured before the fix: 58 of 64 retained lines were
# the reader's own footsteps. The log had been erased by the act of reading it.
if grep -q 'pub fn log_transient' "$LOGSRC"; then
    pass "usb-log can say something without keeping it — the reader's own noise"
else
    fail "usb-log has log_transient" "without it, reading the log erases the log"
fi
noisy="$(grep -cE '^\s*log!\("http:' "$SRC" || true)"
if [[ "$noisy" == "0" ]]; then
    pass "nothing the HTTP server says about itself is retained"
else
    fail "the server's own lines are transient" \
         "$noisy retained line(s) about serving — 58 of 64 was the measurement"
fi
if grep -qE 'log_transient!\("http:' "$SRC"; then
    pass "...and they still go to the serial port, where they are wanted"
else
    fail "the server's lines still reach serial" "they are noise in a history, not in a stream"
fi

# ---- the page has to work in the browsers this experiment exists for -------
page="$(sed -n '/fn render/,/^}/p' "$SRC")"
echo "$page" | grep -q '<script' \
    && fail "no script in the page" "this page is for browsers that lack WebUSB; assuming they have anything else repeats the mistake" \
    || pass "no script in the page — it is for whatever browser somebody has"
echo "$page" | grep -q 'http-equiv=refresh' \
    && pass "the page refreshes itself without script" \
    || fail "the page refreshes itself" "a log you have to reload by hand is not a log viewer"
echo "$page" | grep -q '&lt;' \
    && pass "log text is escaped before it becomes HTML" \
    || fail "log text is escaped" "a firmware that logs a < would break its own page"

# The count moved onto the page precisely so that counting does not cost ring
# lines. If it goes back into the log, the flood comes back with it.
grep -q 'request(s) answered' "$SRC" \
    && pass "the request count is on the page, not in the log" \
    || fail "the request count is on the page" "putting it in the log is what flooded the ring"

# ---- one role, and it is the one that works --------------------------------
if grep -q 'default = \["auto-reboot", "ask-for-an-address"\]' Cargo.toml; then
    pass "the board asks for its address — exp150 measured that the other way is unreachable"
else
    fail "the board asks for its address" "a self-assigned address is not reachable from a phone browser"
fi

# ---- the board half --------------------------------------------------------
PRODUCT="$(yi26 port --json 2>/dev/null | sed -n 's/.*"product":"\([^"]*\)".*/\1/p')"
if [[ "$PRODUCT" != *"exp151"* ]]; then
    echo "SKIP  no board running exp151 (enumerated as: ${PRODUCT:-nothing})"
    exit "$FAILED"
fi
echo "NOTE  enumerated as: $PRODUCT"
OUT="$(yi26 log --seconds 6 2>/dev/null || true)"
addr="$(echo "$OUT" | grep -oE 'http://[0-9.]+' | tail -1)"
if [[ -n "$addr" ]]; then
    pass "the board has an address and says so — $addr"
    if body="$(curl -s --max-time 6 "$addr/")" && [[ -n "$body" ]]; then
        held="$(echo "$body" | sed 's/.*<pre>//' | sed 's|</pre>.*||' | grep -c '')"
        noise="$(echo "$body" | sed 's/.*<pre>//' | sed 's|</pre>.*||' | grep -cE 'http: (connection|served)' || true)"
        pass "it served its own log over HTTP ($held lines, $noise of them about serving)"
        [[ "$noise" == "0" ]] \
            && pass "and reading it did not fill it with the reading" \
            || fail "reading it did not fill it" "$noise retained lines are the reader's footsteps"
    else
        echo "NOTE  nothing answered at $addr — is this host sharing its connection?"
    fi
else
    echo "NOTE  no address yet. This host has to be the DHCP server: see the README."
fi

echo "NOTE  what no script here can do: open that address in a browser that has"
echo "      no WebUSB at all, which is the entire point of this experiment."

exit "$FAILED"
