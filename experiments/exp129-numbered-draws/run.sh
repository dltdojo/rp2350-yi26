#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp129 interactive walkthrough — a prize draw on the board, and the three
# things about it that can actually be checked.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp129-numbered-draws
UF2=target/exp129-numbered-draws.uf2

echo "${BOLD}exp129 — numbered draws${RESET}"
say ""
say "A prize draw, on the board. Send the range on the raffle tickets and get"
say "one number back. The first experiment here with a ${BOLD}use${RESET} rather than a"
say "demonstration — and the first where somebody in the room has a reason to"
say "doubt the answer."

# ---------------------------------------------------------------------------
step 1 "The part that needs no board"
say ""
say "The claim is that the mapping cannot be biased. That is checked by"
say "counting, not by drawing:"
say ""
run_cmd sh -c 'cd ../../crates/draw && cargo test'
say ""
say "It counts, for every possible result, how many of the 2^32 inputs reach"
say "it — over the ${BOLD}whole${RESET} space. No number of draws on real hardware could"
say "establish that, which is why it lives in a crate and not in a firmware."

# ---------------------------------------------------------------------------
step 2 "Build and flash"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
run_cmd yi26 flash "$UF2"
ok "Ready to draw."

# ---------------------------------------------------------------------------
step 3 "Draw"
say ""
say "Employee numbers 2100 to 2567 — 468 tickets:"
say ""
run_cmd yi26 send '2100-2567'
run_cmd yi26 send '2100-2567'
run_cmd yi26 send '2100-2567'
say ""
say "Three numbers, and ${BOLD}three sequence numbers${RESET}. Keep looking at those."

# ---------------------------------------------------------------------------
step 4 "What an audience cannot check"
say ""
say "Nobody watching can tell a number from this chip's TRNG apart from"
say "${DIM}Math.random()${RESET}, or from one a rigged firmware picked in advance. exp112"
say "settled the hardest of those: a build that quietly stopped using the"
say "hardware RNG passed ${BOLD}every${RESET} statistical test in this repository."
say ""
say "Randomness is not something an audience can verify. So this firmware is"
say "built around a different question — ${BOLD}what can be?${RESET}"

# ---------------------------------------------------------------------------
step 5 "One: the mapping cannot be biased"
say ""
say "2^32 is not a multiple of 468. Split those inputs into 468 buckets and"
say "${BOLD}256${RESET} are left over, so 256 of the tickets would be about one part in"
say "nine million more likely than the rest."
say ""
say "Nobody would ever notice. That is the argument for removing it, not"
say "against: a defect you cannot detect afterwards has to be designed out"
say "beforehand. The firmware says how many values it rejected, every time."
say ""
say "And when the range divides 2^32 exactly, it rejects nothing:"
say ""
run_cmd yi26 send '1-256'

# ---------------------------------------------------------------------------
step 6 "Two: a failing source cannot emit"
say ""
say "Every bit that could reach a result goes through the SP 800-90B"
say "continuous tests from exp114 ${BOLD}before${RESET} it is used, and a failure stops the"
say "draw rather than annotating it. The warm-up at boot exists because the"
say "adaptive test says nothing until a 1024-sample window has closed — a gate"
say "that cannot yet fail is not a gate."
say ""
run_cmd yi26 log --seconds 6

# ---------------------------------------------------------------------------
step 7 "Three: a discarded draw is visible"
say ""
say "This is the failure a real prize draw actually has, and it is not"
say "cryptographic: ${BOLD}the operator can press again until they like the number.${RESET}"
say ""
say "Nothing here prevents that, and nothing pretends to. What the sequence"
say "number does is make it ${BOLD}impossible to conceal${RESET}. Draw five times and"
say "announce the fifth, and the screen beside the winning number says #5,"
say "where everyone in the room can see it."
say ""
say "It is not cryptography. It is a counter somebody can read, and for this"
say "job that is the right size of mechanism."

# ---------------------------------------------------------------------------
step 8 "Refusals are named, not silent"
say ""
run_cmd yi26 send 'hello'
run_cmd yi26 send '2567-2100'
say ""
say "A draw that quietly ignores a malformed command is worse than one that"
say "argues, because the operator learns nothing and the audience sees no"
say "number appear."

# ---------------------------------------------------------------------------
step 9 "It can still be reflashed"
run_cmd yi26 bootsel
if in_bootsel; then
    ok "Rebooted itself. No button."
    run_cmd yi26 flash "$UF2"
else
    bad "It did not reboot — that is the failure this step exists to catch."
fi

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp129 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. The mapping is uniform by construction, counted over 2^32 rather"
say "     than sampled — and the count is reported with every draw."
say "  2. A source that fails its health tests stops producing numbers"
say "     instead of producing suspect ones."
say "  3. Every draw is numbered, so one nobody mentions leaves a gap."
say ""
say "What you did ${BOLD}not${RESET} prove is that the draw was fair. One board and a few"
say "thousand samples cannot certify a source — exp111 drew that line and it"
say "has not moved. The claim here is mechanism, not outcome."
say ""
say "Next: the same draw with a phone plugged into the board and the page"
say "coming off the board itself — which puts a browser, a page and a screen"
say "between the TRNG and the room. ${BOLD}exp130${RESET}."
