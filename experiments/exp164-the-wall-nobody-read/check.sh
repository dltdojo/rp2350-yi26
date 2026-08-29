#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp164 quick check — non-interactive.
#
# Six candidates, one per boot. This asserts the shape that makes the readings
# trustworthy — above all that the firmware never *writes* the unit it is
# describing — and then hands the log to verify.py, which derives the map from
# the region descriptors instead of believing the map the board printed.
#
# What is deliberately NOT asserted is any particular attribution. The map is
# the thing the experiment was written to find out, and a check that demands a
# particular answer to an open question is not a check.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # flash it and read the log; nothing here needs a hand on the board
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp164-the-wall-nobody-read
UF2=target/exp164.uf2

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

# **The guard the whole experiment rests on.** This describes the SAU; it must
# not configure it. The only write it is allowed is SAU_RNR, which selects
# which region the next read returns and changes no attribution. A write to
# CTRL, RBAR or RLAR would repartition the address space this firmware is
# running out of, and every reading afterwards would be about a chip this
# experiment had already changed.
if grep -qE 'sau_write\((SAU_CTRL|SAU_RBAR|SAU_RLAR|SFSR|SFAR)' <<< "$CODE"; then
    fail "the firmware never writes the SAU except RNR" \
         "$(grep -oE 'sau_write\((SAU_CTRL|SAU_RBAR|SAU_RLAR|SFSR|SFAR)[^)]*\)' <<< "$CODE" | head -1)"
else
    pass "the firmware never writes the SAU except RNR (which selects, not configures)"
fi
# Calls only: the definition of `sau_write` itself starts at column 0, every
# call is indented, and counting the definition as a write cost this check a
# false failure the first time it ran.
WRITES="$(grep -cE '^\s+sau_write\(' <<< "$CODE")"
RNR_WRITES="$(grep -cE '^\s+sau_write\(SAU_RNR' <<< "$CODE")"
[[ "$WRITES" == "$RNR_WRITES" && "$WRITES" -gt 0 ]] \
    && pass "all $WRITES sau_write calls target RNR and nothing else" \
    || fail "all sau_write calls target RNR" "$WRITES writes, $RNR_WRITES of them to RNR"

if grep -qE '\.lock\s*\(' <<< "$CODE"; then
    fail "the firmware never writes ACCESSCTRL.LOCK" "found a call to .lock() in code"
else
    pass "the firmware never writes ACCESSCTRL.LOCK"
fi

if grep -qE '\b(otp|flash)\s*\.\s*(write|program)|write_ecc|erase' <<< "$CODE"; then
    fail "the firmware writes nothing permanent" "found a flash or OTP write"
else
    pass "the firmware writes nothing permanent (no flash, no OTP)"
fi

# An address typed into a constant is a number; an address the architecture
# crate publishes is the SAU. Candidate 1 compares them on the board and refuses
# to pass if they differ.
if grep -q 'SAU == cortex_m::peripheral::SAU::PTR as usize' <<< "$CODE" \
   && grep -q 'agrees && sregion() > 0' <<< "$CODE"; then
    pass "the base address is checked against cortex-m's SAU::PTR, on the board"
else
    fail "the base address is checked against cortex-m's SAU::PTR" \
         "then every register value below is a number from an address somebody typed"
fi

# Candidate 3 is graded on whether the instrument ran, never on what it found.
if grep -q 'answered == MAP.len()' <<< "$CODE" \
   && ! grep -qE 'secure\(\)\s*==|ns_readable\(\)\s*==' <<< "$CODE"; then
    pass "the map is graded on TT having executed, not on what it said"
else
    fail "the map is graded on TT having executed" \
         "an expected attribution in the matrix is an answer the run cannot contradict"
fi

# Candidate 5's control is the refusal. Without it the SAU values below could
# be a core that was never demoted.
if grep -q 'up && faulted && !done' <<< "$CODE"; then
    pass "candidate 5 is graded on the refusal, and the SAU values are measured"
else
    fail "candidate 5 is graded on the refusal" \
         "grading it on the SAU values would be asserting the finding"
fi

# Order matters: the reading has to be safely stored before the access that is
# designed to kill the core making it.
RD="$(grep -n 'CORE1_READ_DONE.store' <<< "$CODE" | head -1 | cut -d: -f1)"
B8="$(grep -n 'read_volatile(BANK8 as \*const u32)' <<< "$CODE" | head -1 | cut -d: -f1)"
if [[ -n "$RD" && -n "$B8" && "$RD" -lt "$B8" ]]; then
    pass "core 1 stores its reading before the access meant to fault it"
