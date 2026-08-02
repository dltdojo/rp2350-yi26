#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp109 interactive walkthrough — the hardware TRNG, and the one constant
# that decides whether it is usable.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp109-hardware-trng
UF2=target/exp109-hardware-trng.uf2
SLOW_UF2=target/exp109-upstream-default.uf2

GOOD_S=8
# Long enough to see the second request fail to arrive. Measured on this
# board, the second fill at the upstream default took 31 seconds.
SLOW_S=25

echo "${BOLD}exp109 — real entropy, and what it costs to ask${RESET}"
say ""
say "exp108 read a sensor. This reads the other on-chip source of numbers you"
say "did not compute: a true random number generator, sampling the jitter of a"
say "free-running ring oscillator."
say ""
say "Asking for bytes is one line. The experiment is what the asking costs."

# ---------------------------------------------------------------------------
step 1 "Build both configurations"
say "Two firmwares from the same source. They differ in one constant:"
say "  ${DIM}sample_count${RESET} — clock cycles between two oscillator samples."
run_cmd cargo build --release --features upstream-default
run_cmd elf2flash convert -b rp2350 "$ELF" "$SLOW_UF2"
ok "Upstream default (sample_count = 25) ready."
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
ok "Measured value (sample_count = 1000) ready."

# ---------------------------------------------------------------------------
step 2 "The one that works"
run_cmd yi26 flash "$UF2"
say ""
say "Reading for ${GOOD_S} seconds. Watch the ${BOLD}cost${RESET} line — that is how long the"
say "hardware took to produce 64 bits."
say ""
GOOD="$(exp_read_log "$GOOD_S")"
echo "$GOOD" | sed 's/^/    /'
echo

GOOD_ROUNDS="$(echo "$GOOD" | grep -c 'trng: ' || true)"
ok "${GOOD_ROUNDS} request(s) answered in ${GOOD_S} seconds, each costing a few milliseconds."

# ---------------------------------------------------------------------------
step 3 "The one the driver ships"
say ""
say "Same source. Same board. ${BOLD}sample_count = 25${RESET} instead of 1000 — the value"
say "embassy-rp uses if you do not say otherwise."
say ""
run_cmd yi26 flash "$SLOW_UF2"
say ""
say "Reading for ${SLOW_S} seconds. Expect the first request to arrive, and then"
say "a long run of nothing but heartbeats."
say ""
SLOW="$(exp_read_log "$SLOW_S")"
echo "$SLOW" | sed 's/^/    /'
echo

SLOW_ROUNDS="$(echo "$SLOW" | grep -c 'trng: ' || true)"
SLOW_BEATS="$(echo "$SLOW" | grep -c 'heartbeat #' || true)"
say "${BOLD}${SLOW_ROUNDS}${RESET} entropy request(s) and ${BOLD}${SLOW_BEATS}${RESET} heartbeats in the same window."
say ""
say "Those heartbeats are the point. The firmware is not hung, not crashed,"
say "and not broken — every request is answered eventually. On this board the"
say "second one took ${BOLD}31 seconds${RESET}. Something that always works and"
say "occasionally takes half a minute is harder to find than something that"
say "fails, because there is no error to catch."

# ---------------------------------------------------------------------------
step 4 "Put the working one back"
say "Leaving the board on the configuration that works, so the next"
say "experiment starts from a sane place."
run_cmd yi26 flash "$UF2"
ok "Back on sample_count = 1000."

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp109 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. A real entropy source runs health tests and throws away what fails"
say "     them. That makes the cost of a request variable, with no useful"
say "     upper bound — the honest difference between this and a PRNG."
say "  2. A driver default is a starting point, not a verdict. This one is"
say "     documented, upstream, and wrong for this board by a factor of"
say "     thousands."
say "  3. Measuring the cost of every request is what made any of this"
say "     visible. Nothing failed; there was only a gap."
say ""
say "What this experiment did ${BOLD}not${RESET} show: whether the bytes are any good."
say "They look random. So does an encrypted counter. ${BOLD}exp111${RESET} measures them."
