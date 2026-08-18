#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp154 quick check — non-interactive verdict.
# Builds and converts, and if the board is running this firmware, confirms the
# survey ran and reported totals. What the totals ARE is the experiment's
# finding and belongs in the README, not in an assertion here: a check that
# demanded a particular number would be checking this board rather than
# checking that the question was asked.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # the board prints the survey; nothing here needs a hand on it
presence_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp154-somewhere-to-put-a-key
UF2=target/exp154-somewhere-to-put-a-key.uf2

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

if cargo build --release --quiet 2>/dev/null && [[ -f "$ELF" ]]; then
    pass "firmware compiles ($(stat -c%s "$ELF") byte ELF)"
else
    fail "firmware compiles" "run: cargo build --release"
    exit 1
fi

if elf2flash convert -b rp2350 "$ELF" "$UF2" > /dev/null 2>&1 && [[ -f "$UF2" ]]; then
    pass "converts to UF2 ($(stat -c%s "$UF2") bytes)"
else
    fail "converts to UF2" "run: elf2flash convert -b rp2350 $ELF $UF2"
    exit 1
fi
FAMILY="$(od -An -tx4 -j28 -N4 "$UF2" | tr -d ' ')"
[[ "$FAMILY" == "e48bff59" ]] \
    && pass "UF2 family ID is e48bff59 (rp2350-arm-s)" \
    || fail "UF2 family ID is e48bff59 (rp2350-arm-s)" "got: $FAMILY"

# This experiment writes nothing to OTP, and that is a property worth checking
# rather than intending: OTP is permanent, so a write introduced by accident
# does not fail a test, it ruins somebody's board. The HAL's write functions
# are named, so their absence is greppable.
if grep -qE 'write_(raw|ecc)_word|otp_access' src/main.rs; then
    fail "the firmware calls no OTP write function" "src/main.rs references a write path"
else
    pass "the firmware calls no OTP write function"
fi

if ! exp_running 154; then
    echo "SKIP  board is not running exp154 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board enumerated as 1209:0001"

# The survey starts three seconds after boot and prints once. Reading for
# twelve seconds catches it from a cold boot and, when attached later, still
# catches the heartbeat that proves the board is alive.
OUT="$(exp_read_log 12)"

if echo "$OUT" | grep -q 'totals:'; then
    pass "the survey completed and reported totals"
    echo "      $(echo "$OUT" | grep -o 'totals:.*' | tail -1)"
    echo "      $(echo "$OUT" | grep -oE 'no row refused.*|[0-9]+ rows refused.*' | tail -1)"
elif echo "$OUT" | grep -q 'heartbeat'; then
    echo "SKIP  attached after the survey printed — it runs once, three seconds after boot"
else
    fail "the survey reported totals" "no 'totals:' line and no heartbeat in 12 s"
fi

exit "$FAILED"
