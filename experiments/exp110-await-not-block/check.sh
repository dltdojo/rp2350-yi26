#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp110 quick check — non-interactive verdict.
# Builds both configurations and, if the board is running the awaiting build,
# confirms the executor is not being starved.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # both builds report their numbers over the log
presence_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp110-await-not-block
UF2=target/exp110-await.uf2

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

# Both builds must compile. The blocking one is the experiment, not a
# curiosity, and a configuration nobody builds quietly stops working.
if cargo build --release --quiet --features blocking 2>/dev/null; then
    pass "blocking configuration compiles"
else
    fail "blocking configuration compiles" "cargo build --release --features blocking"
fi

if cargo build --release --quiet 2>/dev/null && [[ -f "$ELF" ]]; then
    pass "awaiting configuration compiles ($(stat -c%s "$ELF") byte ELF)"
else
    fail "awaiting configuration compiles" "run: cargo build --release"
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

if ! exp_running 110; then
    echo "SKIP  board is not running exp110 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board enumerated as 1209:0001"

OUT="$(exp_read_log 8)"

echo "$OUT" | grep -q 'entropy: 4096 bytes' \
    && pass "entropy task is requesting" \
    || fail "entropy task is requesting" "no 'entropy:' lines in 8 s"

echo "$OUT" | grep -q 'probe: ' \
    && pass "lateness probe is reporting" \
    || fail "lateness probe is reporting" "no 'probe:' lines"

# Which build is on the board decides what "correct" means, so read it from
# the firmware's own banner rather than guessing. Asserting a threshold
# against the wrong build would be a check that fails for being right.
if echo "$OUT" | grep -q 'built to BLOCK'; then
    echo "NOTE  the blocking build is flashed — that is the demonstration, not a fault"
    WORST="$(echo "$OUT" | grep -o 'worst lateness [0-9]*' | grep -o '[0-9]*' | sort -n | tail -1)"
    if [[ -n "$WORST" ]] && (( WORST > 100000 )); then
        pass "blocking build starves the executor as advertised ($((WORST / 1000)) ms)"
    else
        fail "blocking build starves the executor" "worst lateness only ${WORST} us — expected the stall to show"
    fi
else
    WORST="$(echo "$OUT" | grep -o 'worst lateness [0-9]*' | grep -o '[0-9]*' | sort -n | tail -1)"
    if [[ -n "$WORST" ]] && (( WORST < 50000 )); then
        pass "awaiting build keeps the executor responsive (worst ${WORST} us)"
    else
        fail "awaiting build keeps the executor responsive" "worst lateness ${WORST} us — something is blocking"
    fi
fi

exit "$FAILED"
