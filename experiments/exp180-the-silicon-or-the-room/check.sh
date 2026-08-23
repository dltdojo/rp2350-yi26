#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp180 quick check — non-interactive.
#
# Two of this experiment's three findings need no temperature at all and are
# checked from the transcripts. The third needs the board to start from room
# temperature, which needs somebody to unplug it and leave it alone — the one
# thing here no software can arrange.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

# One action by a person: the cable out, a wait, the cable in. The board does
# the rest, including telling anybody watching what it wants via the LED.
PRESENCE=2
presence_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

command -v python3 > /dev/null && pass "python3 present" \
    || { fail "python3 present" "needed to rule on the transcripts"; exit 1; }

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp180-the-silicon-or-the-room
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

# --- the instrument, where getting it wrong is the whole subject ---------
grep -q 'const SRC_ROSC: u32 = 0x03' "$SRC" && grep -q 'const SRC_LPOSC: u32 = 0x0e' "$SRC" \
    && pass "the FC0 sources are the RP2350's numbers, named rather than written inline" \
    || fail "the FC0 source constants" "the RP2040 numbers them differently; 0x07 here is a GPIO"

grep -q 'const INTERVAL_LONG: u8 = 15' "$SRC" \
    && pass "every real measurement uses the long window" \
    || fail "INTERVAL_LONG is 15" "at interval 8 this experiment measured its own resolution"

# The short interval survives for exactly one purpose.
SHORT_USES="$(grep -c 'INTERVAL_SHORT' "$SRC")"
[[ "$SHORT_USES" -le 4 ]] \
    && pass "the earlier work's interval is kept only to reproduce its reading ($SHORT_USES mentions)" \
    || fail "INTERVAL_SHORT is only a demonstration" "$SHORT_USES mentions is too many to be one"

grep -q 'fn range_table' "$SRC" && grep -q 'set_freq_range' "$SRC" \
    && pass "it sweeps FREQ_RANGE, which is the finding that needs no temperature" \
    || fail "the range table is present" "one register field is the comparison"
grep -q 'stock_range' "$SRC" \
    && pass "and puts the range back the way it found it" \
    || fail "the stock range is restored" "leaving a board reconfigured is not a measurement"

# The LED is the instrument for the person, and exp171 is why.
grep -q 'LED_HOLD' "$SRC" && grep -q 'LED_RELEASE' "$SRC" \
    && pass "the LED has states, so nobody has to count seconds (exp171's lesson)" \
    || fail "the LED signals the window" "asking a person to time something puts their reflex in the measurement"

grep -q 'taken before USB came up' "$SRC" \
    && pass "the first reading is taken before the USB stack, which is the only cold moment" \
    || fail "the boot reading comes first" "setting up a serial port spends the one room-temperature sample"

# --- the transcripts ------------------------------------------------------
FOUND=0
for f in capture-self-heating.txt capture-finger.txt capture-cold-start.txt; do
    if [[ -f "$f" ]]; then
        FOUND=$((FOUND + 1))
        echo "      ruling on $f"
        python3 verify.py "$f"
        [[ $? -eq 0 ]] || FAILED=1
    fi
done
[[ "$FOUND" -ge 2 ]] \
    && pass "at least the two transcripts that need no temperature are checked in" \
    || fail "the transcripts are checked in" "found $FOUND"

if [[ -f capture-cold-start.txt ]]; then
    pass "the cold-start transcript is here — the temperature half has a number"
else
    echo "SKIP  no cold-start transcript yet: unplug the board, leave it until it is at room"
    echo "      temperature, plug it back in and read the log. Nothing else in this"
    echo "      experiment is waiting on anything."
fi

# --- the argument it makes -----------------------------------------------
grep -q 'identity road' README.md 2>/dev/null \
    && pass "the README says which road this is on" \
    || fail "the README names the identity road" "this is that road's second rung"
grep -q '65.7' README.md 2>/dev/null && grep -q '13.34' README.md 2>/dev/null \
    && pass "the README carries both numbers — one register field against three boards" \
    || fail "the README carries both numbers" "the finding is the comparison, not either alone"

exit "$FAILED"
