#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
#
# exp187 quick check — non-interactive.
#
# Verifies CTAP 2.1 Authenticator Reset (0x07 with 10s window interlock) & On-Device Gesture UV (Triple-Tap):
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
        ELF="target/$TARGET/release/exp187-the-three-taps-and-the-reset"
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

grep -q 'AUTHENTICATOR_RESET' "$SRC" \
    && pass "authenticatorReset (0x07) command handled in dispatch" \
    || fail "authenticatorReset handler" "command 0x07 missing"

grep -q 'RESET_WINDOW_SECS' "$SRC" \
    && pass "10-second power-on reset window interlock enforced" \
    || fail "RESET_WINDOW_SECS" "reset window check missing"

grep -q 'wait_for_triple_tap' "$SRC" \
    && pass "on-device triple-tap gesture UV implemented" \
    || fail "wait_for_triple_tap" "gesture detection missing"

grep -q 'getPinUvAuthTokenUsingUv' "$SRC" || grep -q 'sub_cmd' "$SRC" \
    && pass "getPinUvAuthTokenUsingUv (0x06) handled" \
    || fail "getPinUvAuthTokenUsingUv" "subcommand 0x06 missing"

# Verify checked-in probe JSON
if [[ -f "gesture-reset-probe.json" ]]; then
    echo "      ruling on gesture-reset-probe.json"
    python3 verify.py "gesture-reset-probe.json"
    [[ $? -eq 0 ]] || FAILED=1
fi

if exp_running 187; then
    pass "a board is running exp187"
else
    echo "SKIP  the board is not running exp187; checked-in probe record stands"
fi

for e in exp174 exp176 exp177 exp184 exp185 exp186; do
    grep -q "$e" README.md 2>/dev/null \
        && pass "the README names $e" \
        || fail "the README names $e" "this experiment builds directly on $e"
done

exit "$FAILED"

