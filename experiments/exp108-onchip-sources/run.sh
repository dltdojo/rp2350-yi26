#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp108 interactive walkthrough — two on-chip sources of numbers, and two
# cheap tests that disagree about one of them.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp108-onchip-sources
UF2=target/exp108-onchip-sources.uf2

# Long enough for the running percentages to stop lurching around. The first
# few rounds swing wildly on 64 bits each, and watching them settle is part of
# the point — a statistic on too little data is not a small truth, it is
# noise wearing a decimal point.
WATCH_S=30

echo "${BOLD}exp108 — two sources, one question${RESET}"
say ""
say "Every number logged so far was one the firmware worked out: a counter, a"
say "timestamp, how late a wakeup was. This one reads two peripherals that"
say "make numbers on their own — the on-chip temperature sensor, and the"
say "hardware random number generator."
say ""
say "Both hand you bits. Only one of them is random, and you cannot tell"
say "which by looking at them. So the firmware also runs two very cheap"
say "statistical tests on both, and prints the scores."

# ---------------------------------------------------------------------------
step 1 "Build and convert"
say "Nothing new to install. The TRNG driver ships inside embassy-rp, gated"
say "behind the same rp235xa feature the rest of the experiments already set"
say "— there is no TRNG on the RP2040, so this is the first firmware here"
say "that could not be back-ported to one."
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
step 3 "Watch the numbers settle"
say ""
say "Reading for ${WATCH_S} seconds. Four things scroll past each round:"
say ""
say "  ${BOLD}temp${RESET}     the sensor as a temperature, raw count and degrees"
say "  ${BOLD}trng${RESET}     eight random bytes, and how long the wait was"
say "  ${BOLD}ones${RESET}     what fraction of all bits so far were 1"
say "  ${BOLD}changes${RESET}  how often a bit differed from the one before it"
say ""
say "A fair coin scores 50% on both tests. Watch which source stays there."
say ""

OUT="$(exp_read_log "$WATCH_S")"
echo "$OUT" | sed 's/^/    /'
echo

# ---------------------------------------------------------------------------
step 4 "What the scores say"

FINAL_ONES="$(echo "$OUT" | grep 'ones  *after' | tail -1)"
FINAL_CHANGES="$(echo "$OUT" | grep 'changes  *after' | tail -1)"

if [[ -n "$FINAL_ONES" ]]; then
    say "Last monobit line:"
    say "  ${DIM}${FINAL_ONES}${RESET}"
fi
if [[ -n "$FINAL_CHANGES" ]]; then
    say "Last transition line:"
    say "  ${DIM}${FINAL_CHANGES}${RESET}"
fi
say ""
say "The TRNG should be sitting near 50% on both, and should have been near"
say "50% for most of the run. The ADC's bottom bit is the interesting one:"
say "it wanders, and where it lands depends on how steady the chip's"
say "temperature happens to be right now."

WAITS="$(echo "$OUT" | grep -o '([0-9]* us awaited)' | grep -o '[0-9]*' || true)"
if [[ -n "$WAITS" ]]; then
    MIN="$(echo "$WAITS" | sort -n | head -1)"
    MAX="$(echo "$WAITS" | sort -n | tail -1)"
    say ""
    say "TRNG waits this run: ${BOLD}${MIN}${RESET} to ${BOLD}${MAX}${RESET} microseconds."
    say "  That wait is a health check refusing to hand over samples it does"
    say "  not trust. With embassy-rp's default sample_count of 25 the same"
    say "  fill took anywhere from 20 ms to 3.8 seconds on this board — see"
    say "  the README section 'The default that does not work'."
fi

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp108 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. The chip contains hardware that produces numbers your program did"
say "     not compute — an analogue sensor and an entropy source."
say "  2. Neither one can be trusted because it looks right. The ADC's"
say "     bottom bit looks like noise and is not entropy; the only reason"
say "     you know is that you measured it."
say "  3. Two cheap tests that disagree are worth more than one that passes."
say "     Both of these together are still nowhere near enough to certify a"
say "     random number generator — see the README on what they cannot see."
say ""
say "None of this could have been blinked. This is exp107's log earning its"
say "keep: every result here is a number."
