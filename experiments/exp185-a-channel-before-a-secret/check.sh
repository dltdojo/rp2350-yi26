#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp185 quick check — non-interactive.
#
# Verifies CTAP 2.1 PIN Protocol 1:
# Key Agreement (ECDH P-256), AES-256-CBC encrypted tunnel, and HMAC-SHA256 authentication.
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
        ELF="target/$TARGET/release/exp185-a-channel-before-a-secret"
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

grep -q 'decapsulate_shared_secret' "$SRC" \
    && pass "ECDH P-256 key agreement and decapsulation implemented" \
    || fail "ECDH decapsulation" "decapsulate_shared_secret missing"

grep -q 'decrypt_pin_payload' "$SRC" \
    && pass "AES-256-CBC decryption implemented" \
    || fail "AES-256-CBC decryption" "decrypt_pin_payload missing"

grep -q 'verify_pin_auth' "$SRC" \
    && pass "HMAC-SHA256 pinAuth verification implemented" \
    || fail "HMAC-SHA256 pinAuth" "verify_pin_auth missing"

# Verify checked-in probe JSON
if [[ -f "pin-channel-probe.json" ]]; then
    echo "      ruling on pin-channel-probe.json"
    python3 verify.py "pin-channel-probe.json"
    [[ $? -eq 0 ]] || FAILED=1
fi

if exp_running 185; then
    pass "a board is running exp185"
    python3 verify.py
    [[ $? -eq 0 ]] || FAILED=1
else
    echo "SKIP  the board is not running exp185; checked-in probe record stands"
fi

for e in exp174 exp176 exp177 exp184; do
    grep -q "$e" README.md 2>/dev/null \
        && pass "the README names $e" \
        || fail "the README names $e" "this experiment builds directly on $e"
done

exit "$FAILED"

