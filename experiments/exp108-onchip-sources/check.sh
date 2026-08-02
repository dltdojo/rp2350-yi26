#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp108 quick check — non-interactive verdict.
# Builds and converts, and if the board is running this firmware, reads the
# port briefly to confirm both sources are reporting and both tests are
# running. Nothing here needs a human: this is the first experiment whose
# whole result is numbers, which is exactly why it could be built and verified
# with nobody in the room.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp108-onchip-sources
UF2=target/exp108-onchip-sources.uf2

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

if [[ "$(yi26 state)" != "running" ]]; then
    echo "SKIP  board running exp108 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board enumerated as 1209:0001"

PORT="$(exp_serial_port)"
if [[ -z "$PORT" ]]; then
    fail "serial port present" "on USB but no /dev/ttyACM* — check dmesg"
    exit "$FAILED"
fi
pass "serial port present: $PORT"

# Long enough for several rounds. Each round is one second plus however long
# the TRNG takes, so ten seconds is comfortably more than the three rounds the
# checks below need.
OUT="$(exp_read_log 10)"

echo "$OUT" | grep -q 'temp: raw [0-9]* of 4095' \
    && pass "temperature sensor is reporting" \
    || fail "temperature sensor is reporting" "no 'temp: raw' lines in 10 s"

echo "$OUT" | grep -q 'trng: ' \
    && pass "TRNG is producing bytes" \
    || fail "TRNG is producing bytes" "no 'trng:' lines in 10 s"

# The temperature must be a plausible number, not just a line that parsed.
# A dead sensor reads 0 and converts to something absurd; catching that here
# means the experiment cannot silently "pass" while measuring nothing.
RAW="$(echo "$OUT" | grep -o 'temp: raw [0-9]*' | grep -o '[0-9]*' | head -1)"
if [[ -n "$RAW" ]] && (( RAW > 400 && RAW < 1400 )); then
    pass "temperature reading is plausible (raw $RAW)"
else
    fail "temperature reading is plausible" "raw '$RAW' is outside 400..1400 — sensor or conversion is wrong"
fi

# Both tests have to be running, on both sources. This is the experiment.
echo "$OUT" | grep -q 'ones  *after' \
    && pass "monobit test is reporting" \
    || fail "monobit test is reporting" "no 'ones after' lines"

echo "$OUT" | grep -q 'changes  *after' \
    && pass "transition test is reporting" \
    || fail "transition test is reporting" "no 'changes after' lines"

# The TRNG should sit near a fair coin on the monobit test. This is a loose
# bound on purpose: it is checking that the hardware is producing entropy at
# all, not certifying its quality — and a tight bound over a handful of
# hundred bits would fail honestly-random data often enough to be useless.
TRNG_PCT="$(echo "$OUT" | grep -o 'ones  *after [0-9]* bits: trng [0-9]*' | grep -o '[0-9]*$' | tail -1)"
if [[ -n "$TRNG_PCT" ]] && (( TRNG_PCT >= 35 && TRNG_PCT <= 65 )); then
    pass "TRNG monobit is near a fair coin ($TRNG_PCT%)"
else
    fail "TRNG monobit is near a fair coin" "got '$TRNG_PCT%' — outside 35..65"
fi

# The heartbeat is the evidence that awaiting the TRNG did not stop the rest
# of the firmware. Its absence would mean something blocked.
echo "$OUT" | grep -q 'heartbeat #' \
    && pass "heartbeat kept running alongside both sources" \
    || fail "heartbeat kept running" "no heartbeats — something is blocking the executor"

exit "$FAILED"
