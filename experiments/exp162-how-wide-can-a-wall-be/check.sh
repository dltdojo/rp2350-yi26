#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp162 quick check — non-interactive.
#
# The board walks fifteen candidates, one per boot, and ends holding fifteen
# one-bit readings and the arrangement they imply. This asserts the three
# controls, asserts that exactly one arrangement survives, and then hands the
# log to verify.py, which derives the same conclusion from the address
# arithmetic in another language and disagrees out loud if it gets a different
# one.
#
# Twelve of the fifteen candidates are MEASUREMENTS and are not graded here.
# Grading them would mean asserting the answer the experiment was written to
# find, and a run that can only report success has not reported anything.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # flash it and read the log; nothing here needs a hand on the board
presence_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp162-how-wide-can-a-wall-be
UF2=target/exp162.uf2

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

CODE="$(grep -vE '^\s*(///|//!|//)' src/main.rs)"

# ACCESSCTRL.LOCK makes a configuration permanent until a power cycle, and it
# cannot be undone by software. This experiment shuts eight banks in fifteen
# different combinations and must leave every one of them recoverable.
# Matched on the accessor rather than on the word: "block" contains "lock", and
# the verdict this firmware prints is full of blocks.
if grep -qE '\.lock\s*\(' <<< "$CODE"; then
    fail "the firmware never writes ACCESSCTRL.LOCK" "found a call to .lock() in code"
else
    pass "the firmware never writes ACCESSCTRL.LOCK"
fi

# Nothing here is permanent in the other direction either.
if grep -qE '\b(otp|flash)\s*\.\s*(write|program)|write_ecc|erase' <<< "$CODE"; then
    fail "the firmware writes nothing permanent" "found a flash or OTP write"
else
    pass "the firmware writes nothing permanent (no flash, no OTP)"
fi

# The shape the whole run depends on: core 1's stack and the mailbox are in bank
# 8, not in the main SRAM the candidates take away. If either were a plain
# `static` the linker would put it in banks 0-7 and candidate 15 would report a
# refusal it had caused.
if grep -q 'const MAILBOX: usize = BANK8 + CORE1_STACK_BYTES;' <<< "$CODE" \
   && grep -q 'BANK8 as \*mut Stack<CORE1_STACK_BYTES>' <<< "$CODE"; then
    pass "core 1's stack and the mailbox are both in bank 8"
else
    fail "core 1's stack and the mailbox are both in bank 8" \
         "a static in the main SRAM makes candidate 15 measure this firmware"
fi

# exp156's lesson, enforced rather than intended: every bank is put into a known
# state on every candidate, so that a refusal is never a power-on default
# wearing this experiment's name.
if grep -q 'bank_non_secure(bank, shut & (1 << bank) == 0);' <<< "$CODE"; then
    pass "every candidate opens all eight banks before shutting any"
else
    fail "every candidate opens all eight banks before shutting any" \
         "a wall you did not build is not a wall you measured"
fi

# Twelve of fifteen probes must carry no expected outcome.
MEASURED="$(grep -c 'expect: MEASURE' <<< "$CODE")"
[[ "$MEASURED" == "12" ]] \
    && pass "twelve of the fifteen candidates are ungraded measurements" \
    || fail "twelve of the fifteen candidates are ungraded measurements" "found $MEASURED"

grep -q 'assert!(' src/main.rs && grep -q 'PRODUCT.len()' src/main.rs \
    && pass "the product string is bounded at build time" \
    || fail "the product string is bounded at build time" "it can overflow the control buffer"

if [[ "$(grep -n 'spawner.spawn(heartbeat' <<< "$CODE" | cut -d: -f1)" \
      -lt "$(grep -n 'Driver::new' <<< "$CODE" | cut -d: -f1)" ]]; then
    pass "the LED heartbeat starts before the USB stack"
else
    fail "the LED heartbeat starts before the USB stack" "a board that dies in USB init is dark"
fi

grep -q 'breadcrumb::disarm();' <<< "$CODE" \
    && pass "the run has a hard stop that disarms" \
    || fail "the run has a hard stop that disarms" "the watchdog would keep rebooting"

# verify.py's own precondition: the fifteen probes must tell all thirteen
# arrangements apart. If two collided, a single surviving arrangement would not
# mean the map had been identified, and verify.py says BAD before looking at any
# reading. Running it on nothing exercises exactly that path.
COLLIDE="$(printf '' | python3 ./verify.py 2>&1 | tail -1)"
[[ "$COLLIDE" != "BAD" ]] \
    && pass "the fifteen probes tell all thirteen arrangements apart" \
    || fail "the fifteen probes tell all thirteen arrangements apart" \
            "two maps predict the same run; a verdict would be a guess"

