#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp197 quick check — everything but the board half needs no board.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

# The claim includes four firmwares' PIN handling, and that is verified by
# flashing exp189 and asking it over hidraw. No PIN operation waits for a
# person, so: a board, and nobody.
PRESENCE=1
LIFELINE="no: no firmware of its own — its board half flashes exp189, which has one"
presence_check
lifeline_check

USB_IFACE="cdc+hid"
USB_CARRIES="log+ctaphid"
USB_HOST="cdc_acm+hidraw"
USB_RUNS_ON="exp189"
usb_check

TLC=../../tools/tlc/tlc.sh
if command -v java > /dev/null && [[ -f ../../tools/tlc/tla2tools.jar ]]; then
    "$TLC" parse model || FAILED=1
    "$TLC" cited model || FAILED=1
    "$TLC" check model || FAILED=1
else
    echo "SKIP  the model: needs java and tools/tlc/setup.sh (the network, once)"
fi

# --- step 3 and 4 on a host: the crate, each finding a test ---------------
crate_test ../../crates/client-pin "crates/client-pin's tests pass, P1-P5 each among them"

# --- the four firmwares are on the crate, and the old answers are gone ----
for e in exp186 exp187 exp188 exp189; do
    src="$(ls ../$e-*/src/main.rs)"
    if grep -q 'use client_pin::PinState;' "$src" && ! grep -q 'retries_remaining' "$src"; then
        pass "$e keeps no PIN counter of its own"
    else
        fail "$e uses crates/client-pin" "$src still has its own PinState or counter"
    fi
    if grep -qE 'const CTAP2_ERR_PIN_(BLOCKED|AUTH_INVALID|AUTH_BLOCKED): u8 = 0x' "$src"; then
        fail "$e takes its PIN status codes from the crate" "a hand-written value is back"
    else
        pass "$e takes its PIN status codes from the crate"
    fi
done

# --- step 3 and 4 on a board: what run.sh recorded ------------------------
if grep -q '^-- pin_rules_probe --' capture.txt 2>/dev/null; then
    got="$(sed -n '/^-- pin_rules_probe --/{n;p}' capture.txt)"
    [[ "$got" == *'"verdict": "spec"'* ]] \
        && pass "on the board, exp189 refuses a second setPIN and stops after three wrong PINs" \
        || fail "exp189 follows the crate on the board" "it said: ${got:-nothing}"
else
    echo "SKIP  the board half: not captured yet (./run.sh with a board attached)"
fi

exit "$FAILED"
