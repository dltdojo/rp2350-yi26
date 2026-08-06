#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp153 quick check — non-interactive verdict.
#
# PRESENCE 3: the claim is that a phone will carry this board's packets to the
# internet, and nothing here can hold a phone or turn on tethering.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=3
presence_check

USB_IFACE="cdc+ncm+msc"
USB_CARRIES="log+frames+scsi+files"
USB_HOST="cdc_acm+cdc_ncm+usb-storage"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp153-out-through-the-phone
UF2=target/exp153.uf2
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
crate_test ../../crates/fat12 "crates/fat12 passes its own tests"

# ---- the role, which is the only one that can ask the question --------------
#
# A board that assigns itself an address has no gateway by construction, and
# would answer the question by refusing to ask it.
if grep -q 'default = \["auto-reboot", "ask-for-an-address"\]' Cargo.toml; then
    pass "the board asks for its address, so the gateway is somebody else's to give"
else
    fail "the board asks for its address" "a self-assigned address has no way out to test"
fi
# Removed rather than left in and ignored: a NAT translates the addresses it
# handed out, so sending from one that was never leased is a second variable.
if grep -q 'pin_into_subnet' "$SRC"; then
    fail "the leased address is kept" \
         "exp152 pins to .250; a NAT need not translate an address it did not lease"
else
    pass "the leased address is kept — nothing is sent from an address nobody handed out"
fi

# ---- what was offered, said before anything is tried with it ---------------
#
# A log that only prints what worked cannot tell an offer that was never made
# from an offer that did not work.
if grep -q 'a claim that there is a way out' "$SRC" && grep -q 'NO gateway offered' "$SRC"; then
    pass "the gateway is logged as an offer, and its absence is logged too"
else
    fail "the lease is reported both ways" \
         "'no gateway' and 'gateway did not work' are different findings"
fi
if grep -q 'no DNS server offered' "$SRC"; then
    pass "a lease with no resolver in it says so"
else
    fail "a missing resolver is reported" "silence here reads as a resolver that failed"
fi

# ---- the two requests, which differ in exactly one thing -------------------
#
# Same address, separate connections, one header apart. A difference between
# the answers can then only be about the name, never about the route.
if grep -q 'Host: 1.1.1.1' "$SRC" && grep -q 'Host: cp.cloudflare.com' "$SRC"; then
    pass "two requests to one address, differing in the Host header"
else
    fail "the pair differs only in Host" "any other difference makes the comparison mean less"
fi
if grep -qE 'OUT_HOST: \[u8; 4\] = \[1, 1, 1, 1\]' "$SRC"; then
    pass "the target is a literal address — an experiment frozen once must not depend on a name"
else
    fail "the target is a literal address" "a renumbered name makes a frozen walkthrough describe nothing"
fi
# The 301 is not a failure to be retried away. Both codes are recorded and the
# pair is the result.
if grep -q 'static STATUS_ROOT' "$SRC" && grep -q 'static STATUS_204' "$SRC"; then
    pass "both status codes are kept — either one alone is half the result"
else
    fail "both status codes are kept" "the finding is the difference, not one number"
fi

# ---- the ordering that keeps two failures distinguishable ------------------
#
# A client that cannot resolve and a client that cannot route look identical
# from a bench. Resolving first would have made one of them unmeasurable.
if python3 - "$SRC" <<'EOF'
import sys
src = open(sys.argv[1]).read()
fetch = src.find('if STATUS_ROOT.load(Ordering::Relaxed) == 0 {')
dns = src.find('stack.dns_query(')
sys.exit(0 if 0 <= fetch < dns else 1)
EOF
then
    pass "the DNS query runs after the requests, so a dead resolver cannot look like a dead link"
else
    fail "DNS runs after the literal-address requests" \
         "a name in front of the measurement makes two different failures identical"
fi

# ---- the evidence is the raw line, not the parsed number -------------------
#
# `status_of` is a convenience. If it is ever wrong, the first line of the
# response is still in the log verbatim and the reader loses nothing.
if grep -q 'log!("out: {} — {}", label, line)' "$SRC"; then
    pass "the response's own first line is logged verbatim"
