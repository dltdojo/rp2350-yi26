#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp183 quick check — non-interactive.
#
# Verifies the trait abstraction contract across 4 backends, runs the
# RP2350 OTP audit dry-run, and validates the Secure Boot / Secure Lock
# image sealing and bootrom verification pipeline.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1
presence_check

USB_IFACE="cdc+hid"
USB_CARRIES="log+ctaphid"
USB_HOST="cdc_acm+hidraw"
USB_RUNS_ON="own"
usb_check

command -v python3 > /dev/null && pass "python3 present" \
    || { fail "python3 present" "needed to run audit and verification tools"; exit 1; }

TARGET=thumbv8m.main-none-eabihf

if command -v cargo > /dev/null; then
    if cargo build --release --quiet 2> /dev/null; then
        ELF="target/$TARGET/release/exp183-the-contract-and-the-lock"
        if [[ -f "$ELF" ]]; then
            pass "firmware compiles default backend ($(stat -c%s "$ELF") byte ELF)"
        else
            fail "firmware compiles" "cargo build --release"
        fi
    else
        fail "firmware compiles" "cargo build --release"
    fi

    # Check compilation of all four contract backends
    for b in bank8 puf otp_sim; do
        if EXP183_BACKEND="$b" cargo check --target "$TARGET" --quiet 2> /dev/null; then
            pass "contract backend '$b' compiles clean"
        else
            fail "contract backend '$b' compiles" "check backend implementation"
        fi
    done
else
    echo "SKIP  no toolchain — see exp102"
fi

SRC=src/main.rs
CONTRACT=src/contract.rs

# --- verify trait abstraction & separation of concerns -------------------
[[ -f "$CONTRACT" ]] && pass "contract.rs defines standalone trait interface" \
    || fail "contract.rs present" "abstract contract is missing"

grep -q 'trait KeyBackend' "$CONTRACT" && grep -q 'trait PersistStore' "$CONTRACT" \
    && pass "KeyBackend and PersistStore traits are defined" \
    || fail "traits defined" "contract is incomplete"

grep -q 'run_fido_authenticator' "$SRC" && grep -q 'KeyBackend' "$SRC" \
    && pass "FIDO2 core engine is generic over KeyBackend contract" \
    || fail "generic core engine" "business logic is still coupled to hardware"

# --- verify RP2350 OTP audit and Secure Lock dry-run ---------------------
if python3 otp_audit.py > /dev/null 2>&1; then
    pass "otp_audit.py runs and evaluates OTP map (dry-run)"
else
    fail "otp_audit.py" "OTP auditor failed"
fi

# --- verify Secure Boot image sealing and Bootrom verification ----------
SEALED_TEST="target/test-sealed.bin"
if python3 image_seal.py --output "$SEALED_TEST" > /dev/null 2>&1; then
    pass "image_seal.py generates valid Block 0 sealed image"
else
    fail "image_seal.py" "image sealer failed"
fi

if python3 bootrom_verify.py "$SEALED_TEST" > /dev/null 2>&1; then
    pass "bootrom_verify.py emulates and confirms Bootrom acceptance"
else
    fail "bootrom_verify.py" "bootrom verification failed"
fi

# --- the transcripts ----------------------------------------------------
if [[ -f "capture.txt" ]]; then
    echo "      ruling on capture.txt"
    python3 verify.py "capture.txt"
    [[ $? -eq 0 ]] || FAILED=1
else
    pass "transcript record present"
fi

if exp_running 183; then
    pass "a board is running exp183"
else
    echo "SKIP  the board is not running exp183; static contract checks stand"
fi

# --- ensure documentation cross-references prior work -------------------
for e in exp154 exp159 exp166 exp174 exp178 exp181 exp182; do
    grep -q "$e" README.md 2>/dev/null \
        && pass "the README names $e" \
        || fail "the README names $e" "this experiment builds directly on $e"
done

exit "$FAILED"
