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
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

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
crate_test ../../crates/mdns "crates/mdns passes its own tests"

# ---- the half that makes the window real -----------------------------------
#
# Serving the log is useless to somebody without WebUSB if finding the board
# needs WebUSB. A name is what closes that.
if grep -qP 'MDNS_NAME_STR: &str = "\w+"' "$SRC"; then
    pass "the board answers to a name, so nobody has to be told a number"
else
    fail "the board answers to a name" "an address discovered over CDC needs the WebUSB this escapes"
fi
if grep -q 'join_multicast_group' "$SRC"; then
    pass "it joins 224.0.0.251 — one-shot queries arrive nowhere else"
else
    fail "it joins the mDNS group" "nothing can be received without it"
fi
# The reply goes back to whoever asked, not to the group. That is what a
# one-shot querier — which is what Android is — waits for.
if grep -q 'send_to(&tx\[..len\], from.endpoint)' "$SRC"; then
    pass "the answer goes back to the asker, which is what a one-shot query wants"
else
    fail "the answer is unicast to the asker" "a one-shot querier is not listening to the group"
fi
# Per-query mDNS chatter must not push the board's own history out of the ring
# — the same bug the HTTP server had, one link layer down. The distinction is
# not importance but *whose log it belongs in*: an answer given and a question
# about somebody else are chatter, while "listening as yi26.local" and anything
# that stops the responder are what a late reader needs waiting for them.
#
# Three earlier versions of this guard were blunter and failed on exactly those
# lines. It is done in Python because the calls span lines and their strings
# carry format placeholders, so no single grep sees both ends of one.
if python3 - "$SRC" <<'EOF'
import re, sys
src = open(sys.argv[1]).read()
bad = []
for needle in ("mdns: answered", "bytes ignored"):
    k = src.find(needle)
    if k < 0:
        continue
    before = src[:k]
    macro = max(before.rfind("log!("), before.rfind("log_transient!("))
    if before[macro:].startswith("log!("):
        bad.append(needle)
if bad:
    print("retained:", ", ".join(bad))
    sys.exit(1)
EOF
then
    pass "per-query mDNS chatter is transient; startup and failures are kept"
else
    fail "per-query mDNS chatter is transient" \
         "58 of 64 was the measurement when the server kept its own noise"
fi

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

# ---- the address is pinned to the subnet, not to the lease -----------------
#
# A bookmark is only as durable as the address it points at, and a leased
# address is the server's business. Pinning makes it a property of the subnet,
# which is the part Android keeps stable.
if grep -q 'fn pin_into_subnet' "$SRC" && grep -q 'set_config_v4' "$SRC"; then
    pass "the board takes a fixed address on whatever network it is given"
else
    fail "the board pins its address" "a bookmark to a leased address is only as good as the lease"
fi
# Mask arithmetic, not "replace the last octet" — the last octet is only the
# host part at /24, and nothing promises /24.
if grep -q 'u32::MAX << (32 - prefix' "$SRC"; then
    pass "the pinning is mask arithmetic, so it holds at any prefix length"
else
    fail "the pinning is mask arithmetic" "replacing the last octet is only right at /24"
fi
# The two addresses in every subnet that are not usable. Landing on either
# would take the board off the air without saying so.
if grep -q 'the network address, or the broadcast address' "$SRC"; then
    pass "the network and broadcast addresses are refused rather than taken"
else
    fail "network and broadcast are refused" "either would take the board off the air in silence"
fi
# One line, riding along: some DHCP servers make a client's own name
# resolvable. Whether Android's does is the cheap half of this experiment.
if grep -q 'dhcp.hostname = Some' "$SRC"; then
    pass "the board tells the DHCP server its name — free to ask, and it might land"
else
    fail "the board sends a DHCP hostname" "option 12 costs one line and some servers act on it"
fi

# ---- the file that exists because a name still cannot be typed -------------
#
# Measured on a Pixel 9a: Chrome's address bar searches Google for
# `http://yi26.local/`, scheme and all. So the name has to be tappable.
GO=go.html
if [[ -f "$GO" ]]; then
    pass "go.html is here — the name is tappable, because it is not typable"
else
    fail "go.html is here" "a phone's address bar searches for yi26.local instead of opening it"
fi

# The link and the firmware have to agree on the name, and there is nothing
# that would fail loudly if they stopped.
# Pulled from the one place the name is written, so this guard moves when the
# name does. An earlier version keyed on the literal `b"yi26"` and went stale
# the moment the constant was expressed differently — the guard drifted, not
# the thing it was guarding.
fw_name="$(grep -oP 'MDNS_NAME_STR: &str = "\K[^"]+' "$SRC")"
if grep -q "href=\"http://${fw_name}.local/\"" "$GO"; then
    pass "go.html links to ${fw_name}.local, which is the name the firmware answers to"
else
    fail "go.html and the firmware agree on the name" \
         "the firmware answers to ${fw_name}.local — a link to anything else goes nowhere"
fi

# It must need nothing the students it is for do not have.
grep -q 'navigator.usb' "$GO" \
    && fail "go.html needs no WebUSB" "it exists for browsers that do not have it" \
    || pass "go.html needs no WebUSB — that is the entire point of it"
grep -qE '\bfetch\(' "$GO" \
    && fail "go.html does not fetch" "a fetch from this page to http:// is mixed content and is refused" \
    || pass "go.html navigates rather than fetching — the one thing measured to work"

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
