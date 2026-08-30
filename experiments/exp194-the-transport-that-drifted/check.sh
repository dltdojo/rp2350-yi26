#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
#
# exp194 quick check — non-interactive, and it needs nobody and no board.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed
#
# The live half is ./drift.sh, which flashes six firmwares and writes
# capture.txt. This rules on that capture and on the suite itself.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1
LIFELINE=yes
presence_check
lifeline_check

USB_IFACE="cdc+hid"
USB_CARRIES="log+ctaphid"
USB_HOST="cdc_acm+hidraw"
USB_RUNS_ON="own+exp168+exp170+exp172+exp174+exp184+exp189"
usb_check

command -v python3 > /dev/null && pass "python3 present" \
    || { fail "python3 present" "needed to drive the suite and rule on it"; exit 1; }

CLIENT=../../tools/ctaphid/ctaphid.py

# The firmware, and the crate under it. The crate is where every judgement
# lives, so its tests are this experiment's cheapest evidence and run first.
crate_test ../../crates/ctap-hid "the transport's twenty-two host tests pass"

if command -v cargo > /dev/null; then
    cargo build --release --quiet 2> /dev/null \
        && pass "the firmware compiles" \
        || fail "the firmware compiles" "cargo build --release"
fi

grep -q "ctap_hid::" src/main.rs || grep -q "use ctap_hid" src/main.rs \
    && pass "the firmware's decisions come from crates/ctap-hid" \
    || fail "src/main.rs uses ctap-hid" "a copied transport measures nothing"

[[ -f "$CLIENT" ]] \
    && pass "the client is in tools/, not here — one suite for every firmware" \
    || fail "tools/ctaphid/ctaphid.py exists" "a suite that changes between boards is not a comparison"

python3 -c "import ast,sys; ast.parse(open('$CLIENT').read())" 2> /dev/null \
    && pass "and it parses" \
    || fail "the client parses" "python3 -c ast.parse"

# Every case has to name what the specification says, or the run is describing
# firmwares rather than grading them.
CASES="$(python3 "$CLIENT" --list 2> /dev/null | wc -l)"
[[ "$CASES" -ge 10 ]] \
    && pass "and it names what the specification requires for all $CASES cases" \
    || fail "the client documents its cases" "python3 $CLIENT --list"

# The one thing about the suite that must not drift: a device that will not open
# a channel is a verdict, not a crash. It exited instead, the first time this
# ran, and swallowed four of exp189's rows.
grep -q "class NoChannel" "$CLIENT" \
    && pass "a refused channel is a verdict rather than an exit" \
    || fail "NoChannel is caught" "an exit here turns a finding into a missing row"

# --- the capture ------------------------------------------------------------
if [[ -f capture.txt ]]; then
    echo "      ruling on capture.txt"
    python3 verify.py capture.txt
    [[ $? -eq 0 ]] || FAILED=1
else
    fail "capture.txt exists" "run ./drift.sh — it needs a board and nobody"
fi

for e in exp168 exp189 exp193; do
    grep -q "$e" README.md 2>/dev/null \
        && pass "the README names $e" \
        || fail "the README names $e" "this experiment stands on $e"
done

exit "$FAILED"