if [[ -f capture.txt ]]; then
    REPLAY="$(python3 ./verify.py < capture.txt 2>&1 | tail -1)"
    [[ "$REPLAY" == "OK" ]] \
        && pass "verify.py replays the recorded capture" \
        || fail "verify.py replays the recorded capture" "got: $REPLAY"

    # A check that cannot fail has not passed. Flip one reading in the recorded
    # capture and require verify.py to stop agreeing — and assert first that the
    # flip changed the file, because exp160 shipped a corruption test that
    # corrupted nothing and read as a pass for it.
    CORRUPT="$(sed '0,/3 bank 0 SHUT, read 0x20010000 - DENIED/s//3 bank 0 SHUT, read 0x20010000 - allowed/' capture.txt)"
    if [[ "$CORRUPT" == "$(cat capture.txt)" ]]; then
        fail "the corrupted-capture test actually corrupts something" \
             "the line it edits is not in capture.txt, so the guard below is empty"
    else
        pass "the corrupted-capture test actually corrupts something"
    fi
    BROKEN="$(printf '%s\n' "$CORRUPT" | python3 ./verify.py 2>&1 | tail -1)"
    [[ "$BROKEN" != "OK" ]] \
        && pass "verify.py rejects a capture with one reading flipped (got $BROKEN)" \
        || fail "verify.py rejects a capture with one reading flipped" "it still said OK"
else
    fail "a recorded capture is checked in" "capture.txt is missing; verify.py is unreplayed"
fi

if ! exp_running 162; then
    echo "SKIP  board is not running exp162 — flash it (not an error)"
    exit "$FAILED"
fi
pass "board enumerated as 1209:0001"

# Wait for the matrix. Fifteen boots at roughly eleven seconds each, and the
# port disappears between every pair of them, so exp_read_log returns early and
# a bare retry loop spins through in seconds on a healthy board.
OUT=""
for _ in $(seq 40); do
    OUT="$(exp_read_log 15 2>/dev/null)"
    grep -q 'VERDICT' <<< "$OUT" && break
    sleep 3
done

# Assert on the final report block, not on the whole window: every boot opens by
# printing the matrix as it stood when that boot started, so "not reached"
# appears legitimately in the early ones.
FINAL="$(sed -n '/exp162 done/,$p' <<< "$OUT")"

grep -q 'not reached' <<< "$FINAL" \
    && fail "every candidate was attempted" "the final report still lists one as not reached" \
    || pass "every candidate was attempted"

grep -q 'KILLED CORE 0' <<< "$FINAL" \
    && fail "no candidate killed the reporting core" "$(grep -o '[0-9]* .* - KILLED CORE 0' <<< "$FINAL" | tail -1)" \
    || pass "no candidate killed the reporting core"

if grep -q 'NOT as expected' <<< "$FINAL"; then
    fail "the three controls behaved as expected" \
         "$(grep -o '[0-9]* [^-]* - .* (NOT as expected)' <<< "$FINAL" | tail -1)"
else
    pass "the three controls behaved as expected"
fi

# Named separately, because without them a refusal is one failed access.
grep -q '1 nothing shut, read 0x20000000 - allowed' <<< "$FINAL" \
    && pass "control: a demoted core reads the main SRAM when nothing is shut" \
    || fail "control: a demoted core reads the main SRAM when nothing is shut" \
            "nothing below means anything without it"

grep -q '2 bank 0 SHUT, read 0x20000000 - DENIED' <<< "$FINAL" \
    && pass "control: the same read is refused once this firmware shuts bank 0" \
    || fail "control: the same read is refused once this firmware shuts bank 0" \
            "the wall was not built by this experiment"

grep -q '15 all eight SHUT, read 0x2007fffc - DENIED' <<< "$FINAL" \
    && pass "control: the eight registers reach the top of the 512 KB" \
    || fail "control: the eight registers reach the top of the 512 KB" \
            "and core 1 answered it from bank 8, which is the layout everything here rests on"

if grep -q 'exactly one arrangement predicts all fifteen readings' <<< "$FINAL"; then
    pass "exactly one arrangement of the eight banks fits the readings"
    echo "      $(grep -o 'banks 0-7 are .*' <<< "$FINAL" | tail -1)"
else
    fail "exactly one arrangement of the eight banks fits the readings" \
         "$(grep -o 'VERDICT.*' <<< "$FINAL" | tail -1)"
fi

# And now the half the board should not be trusted to do alone.
VERIFY="$(python3 ./verify.py <<< "$OUT" 2>&1 | tail -1)"
case "$VERIFY" in
    OK)         pass "the readings imply the board's verdict, derived off the board" ;;
    BAD)        fail "the readings imply the board's verdict" "a control did not hold" ;;
    NOFIT)      fail "the readings imply the board's verdict" \
                     "off the board, no single arrangement fits — the board named one anyway" ;;
    DISAGREE)   fail "the readings imply the board's verdict" \
                     "the board and verify.py named different arrangements" ;;
    INCOMPLETE) fail "the capture holds all fifteen readings" \
                     "the window may be too short; the run takes about three minutes" ;;
    *)          fail "off-board verification ran" "unexpected result: $VERIFY" ;;
esac

exit "$FAILED"
