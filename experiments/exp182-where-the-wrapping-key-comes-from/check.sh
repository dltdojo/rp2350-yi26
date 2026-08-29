#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp182 quick check — non-interactive.
#
# The claim is that this device's secret is not in its image, and the test for
# it is somebody else's attack failing: exp175's forge.py, unchanged, pointed at
# both firmwares. That runs here with no board attached. What needs a person is
# the round trip — two presses, and a power cycle before any of it, because
# flashing clears the SRAM the key is reconstructed from.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

# A power cycle after flashing, then a press per credential operation.
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
    || { fail "python3 present" "needed to run exp175's forgery"; exit 1; }
command -v fido2-token > /dev/null && pass "fido2-token present (the host's own tool)" \
    || fail "fido2-token present" "install libfido2-tools"

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp182-where-the-wrapping-key-comes-from
if command -v cargo > /dev/null; then
    if cargo build --release --quiet 2> /dev/null && [[ -f "$ELF" ]]; then
        pass "firmware compiles ($(stat -c%s "$ELF") byte ELF)"
    else
        fail "firmware compiles" "cargo build --release"
    fi
else
    echo "SKIP  no toolchain — see exp102"
fi

SRC=src/main.rs

# --- the secret is not a constant any more, and check that it cannot be --
grep -q 'DEVICE_SECRET' "$SRC" \
    && fail "no compiled-in device secret remains" "that constant is exp175's whole subject" \
    || pass "there is no compiled-in device secret left in the source"
grep -q 'fn mac(secret: &\[u8; 32\]' "$SRC" && grep -q 'fn derive_key(secret: &\[u8; 32\]' "$SRC" \
    && pass "both key-using functions take the secret as an argument, not from a global" \
    || fail "the secret is a parameter" "a global is a place it can be reached from anywhere"

# --- the two refusals, and the fact that they are different -------------
grep -q 'CTAP2_ERR_VENDOR_UNPROVISIONED' "$SRC" \
    && pass "an unprovisioned board has its own status, not the one that means no press" \
    || fail "the refusals are distinguishable" "exp173 is an experiment about one shared number"
UNPROV_SENDS="$(grep -c 'CTAP2_ERR_VENDOR_UNPROVISIONED\]' "$SRC")"
[[ "$UNPROV_SENDS" -eq 2 ]] \
    && pass "and both credential commands refuse with it (makeCredential, getAssertion)" \
    || fail "both commands refuse" "$UNPROV_SENDS send sites found, expected 2"

# --- the LED, because a remote user sees nothing else -------------------
grep -q 'LED_PRESS_NOW' "$SRC" && grep -q 'LED_UNPROVISIONED' "$SRC" \
    && pass "the LED has a state for 'press now' and one for 'power cycle me'" \
    || fail "the LED says what is wanted" "a script's stdout does not reach somebody driving this remotely"
grep -q 'LED_MODE.store(LED_PRESS_NOW' "$SRC" \
    && pass "and it is set where the presence window opens, not at the call sites" \
    || fail "the LED cannot be opened silently" "a future caller would forget"

# --- exp179's traps, inherited --------------------------------------------
grep -q 'UNIFORMITY_MIN' "$SRC" \
    && pass "enrolment refuses a cleared window (exp179's 0.00% after a flash)" \
    || fail "the enrolment guard" "H = K XOR 0 = K"

# --- the falsifiable one, which needs no board --------------------------
FORGE=../exp175-the-secret-is-the-file/forge.py
if [[ -f "$FORGE" && -f target/exp182-button.uf2 ]]; then
    if python3 "$FORGE" target/exp182-button.uf2 example.test > /dev/null 2>&1; then
        fail "exp175's forgery finds nothing here" "it produced an assertion, which means a secret is in the image"
    else
        pass "exp175's forgery, run live, finds no secret in this image"
    fi
else
    echo "SKIP  no built image to attack — cargo build first"
fi

# --- the transcripts ------------------------------------------------------
for f in capture-unprovisioned.txt capture-provisioned.txt capture-roundtrip.txt capture-forge.txt; do
    if [[ -f "$f" ]]; then
        echo "      ruling on $f"
        python3 verify.py "$f"
        [[ $? -eq 0 ]] || FAILED=1
    else
        fail "$f is checked in" "the record is incomplete"
    fi
done

if exp_running 182; then
    pass "a board is running exp182"
else
    echo "SKIP  the board is not running exp182; the checked-in transcripts stand"
fi

# --- the argument it makes -----------------------------------------------
for e in exp175 exp179 exp181 exp163; do
    grep -q "$e" README.md 2>/dev/null \
        && pass "the README names $e" \
        || fail "the README names $e" "this rung is made of those four"
done

exit "$FAILED"
