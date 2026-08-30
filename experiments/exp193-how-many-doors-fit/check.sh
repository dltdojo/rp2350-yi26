#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
#
# exp193 quick check — non-interactive, and it needs nobody.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed
#
# The live half is ./drop.sh, which walks towards the descriptor wall and writes
# capture.txt. This rules on that capture and on the things about the firmware
# that can be read out of the source.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1
LIFELINE=yes
presence_check
lifeline_check

USB_IFACE="cdc+hid"
USB_CARRIES="log"
USB_HOST="cdc_acm+hidraw"
USB_RUNS_ON="own"
usb_check

command -v python3 > /dev/null && pass "python3 present" \
    || { fail "python3 present" "needed to rule on the capture"; exit 1; }

TARGET=thumbv8m.main-none-eabihf
SRC=src/main.rs

# Three steps, not thirteen: 0 is the control, 1 is the shape twenty
# experiments here use, and a middle one is where the walk actually lives.
# drop.sh builds all of them; this is only asking whether the knob works.
if command -v cargo > /dev/null; then
    for n in 0 1 4; do
        if EXP193_HID="$n" cargo build --release --quiet 2> /dev/null; then
            pass "the hid $n shape compiles"
        else
            fail "the hid $n shape compiles" "EXP193_HID=$n cargo build --release"
        fi
    done
    if EXP193_HID=99 cargo build --release --quiet > /dev/null 2>&1; then
        fail "build.rs refuses a shape past its ceiling" "EXP193_HID=99 built anyway"
    else
        pass "build.rs refuses a shape past its ceiling"
    fi
else
    echo "SKIP  no toolchain — see exp102"
fi

# --- the shape of the firmware, read out of it ------------------------------
#
# The same two orderings exp190 asserts, for the same reasons: a peripheral
# reset before `lifeline::begin` destroys the note the escape reads, and a board
# that hangs before its LED is up is indistinguishable from one that never
# started. Comment lines are excluded — prose about a call is not the call.
BEGIN_AT="$(grep -n 'lifeline::begin' "$SRC" | grep -v ':[[:space:]]*//' | head -1 | cut -d: -f1)"
INIT_AT="$(grep -n 'embassy_rp::init' "$SRC" | grep -v ':[[:space:]]*//' | head -1 | cut -d: -f1)"
if [[ -n "$BEGIN_AT" && -n "$INIT_AT" && "$BEGIN_AT" -lt "$INIT_AT" ]]; then
    pass "lifeline::begin runs before embassy_rp::init (line $BEGIN_AT before $INIT_AT)"
else
    fail "lifeline::begin runs first" "a peripheral reset before it destroys the note the escape reads"
fi

LED_AT="$(grep -n 'spawner.spawn(lifeline::led' "$SRC" | grep -v ':[[:space:]]*//' | head -1 | cut -d: -f1)"
USB_AT="$(grep -n 'cdc_console::open_composite' "$SRC" | grep -v ':[[:space:]]*//' | head -1 | cut -d: -f1)"
if [[ -n "$LED_AT" && -n "$USB_AT" && "$LED_AT" -lt "$USB_AT" ]]; then
    pass "the LED is up before the USB stack, so dark and died are different signals"
else
    fail "the LED is up before the USB stack" "exp156 spent two board recoveries on this"
fi

# The whole reason this experiment exists: it is the first caller of the
# composite path, and a firmware that reached for `open` instead would be
# measuring nothing.
grep -q 'cdc_console::open_composite' "$SRC" \
    && pass "it uses the composite path — the builder comes back and interfaces are added" \
    || fail "it uses cdc_console::open_composite" "the CDC-only path measures no wall"

grep -q 'panic-halt' Cargo.toml \
    && fail "no panic-halt" "the step past the wall panics, and halting there is a walk to a bench" \
    || pass "no panic-halt — lifeline's handler reboots instead"

# --- the capture, if there is one -------------------------------------------
if [[ -f capture.txt ]]; then
    echo "      ruling on capture.txt"
    python3 verify.py capture.txt
    [[ $? -eq 0 ]] || FAILED=1
else
    fail "capture.txt exists" "run ./drop.sh — it needs a board and nobody"
fi

for e in exp140 exp156 exp190; do
    grep -q "$e" README.md 2>/dev/null \
        && pass "the README names $e" \
        || fail "the README names $e" "this experiment stands on $e"
done

exit "$FAILED"
