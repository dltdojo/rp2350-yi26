#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp181 quick check — non-interactive.
#
# The claim needs power to have actually gone away twice: once to enrol on a
# window nobody has written, once to reconstruct from a fresh one. No software
# here can arrange that, so both transcripts are checked in and verify.py rules
# on them — including the one where the firmware refused to do anything.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

# Two cable pulls, seconds apart, and nothing else. The firmware does the rest
# and reports for as long as it is powered.
PRESENCE=2
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

command -v python3 > /dev/null && pass "python3 present" \
    || { fail "python3 present" "needed to rule on the transcripts"; exit 1; }

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp181-a-key-that-is-written-nowhere
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

# --- the key is not stored, which is the whole claim ---------------------
grep -q 'log!.*key' "$SRC" && grep -q 'the key itself is not printed' "$SRC" \
    && pass "the firmware says the key is not printed, in the log itself" \
    || fail "the firmware says so" "a claim the output does not make is a claim nobody can check"

# Nothing may write the key or the window to flash. Only the record goes.
grep -q 'blocking_write(HELPER_OFFSET, &page)' "$SRC" \
    && pass "exactly one thing is written to flash, and it is the record" \
    || fail "one flash write" "any other write is a place the secret could land"
grep -cq 'blocking_write' "$SRC" && [[ "$(grep -c 'blocking_write' "$SRC")" -eq 1 ]] \
    && pass "and there is only one such write in the whole firmware" \
    || fail "only one flash write exists" "$(grep -c 'blocking_write' "$SRC") found"

# The window itself must never be stored — storing it is storing the key.
grep -q 'window' "$SRC" && ! grep -qE 'blocking_write\(.*window' "$SRC" \
    && pass "the SRAM window is never written to flash — storing it would be storing the key" \
    || fail "the window is never stored" "H XOR w is K"

# --- the two guards, both handed over by exp179 ---------------------------
grep -q 'UNIFORMITY_MIN' "$SRC" && grep -q 'REFUSED to enrol' "$SRC" \
    && pass "enrolment refuses a window outside the power-on band (exp179's 0.00% trap)" \
    || fail "the enrolment guard exists" "H = K XOR 0 = K"
grep -q 'NOT EVIDENCE' "$SRC" && grep -q 'Cause::Fresh' "$SRC" \
    && pass "a reconstruction after a warm reset is labelled as not evidence (exp179 again)" \
    || fail "the warm-reset guard exists" "SRAM survives a reset that keeps the power"

grep -q 'sample_count = 1000' "$SRC" \
    && pass "the TRNG uses exp109's sample count, not the driver's default" \
    || fail "the TRNG sample count" "exp174 lost twenty seconds a credential to the default"

# --- the transcripts ------------------------------------------------------
for f in capture-refused.txt capture-reconstructed.txt; do
    if [[ -f "$f" ]]; then
        echo "      ruling on $f"
        python3 verify.py "$f"
        [[ $? -eq 0 ]] || FAILED=1
    else
        fail "$f is checked in" "the record is incomplete"
    fi
done

# --- the board, if it is here --------------------------------------------
if exp_running 181; then
    pass "a board is running exp181 — pull the cable and it does the whole thing again"
else
    echo "SKIP  the board is not running exp181; the checked-in transcripts stand"
fi

# --- the argument it makes -----------------------------------------------
grep -q 'exp179' README.md 2>/dev/null \
    && pass "the README names exp179, which is what unlocked this" \
    || fail "the README names exp179" "without it there is no window to read"
grep -q 'exp175' README.md 2>/dev/null \
    && pass "the README names exp175, whose gap this closes" \
    || fail "the README names exp175" "the point is a secret the image cannot carry"
grep -q 'exp163' README.md 2>/dev/null \
    && pass "and exp163, which says what this does not fix" \
    || fail "the README names exp163" "the key is still readable while in use"

exit "$FAILED"