else
    fail "the raw first line is logged" "a parsed code is the only evidence if the raw line is not there"
fi
if grep -q 'Location: {}' "$SRC"; then
    pass "the Location header is printed — it names the protocol this board cannot speak"
else
    fail "the redirect target is printed" "'301' without the target is half the finding"
fi

# ---- bounded, because this is a measurement and not a watcher --------------
if grep -qE 'OUT_ATTEMPTS: u32 = [0-9]+' "$SRC" && grep -q 'OUT_DONE.store(true' "$SRC"; then
    pass "the attempts are bounded and their end is recorded"
else
    fail "the attempts are bounded" \
         "an unbounded retry loop fills the log with the reader's own waiting"
fi
# "still trying" and "tried and got nothing" are acted on differently — one
# asks somebody to wait, the other asks them to look at the tethering switch.
if grep -q 'still trying' "$SRC" && grep -q 'no answer' "$SRC"; then
    pass "the page tells 'still trying' from 'tried and got nothing'"
else
    fail "the two silences are distinguished" "they lead a reader to do different things"
fi
# An attempt that was never worth making is not an attempt that failed.
if grep -q 'nothing to try. Nothing was sent' "$SRC"; then
    pass "a lease with no gateway is reported as nothing sent, not as a failure"
else
    fail "no gateway means nothing was sent" "reporting it as a failure blames the wrong thing"
fi

# ---- the crate this experiment was most at risk of breaking ----------------
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

# ---- the reader's own footsteps, for the fourth time -----------------------
#
# HTTP requests in exp151, mDNS chatter in exp151, a hundred READ(10)s in
# exp152. The page a person opens is reached by opening the drive, so the
# drive's own traffic and the server's own traffic are both the reader arriving.
noisy="$(grep -cE '^\s*log!\("http:' "$SRC" || true)"
if [[ "$noisy" == "0" ]]; then
    pass "nothing the HTTP server says about itself is retained"
else
    fail "the server's own lines are transient" \
         "$noisy retained line(s) about serving — 58 of 64 was the measurement"
fi
if python3 - "$SRC" <<'EOF'
import sys
src = open(sys.argv[1]).read()
bad = []
for needle in ("{} lba {} +{} blocks", "{}  -> ok", "MODE SENSE(6)  -> READ-ONLY"):
    k = src.find(needle)
    if k < 0:
        continue
    before = src[:k]
    if before[max(before.rfind("log!("), before.rfind("log_transient!(")):].startswith("log!("):
        bad.append(needle)
if bad:
    print("retained:", "; ".join(bad)); sys.exit(1)
EOF
then
    pass "the drive's own traffic is transient — reaching the log must not fill it"
else
    fail "per-command SCSI chatter is transient" \
         "a hundred READ(10)s is what opening the drive costs, and it buried the boot lines"
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

# The result goes ABOVE the log, not in it. This is the line somebody
# photographs, and a reader should not have to find it among a hundred others.
if python3 - "$SRC" <<'EOF'
import sys
src = open(sys.argv[1]).read()
page = src[src.find("fn render(out: &mut [u8]"):]
page = page[:page.find("\n}\n")]
table = page.find("outcome(&mut w,")
log = page.find("usb_log::retained")
sys.exit(0 if 0 <= table < log else 1)
EOF
then
    pass "the two answers are above the log, where a photograph will catch them"
else
    fail "the result is above the log" "a finding inside a hundred lines is a finding nobody reads"
fi

# ---- the medium that does not exist until there is something to say --------
if grep -q 'ASC_MEDIUM_NOT_PRESENT' "$SRC" && grep -q 'SENSE_NOT_READY' "$SRC"; then
    pass "the board reports NOT READY / MEDIUM NOT PRESENT before it has an address"
else
    fail "the medium is absent until the address is known" \
         "a volume mounted before it knows the answer is one the host will cache"
fi
if grep -qE 'matches!\(op, 0x25 \| 0x28' "$SRC"; then
    pass "capacity and reads are refused in the same breath as the readiness poll"
