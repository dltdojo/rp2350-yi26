#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
#
# exp190 quick check — non-interactive, and it needs nobody.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed
#
# The live half is ./drop.sh, which drops four weights on the net and writes
# capture.txt. This rules on that capture, on the policy's own tests, and on the
# things about the firmware that can be read out of the source.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1
LIFELINE=yes
presence_check
lifeline_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

command -v python3 > /dev/null && pass "python3 present" \
    || { fail "python3 present" "needed to rule on the capture"; exit 1; }

# The policy — when a board has stopped coming back — is arithmetic, and runs
# with no board at all.
crate_test ../../crates/lifeline "the give-up rule passes its own tests"

TARGET=thumbv8m.main-none-eabihf
SRC=src/main.rs

if command -v cargo > /dev/null; then
    for arm in never late early hang; do
        if EXP190_DIE="$arm" cargo build --release --quiet 2> /dev/null; then
            pass "the $arm arm compiles"
        else
            fail "the $arm arm compiles" "EXP190_DIE=$arm cargo build --release"
        fi
    done
else
    echo "SKIP  no toolchain — see exp102"
fi

# --- the shape of the firmware, read out of it ------------------------------
#
# `lifeline::begin` must be the first thing in main. Anything that resets a
# peripheral or takes a fault before it destroys the only record of why the last
# boot ended, and the escape reads that record.
# Comment lines excluded: prose about a call is not the call, and the first
# version of this check read the sentence "FIRST, before embassy_rp::init" as
# the call itself and failed a firmware that was correct.
code() { grep -nv '^[[:space:]]*//' "$SRC" | grep -n "$1" | head -1 | cut -d: -f1; }
BEGIN_AT="$(grep -n 'lifeline::begin' "$SRC" | grep -v '^\s*[0-9]*:\s*//' | head -1 | cut -d: -f1)"
INIT_AT="$(grep -n 'embassy_rp::init' "$SRC" | grep -v ':[[:space:]]*//' | head -1 | cut -d: -f1)"
if [[ -n "$BEGIN_AT" && -n "$INIT_AT" && "$BEGIN_AT" -lt "$INIT_AT" ]]; then
    pass "lifeline::begin runs before embassy_rp::init (line $BEGIN_AT before $INIT_AT)"
else
    fail "lifeline::begin runs first" "a peripheral reset before it destroys the note the escape reads"
fi

# The LED comes up before anything that can hang. exp156 paid for this rule and
# exp157 records paying it again.
LED_AT="$(grep -n 'spawner.spawn(lifeline::led' "$SRC" | grep -v ':[[:space:]]*//' | head -1 | cut -d: -f1)"
USB_AT="$(grep -n 'cdc_console::open' "$SRC" | grep -v ':[[:space:]]*//' | head -1 | cut -d: -f1)"
if [[ -n "$LED_AT" && -n "$USB_AT" && "$LED_AT" -lt "$USB_AT" ]]; then
    pass "the LED is up before the USB stack, so dark and died are different signals"
else
    fail "the LED is up before the USB stack" "exp156 spent two board recoveries on this"
fi

grep -q 'panic-halt' Cargo.toml \
    && fail "no panic-halt" "it halts in silence, which reads as a bad cable" \
    || pass "no panic-halt — lifeline's handler reboots instead"

# --- the capture, if there is one -------------------------------------------
if [[ -f capture.txt ]]; then
    echo "      ruling on capture.txt"
    python3 verify.py capture.txt
    [[ $? -eq 0 ]] || FAILED=1
else
    fail "capture.txt exists" "run ./drop.sh — it needs a board and nobody"
fi

for e in exp140 exp156 exp157; do
    grep -q "$e" README.md 2>/dev/null \
        && pass "the README names $e" \
        || fail "the README names $e" "this experiment stands on $e"
done

exit "$FAILED"
