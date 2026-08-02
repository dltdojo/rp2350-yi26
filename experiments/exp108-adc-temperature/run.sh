#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp108 interactive walkthrough — read the chip's own temperature sensor,
# then warm the chip and watch the number follow.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp108-adc-temperature
UF2=target/exp108-adc-temperature.uf2

BASELINE_S=6
WARM_S=15

echo "${BOLD}exp108 — the chip takes its own temperature${RESET}"
say ""
say "Every number logged so far was one the firmware worked out. This one is"
say "measured: an analogue voltage inside the chip, converted to degrees by"
say "three lines of arithmetic out of the datasheet."
say ""
say "Nothing to wire. The sensor is on ADC channel 4, already there."

# ---------------------------------------------------------------------------
step 1 "Build and convert"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
ok "UF2 ready ($(stat -c%s "$UF2") bytes)."

# ---------------------------------------------------------------------------
step 2 "Flash it"
say "The board can still reboot itself, so this needs no button."
run_cmd yi26 flash "$UF2"
PORT="$(exp_serial_port)"
ok "Running, serial port at $PORT"

# ---------------------------------------------------------------------------
step 3 "A baseline"
say ""
say "Reading for ${BASELINE_S} seconds with the board left alone. Each line has"
say "both numbers: the raw count the hardware gave, and your arithmetic on"
say "top of it."
say ""
BASE="$(exp_read_log "$BASELINE_S")"
echo "$BASE" | sed 's/^/    /'
echo

BASE_C="$(echo "$BASE" | grep -o '[0-9]*\.[0-9]* C' | grep -o '^[0-9]*' | tail -1)"
if [[ -n "$BASE_C" ]]; then
    ok "Sitting around ${BOLD}${BASE_C} °C${RESET}."
    say "  That is the chip, not the room. A Pico 2 doing almost nothing still"
    say "  runs well above ambient."
fi

# ---------------------------------------------------------------------------
step 4 "Now warm it"
say ""
say "${BOLD}Pinch the chip${RESET} — the black square in the middle of the board — between"
say "finger and thumb, and hold it there. Not the USB connector, not the"
say "board edge: the chip itself."
say ""
say "Reading for ${WARM_S} seconds starting now."
say ""

WARM="$(exp_read_log "$WARM_S")"
echo "$WARM" | sed 's/^/    /'
echo

WARM_C="$(echo "$WARM" | grep -o '[0-9]*\.[0-9]* C' | grep -o '^[0-9]*' | tail -1)"
if [[ -n "$BASE_C" && -n "$WARM_C" ]]; then
    if (( WARM_C > BASE_C )); then
        ok "Rose from ${BASE_C} °C to ${WARM_C} °C."
        say "  You have now checked this sensor against the only reference you"
        say "  need: something you know is warm."
    else
        say "${YELLOW}Ended at ${WARM_C} °C, not above ${BASE_C} °C.${RESET}"
        say "  If you did not touch the chip, that is expected. If you did, try"
        say "  again and hold longer — the package takes a few seconds."
    fi
fi

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp108 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. The hardware gives you a count, not a temperature. The meaning is"
say "     arithmetic you supply, and the datasheet supplies the constants."
say "  2. Those constants are typical values, not a calibration of your chip."
say "     Trust the change, not the absolute number — which is what step 4"
say "     actually tested."
say "  3. The reading is never perfectly still. An analogue measurement is a"
say "     number with noise on it, always."
say ""
say "Next: ${BOLD}exp109${RESET} reads the other on-chip source of numbers you did not"
say "compute — the hardware random number generator — which turns out to be a"
say "much less well-behaved peripheral than this one."
