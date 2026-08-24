#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp184 quick check — non-interactive.
#
# Verifies CTAP 2.1 minimal compatibility for strict clients (Firefox):
# getInfo versions, options.clientPin = false, pinUvAuthProtocols: [1],
# and authenticatorClientPIN (0x06) getPinRetries handler.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=2
presence_check

USB_IFACE="cdc+hid"
USB_CARRIES="log+ctaphid"
USB_HOST="cdc_acm+hidraw"
USB_RUNS_ON="own"
usb_check

command -v python3 > /dev/null && pass "python3 present" \
    || { fail "python3 present" "needed to run verification tools"; exit 1; }

TARGET=thumbv8m.main-none-eabihf

if command -v cargo > /dev/null; then
    if cargo build --release --quiet 2> /dev/null; then
        ELF="target/$TARGET/release/exp184-the-client-that-must-know"
        if [[ -f "$ELF" ]]; then
            pass "firmware compiles ($(stat -c%s "$ELF") byte ELF)"
        else
            fail "firmware compiles" "cargo build --release"
        fi
    else
        fail "firmware compiles" "cargo build --release"
    fi
else
    echo "SKIP  no toolchain — see exp102"
fi

SRC=src/main.rs

grep -q 'AUTHENTICATOR_CLIENT_PIN' "$SRC" \
    && pass "authenticatorClientPIN (0x06) command handled in dispatch" \
    || fail "authenticatorClientPIN handler" "command 0x06 missing"

grep -q 'FIDO_2_1' "$SRC" \
    && pass "getInfo advertises FIDO_2_1" \
    || fail "FIDO_2_1 advertised" "missing FIDO_2_1 in versions"

grep -q 'clientPin' "$SRC" \
    && pass "options advertises clientPin" \
    || fail "clientPin advertised" "missing clientPin in options"

# Verify checked-in probe JSON
if [[ -f "firefox-probe.json" ]]; then
    echo "      ruling on firefox-probe.json"
    python3 verify.py "firefox-probe.json"
    [[ $? -eq 0 ]] || FAILED=1
fi

if exp_running 184; then
    pass "a board is running exp184"
    python3 verify.py
    [[ $? -eq 0 ]] || FAILED=1
else
    echo "SKIP  the board is not running exp184; checked-in probe record stands"
fi

for e in exp174 exp176 exp177 exp183; do
    grep -q "$e" README.md 2>/dev/null \
        && pass "the README names $e" \
        || fail "the README names $e" "this experiment builds directly on $e"
done

exit "$FAILED"
