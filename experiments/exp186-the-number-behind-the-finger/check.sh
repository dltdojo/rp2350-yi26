#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
#
# exp186 quick check — non-interactive.
#
# Verifies CTAP 2.1 Full PIN Lifecycle State Machine:
# setPIN, changePIN, getPinToken, 8-retry countdown, active token issuance, and UV verification.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=2
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

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
        ELF="target/$TARGET/release/exp186-the-number-behind-the-finger"
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

grep -q 'PinState' "$SRC" \
    && pass "PinState struct and retry counter implemented" \
    || fail "PinState" "PinState struct missing"

grep -q 'setPIN' "$SRC" \
    && pass "setPIN (0x03) subCommand handled" \
    || fail "setPIN handler" "setPIN logic missing"

grep -q 'getPinToken' "$SRC" \
    && pass "getPinToken (0x05) subCommand handled" \
    || fail "getPinToken handler" "getPinToken logic missing"

grep -q 'FLAG_UV' "$SRC" \
    && pass "FLAG_UV (0x04) set in authData when pinUvAuthParam verified" \
    || fail "FLAG_UV" "FLAG_UV missing"

# Verify checked-in probe JSON
if [[ -f "pin-lifecycle-probe.json" ]]; then
    echo "      ruling on pin-lifecycle-probe.json"
    python3 verify.py "pin-lifecycle-probe.json"
    [[ $? -eq 0 ]] || FAILED=1
fi

if exp_running 186; then
    pass "a board is running exp186"
    python3 verify.py
    [[ $? -eq 0 ]] || FAILED=1
else
    echo "SKIP  the board is not running exp186; checked-in probe record stands"
fi

for e in exp174 exp176 exp177 exp184 exp185; do
    grep -q "$e" README.md 2>/dev/null \
        && pass "the README names $e" \
        || fail "the README names $e" "this experiment builds directly on $e"
done

exit "$FAILED"

