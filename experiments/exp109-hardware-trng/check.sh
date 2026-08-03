#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp109 quick check — non-interactive verdict.
# Builds both configurations and, if the board is running this firmware,
# confirms the TRNG is producing bytes at the measured cost.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # the timings arrive in the log
presence_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp109-hardware-trng
UF2=target/exp109-hardware-trng.uf2

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

# The slow configuration has to keep compiling too. It is documented in the
# README as something to try, and a feature nobody builds is a feature that
# quietly stops working.
if cargo build --release --quiet --features upstream-default 2>/dev/null; then
    pass "upstream-default configuration also compiles"
else
    fail "upstream-default configuration also compiles" "cargo build --release --features upstream-default"
fi
# Leave the default build in place for the conversion below.
cargo build --release --quiet 2>/dev/null

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

if ! exp_running 109; then
    echo "SKIP  board is not running exp109 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board enumerated as 1209:0001"

PORT="$(exp_serial_port)"
if [[ -z "$PORT" ]]; then
    fail "serial port present" "on USB but no /dev/ttyACM* — check dmesg"
    exit "$FAILED"
fi
pass "serial port present: $PORT"

OUT="$(exp_read_log 8)"

echo "$OUT" | grep -q 'trng: ' \
    && pass "TRNG is producing bytes" \
    || fail "TRNG is producing bytes" "no 'trng:' lines in 8 s"

echo "$OUT" | grep -q 'heartbeat #' \
    && pass "heartbeat is running" \
    || fail "heartbeat is running" "no heartbeats — the firmware, not the TRNG"

# Several rounds in eight seconds is the actual verdict on the configuration.
# One round would also appear at the upstream default; four would not.
ROUNDS="$(echo "$OUT" | grep -c 'trng: ' || true)"
if (( ROUNDS >= 4 )); then
    pass "TRNG answered $ROUNDS times in 8 s (a slow sample_count would not)"
else
    fail "TRNG answered enough times" "only $ROUNDS round(s) in 8 s — check TRNG_SAMPLE_COUNT"
fi

# The bytes must not be constant. A TRNG that has stopped and is handing back
# a stale register reads as perfectly valid hex, so this is worth checking:
# it is the cheapest possible liveness test on the entropy itself.
UNIQUE="$(echo "$OUT" | grep -o 'trng: .*' | sort -u | wc -l)"
if (( UNIQUE >= 2 )); then
    pass "successive reads differ ($UNIQUE distinct lines)"
else
    fail "successive reads differ" "every read returned the same bytes — the TRNG is stuck"
fi

# The cost line is the point of the experiment; if it stops being printed the
# experiment has quietly become "call a function".
echo "$OUT" | grep -q 'cost: [0-9]* us' \
    && pass "cost of each request is reported" \
    || fail "cost of each request is reported" "no 'cost:' lines"

exit "$FAILED"
