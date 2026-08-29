#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp108 quick check — non-interactive verdict.
# Builds and converts, and if the board is running this firmware, reads the
# port briefly to confirm the sensor is producing a plausible temperature.
# Warming the chip with a finger is a human job, so that lives in run.sh.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # the temperature arrives in the log
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp108-adc-temperature
UF2=target/exp108-adc-temperature.uf2

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

if ! exp_running 108; then
    echo "SKIP  board is not running exp108 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board enumerated as 1209:0001"

PORT="$(exp_serial_port)"
if [[ -z "$PORT" ]]; then
    fail "serial port present" "on USB but no /dev/ttyACM* — check dmesg"
    exit "$FAILED"
fi
pass "serial port present: $PORT"

OUT="$(exp_read_log 5)"

echo "$OUT" | grep -q 'temp: raw [0-9]* of 4095' \
    && pass "temperature sensor is reporting" \
    || fail "temperature sensor is reporting" "no 'temp: raw' lines in 5 s"

# Both halves get checked separately, because they fail for different reasons.
# A bad raw count means the ADC or the channel is wrong; a bad temperature
# with a good raw count means the arithmetic is. Checking only the pretty
# number would let a broken conversion pass whenever the sensor happened to
# read something reasonable.
RAW="$(echo "$OUT" | grep -o 'temp: raw [0-9]*' | grep -o '[0-9]*' | tail -1)"
if [[ -n "$RAW" ]] && (( RAW > 400 && RAW < 1400 )); then
    pass "raw count is plausible ($RAW)"
else
    fail "raw count is plausible" "got '$RAW' — outside 400..1400, so the ADC or the channel is wrong"
fi

C="$(echo "$OUT" | grep -o '\-\?[0-9]*\.[0-9]* C' | grep -o '^-\?[0-9]*' | tail -1)"
if [[ -n "$C" ]] && (( C > 0 && C < 90 )); then
    pass "converted temperature is plausible ($C C)"
else
    fail "converted temperature is plausible" "got '$C C' — outside 0..90, so the conversion is wrong"
fi

exit "$FAILED"
