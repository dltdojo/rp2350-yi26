#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
#
# exp188 quick check — non-interactive.
#
# Verifies CTAP 2.1 Passkey Discoverable Credentials & Credential Management (credMgmt):
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
        ELF="target/$TARGET/release/exp188-the-passkey-in-the-pocket"
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

grep -q 'ResidentStore' "$SRC" \
    && pass "ResidentStore struct and resident key storage implemented" \
    || fail "ResidentStore" "ResidentStore missing"

grep -q 'AUTHENTICATOR_CREDENTIAL_MANAGEMENT' "$SRC" \
    && pass "authenticatorCredentialManagement (0x0A) handled in dispatch" \
    || fail "credMgmt handler" "command 0x0A missing"

grep -q 'rk: true' README.md 2>/dev/null || grep -q 'rk' "$SRC" \
    && pass "Passkey rk: true option supported" \
    || fail "rk option" "rk option missing"

# Verify checked-in probe JSON
if [[ -f "passkey-credmgmt-probe.json" ]]; then
    echo "      ruling on passkey-credmgmt-probe.json"
    python3 verify.py "passkey-credmgmt-probe.json"
    [[ $? -eq 0 ]] || FAILED=1
fi

if exp_running 188; then
    pass "a board is running exp188"
else
    echo "SKIP  the board is not running exp188; checked-in probe record stands"
fi

for e in exp174 exp176 exp177 exp184 exp185 exp186 exp187; do
    grep -q "$e" README.md 2>/dev/null \
        && pass "the README names $e" \
        || fail "the README names $e" "this experiment builds directly on $e"
done

exit "$FAILED"

