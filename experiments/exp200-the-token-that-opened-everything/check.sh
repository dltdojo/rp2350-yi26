#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp200 quick check — everything but the board half needs no board.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

# The claim includes two firmwares' credential management, and that is
# verified by flashing exp189 and asking it over hidraw. No question needs a
# credential to exist, so none needs a press: a board, and nobody.
PRESENCE=1
LIFELINE="no: no firmware of its own — its board half flashes exp189, which has one"
presence_check
lifeline_check

USB_IFACE="cdc+hid"
USB_CARRIES="log+ctaphid"
USB_HOST="cdc_acm+hidraw"
USB_RUNS_ON="exp189"
usb_check

# --- steps 1 and 2: the model ---------------------------------------------
TLC=../../tools/tlc/tlc.sh
"$TLC" cited model || FAILED=1
if command -v java > /dev/null && [[ -f ../../tools/tlc/tla2tools.jar ]]; then
    "$TLC" parse model || FAILED=1
    "$TLC" check model || FAILED=1
else
    echo "SKIP  the model: needs java and tools/tlc/setup.sh (the network, once)"
fi

# --- steps 3 and 4 on a host: the crate, each finding a test ---------------
crate_test ../../crates/client-pin "crates/client-pin's tests pass, C1-C3 each among them"

# --- the two firmwares with credential management use it -------------------
for e in exp188 exp189; do
    src="$(ls ../$e-*/src/main.rs)"
    if grep -q 'For testing flexibility in credMgmt' "$src" || grep -q 'fn verify_pin_uv_auth_token' "$src"; then
        fail "$e decides credMgmt with crates/client-pin" "its own verifier, or its fallback, is back"
    else
        pass "$e keeps no verifier of its own and no fallback"
    fi
    grep -q 'pin_state.authorize(permission::CM, scope, &\[&sub_byte, params_raw' "$src" \
        && pass "$e MACs subCommand || subCommandParams and needs cm" \
        || fail "$e credMgmt authorization" "the call to authorize(permission::CM, ...) changed"
    grep -q 'Some(0x05) | Some(0x09) => {' "$src" \
        && pass "$e issues tokens with permissions through 0x09" \
        || fail "$e getPinUvAuthTokenUsingPinWithPermissions" "0x09 is not answered"
done
for e in exp186 exp187 exp188 exp189; do
    src="$(ls ../$e-*/src/main.rs)"
    if grep -q 'active_token' "$src"; then
        fail "$e issues tokens through crates/client-pin" "it still writes active_token"
    else
        pass "$e issues every token through crates/client-pin"
    fi
done

# --- steps 3 and 4 on a board: what run.sh recorded ------------------------
if grep -q '^-- credmgmt_rules_probe --' capture.txt 2>/dev/null; then
    got="$(sed -n '/^-- credmgmt_rules_probe --/{n;p}' capture.txt)"
    [[ "$got" == *'"verdict": "spec"'* ]] \
        && pass "on the board, exp189 refuses all three ways in" \
        || fail "exp189 follows the crate on the board" "it said: ${got:-nothing}"
else
    echo "SKIP  the board half: not captured yet (./run.sh with a board attached)"
fi

exit "$FAILED"
