#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp111 interactive walkthrough — two sources that look alike, scored.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp111-measuring-randomness
UF2=target/exp111-measuring-randomness.uf2

# The first few rounds are pure noise. Long enough that the columns separate.
WATCH_S=40

echo "${BOLD}exp111 — both of these look random${RESET}"
say ""
say "exp108 read a temperature sensor. exp109 read an entropy source. Print"
say "raw bits from either and they look the same — no pattern, nothing a"
say "person could pick out."
say ""
say "One of them is random. The other is a thermometer being misused. This"
say "experiment stops looking and starts counting."

# ---------------------------------------------------------------------------
step 1 "Build and convert"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
ok "UF2 ready ($(stat -c%s "$UF2") bytes)."

# ---------------------------------------------------------------------------
step 2 "Flash it"
run_cmd yi26 flash "$UF2"
ok "Running, serial port at $(exp_serial_port)"

# ---------------------------------------------------------------------------
step 3 "Watch the columns separate"
say ""
say "Reading for ${WATCH_S} seconds. Two scored lines per round:"
say ""
say "  ${BOLD}ones${RESET}     what fraction of the bits so far were 1"
say "  ${BOLD}changes${RESET}  how often a bit differed from the one before it"
say ""
say "A fair coin scores 50% on both. ${BOLD}Ignore the first few rounds${RESET} — sixty-four"
say "bits is not enough data to say anything, and it will look like it is."
say ""

OUT="$(exp_read_log "$WATCH_S")"
echo "$OUT" | sed 's/^/    /'
echo

# ---------------------------------------------------------------------------
step 4 "The verdict"

FIRST_ONES="$(echo "$OUT" | grep 'ones  *after' | head -1 || true)"
LAST_ONES="$(echo "$OUT" | grep 'ones  *after' | tail -1 || true)"
LAST_CHANGES="$(echo "$OUT" | grep 'changes  *after' | tail -1 || true)"

if [[ -n "$FIRST_ONES" ]]; then
    say "The first scored line, on 64 bits:"
    say "  ${DIM}${FIRST_ONES}${RESET}"
    say "  Worthless. On that evidence either source could be the good one."
fi
say ""
if [[ -n "$LAST_ONES" ]]; then say "  ${DIM}${LAST_ONES}${RESET}"; fi
if [[ -n "$LAST_CHANGES" ]]; then say "  ${DIM}${LAST_CHANGES}${RESET}"; fi
say ""
say "The TRNG should be near 50% on both and have been for a while. The ADC"
say "column depends on how steady your chip's temperature happens to be — and"
say "${BOLD}that dependence is the finding${RESET}, not whichever number you got."
say ""
say "Run this again in ten minutes and compare. Across runs while this"
say "experiment was written, the ADC's 'ones' score ranged from 32.8% to"
say "84.1%, and once landed on 47.5% over six thousand bits — a comfortable"
say "pass. The TRNG never moved off 50%."

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp111 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. Looking at bits tells you nothing. Both columns started from hex"
say "     that was equally convincing."
say "  2. A statistic on too little data is noise with a decimal point on it."
say "  3. Two cheap tests that disagree are worth more than one that passes."
say ""
say "What you did ${BOLD}not${RESET} prove: that the TRNG is a good random number"
say "generator. '0101010101...' scores a perfect 50% on both tests here and is"
say "entirely predictable. Neither test looks back further than one bit, and"
say "neither has any concept of an adversary. Read the README's last section"
say "before reusing any of this for anything that matters."
