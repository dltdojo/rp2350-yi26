#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp196 quick check — everything but the board half needs no board.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

# The claim includes a change to the transport exp194's firmware runs, and that
# is verified by flashing exp194 and asking it the new question over hidraw.
# A board attached; nobody at it — no case reaches user presence.
PRESENCE=1
LIFELINE="no: no firmware of its own — its board half flashes exp194, which has one"
presence_check
lifeline_check

USB_IFACE="cdc+hid"
USB_CARRIES="log+ctaphid"
USB_HOST="cdc_acm+hidraw"
USB_RUNS_ON="exp194"
usb_check

TLC=../../tools/tlc/tlc.sh
if command -v java > /dev/null && [[ -f ../../tools/tlc/tla2tools.jar ]]; then
    # --- step 1 and 2: the model, its citations, and what TLC says ----------
    "$TLC" parse model || FAILED=1
    "$TLC" cited model || FAILED=1
    "$TLC" check model || FAILED=1
else
    echo "SKIP  the model: needs java and tools/tlc/setup.sh (the network, once)"
fi

# --- step 3 and 4, on a host: before exp196 and after, the same scenarios ---
( cd replay && cargo test --quiet ) > /dev/null 2>&1 \
    && pass "the counterexamples reproduce against the crate before exp196, and not after (replay/)" \
    || fail "replay/ passes" "cd replay && cargo test — it needs the network once to fetch the pinned crate"
crate_test ../../crates/ctap-hid "crates/ctap-hid's own tests pass, H1 and H2 among them"

# --- and end to end, over a socket: the suite, the fix, and the old answer --
if ../../tools/vctaphid/selftest.sh > states.out 2>&1; then
    pass "tools/vctaphid: every case is answered to spec, init-keeps-other among them"
else
    fail "tools/vctaphid/selftest.sh passes" "$(grep FAIL states.out | head -1)"
fi
grep -q "catches a message eaten by another client's INIT" states.out \
    && pass "and a device with the old behaviour is caught by the new case" \
    || fail "the new case catches the old behaviour" "see tools/vctaphid/selftest.sh"

# --- step 4, on a board: what run.sh recorded ------------------------------
if grep -q '^-- init-keeps-other --' capture.txt 2>/dev/null; then
    got="$(sed -n '/^-- init-keeps-other --/{n;p}' capture.txt)"
    [[ "$got" == *'"verdict": "spec"'* ]] \
        && pass "on the board, exp194's firmware keeps A's message whole through another client's INIT" \
        || fail "exp194's firmware keeps A's message whole" "it said: ${got:-nothing}"
else
    echo "SKIP  the board half: not captured yet (./run.sh with a board attached)"
fi

exit "$FAILED"