else
    fail "capacity and reads agree with the readiness answer" \
         "a host given a capacity will mount whatever it is offered"
fi
if [[ "$(grep -c 'let clusters = lay_down(disk' "$SRC")" == "1" ]]; then
    pass "the volume is laid down exactly once — there is no second version"
else
    fail "the volume is laid down once" "a second version is a cache question again"
fi
if grep -q 'OPEN    HTM' "$SRC" && grep -q 'ADDRESS TXT' "$SRC"; then
    pass "the drive carries a link to tap and the address as plain text"
else
    fail "the drive carries a link and the address" "the whole point is not having to type it"
fi
if grep -q 'filled its buffer exactly' "$SRC"; then
    pass "a page that fills its buffer says so — silence is what hid the last one"
else
    fail "truncation is detected, not silent" \
         "a cut page renders as a working button with half an address on it"
fi
if grep -q 'THE ORDER MATTERS' "$SRC"; then
    pass "the drive's own README leads with the order, not with the explanation"
else
    fail "the drive says what order to do things in" \
         "tethering is greyed out until something is plugged in, so there is only one order"
fi
if grep -q 'TURN ON Ethernet tethering' "$SRC"; then
    pass "the waiting log names the action, not just the state"
else
    fail "the waiting log names the action" "'still asking' does not tell anybody what to do"
fi

# ---- the board half --------------------------------------------------------
PRODUCT="$(yi26 port --json 2>/dev/null | sed -n 's/.*"product":"\([^"]*\)".*/\1/p')"
if [[ "$PRODUCT" != *"exp153"* ]]; then
    echo "SKIP  no board running exp153 (enumerated as: ${PRODUCT:-nothing})"
    exit "$FAILED"
fi
echo "NOTE  enumerated as: $PRODUCT"
OUT="$(yi26 log --seconds 8 2>/dev/null || true)"

if echo "$OUT" | grep -q 'link UP'; then
    pass "a host driver claimed the NCM interface"
else
    echo "NOTE  no link yet — nothing has bound cdc_ncm on this host"
fi

addr="$(echo "$OUT" | grep -oE 'http://[0-9.]+' | tail -1)"
if [[ -z "$addr" ]]; then
    echo "NOTE  no address. This host is not sharing its connection, which is a sudo"
    echo "      step here and a switch on a phone — see the README."
    echo "NOTE  what no script here can do: turn on a phone's Ethernet tethering and"
    echo "      look at the drive that appears, which is the entire experiment."
    exit "$FAILED"
fi
pass "the board has an address and says so — $addr"

if echo "$OUT" | grep -q 'a claim that there is a way out'; then
    pass "the lease carried a gateway, so there was something to try"
elif echo "$OUT" | grep -q 'nothing to try. Nothing was sent'; then
    echo "NOTE  the lease had no gateway. Nothing was sent, which is not a failed attempt."
fi

root_code="$(echo "$OUT" | grep -oE 'GET http://1\.1\.1\.1/ — HTTP/1\.[01] [0-9]{3}' | grep -oE '[0-9]{3}$' | tail -1)"
c204="$(echo "$OUT" | grep -oE 'generate_204 — HTTP/1\.[01] [0-9]{3}' | grep -oE '[0-9]{3}$' | tail -1)"
if [[ -n "$root_code" && -n "$c204" ]]; then
    pass "the board got out: / -> $root_code, /generate_204 -> $c204"
    if [[ "$root_code" == "301" && "$c204" == "204" ]]; then
        pass "and the pair is the finding — redirected off one, served the other"
    else
        echo "NOTE  the pair was $root_code / $c204, not 301 / 204. Read the log before"
        echo "      concluding anything; the raw first lines are in it."
    fi
else
    echo "NOTE  no answers recorded yet. Three attempts, five seconds apart — try a"
    echo "      longer 'yi26 log --seconds'."
fi

echo "NOTE  what no script here can do: turn on a phone's Ethernet tethering and"
echo "      look at the drive that appears, which is the entire experiment."

exit "$FAILED"