else
    fail "core 1 stores its reading before the access meant to fault it" \
         "otherwise a fault erases the measurement it was supposed to protect"
fi

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

if [[ -f capture.txt ]]; then
    REPLAY="$(python3 ./verify.py < capture.txt 2>&1 | tail -1)"
    [[ "$REPLAY" == "OK" ]] \
        && pass "verify.py replays the recorded capture" \
        || fail "verify.py replays the recorded capture" "got: $REPLAY"

    # A check that cannot fail has not passed. Make one address in the map
    # claim to be Secure and Non-secure-readable at once — a contradiction
    # whatever the attribution rules are — and require verify.py to say so.
    CORRUPT="$(sed '0,/S=yes nsr=no /s//S=yes nsr=yes/' capture.txt)"
    if [[ "$CORRUPT" == "$(cat capture.txt)" ]]; then
        fail "the corrupted-capture test actually corrupts something" \
             "the line it edits is not in capture.txt, so the guard below is empty"
    else
        pass "the corrupted-capture test actually corrupts something"
    fi
    BROKEN="$(printf '%s\n' "$CORRUPT" | python3 ./verify.py 2>&1 | tail -1)"
    [[ "$BROKEN" != "OK" ]] \
        && pass "verify.py rejects a map that contradicts itself (got $BROKEN)" \
        || fail "verify.py rejects a map that contradicts itself" "it still said OK"
else
    fail "a recorded capture is checked in" "capture.txt is missing; verify.py is unreplayed"
fi

if ! exp_running 164; then
    echo "SKIP  board is not running exp164 — flash it (not an error)"
    exit "$FAILED"
fi
pass "board enumerated as 1209:0001"

OUT=""
for _ in $(seq 40); do
    OUT="$(exp_read_log 15 2>/dev/null)"
    grep -q 'VERDICT' <<< "$OUT" && break
    sleep 3
done

# Timestamps stripped: every assertion below is about what the line says.
FINAL="$(sed -n '/exp164 done/,$p' <<< "$OUT" | sed 's/^\[[^]]*\] //')"

grep -q 'not reached' <<< "$FINAL" \
    && fail "every candidate was attempted" "the final report still lists one as not reached" \
    || pass "every candidate was attempted"

grep -q 'KILLED CORE 0' <<< "$FINAL" \
    && fail "no candidate died unexpectedly" "$(grep -o '[0-9] .* - KILLED CORE 0' <<< "$FINAL" | tail -1)" \
    || pass "no candidate died unexpectedly"

grep -q 'NOT as expected' <<< "$FINAL" \
    && fail "all six candidates behaved as expected" \
            "$(grep -o '[0-9] [^-]* - NOT as expected' <<< "$FINAL" | tail -1)" \
    || pass "all six candidates behaved as expected"

grep -qE '^\s*6 .* - as expected: the launch never returned' <<< "$FINAL" \
    && pass "candidate 6: demoting before the launch leaves spawn_core1 waiting" \
    || fail "candidate 6: demoting before the launch leaves spawn_core1 waiting" \
            "$(grep -oE '^\s*6 .*' <<< "$FINAL" | tail -1)"

grep -qE 'demoted after : read=1 fault=1' <<< "$FINAL" \
    && pass "control: the demoted core read the SAU and was then refused by ACCESSCTRL" \
    || fail "control: the demoted core read the SAU and was then refused" \
            "$(grep -oE 'demoted after.*' <<< "$FINAL" | tail -1)"

CORE01="$(grep -oE 'TT core1=(0x[0-9a-f]+) core0=(0x[0-9a-f]+)' <<< "$FINAL" | head -1)"
[[ -n "$CORE01" ]] \
    && pass "the two cores' TT responses are both in the report ($CORE01)" \
    || fail "the two cores' TT responses are both in the report" "no TT pair in the final block"

VERIFY="$(python3 ./verify.py <<< "$OUT" 2>&1 | tail -1)"
case "$VERIFY" in
    OK)         pass "the map follows the region descriptors, derived off the board" ;;
    BAD)        fail "the map follows the region descriptors" "a control did not hold" ;;
    DISAGREE)   fail "the map follows the region descriptors" \
                     "the printed map and the eight regions say different things" ;;
    INCOMPLETE) fail "the window holds the whole final report" \
                     "the window may be too short" ;;
    *)          fail "off-board verification ran" "unexpected result: $VERIFY" ;;
esac

exit "$FAILED"
