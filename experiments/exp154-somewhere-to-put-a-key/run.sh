#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp154 interactive walkthrough — ask the chip what it already has, and write
# nothing to it.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp154-somewhere-to-put-a-key
UF2=target/exp154-somewhere-to-put-a-key.uf2

# The survey starts three seconds in — the firmware lets USB enumerate before
# doing anything that takes a while — and 4096 rows take a moment after that.
SURVEY_S=15

echo "${BOLD}exp154 — somewhere to put a key${RESET}"
say ""
say "The signing road needs a place to keep a private key that code on the"
say "other side of a boundary cannot read. Before building any boundary, this"
say "asks the part what it already has."
say ""
say "It reads. It writes nothing, and that is not politeness: OTP is one-time"
say "programmable, so a write that is wrong does not fail a test — it ruins"
say "the board, permanently, for every experiment after this one."

# ---------------------------------------------------------------------------
step 1 "Build and convert"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
ok "UF2 ready ($(stat -c%s "$UF2") bytes)."

# ---------------------------------------------------------------------------
step 2 "Ask every row"
run_cmd yi26 flash "$UF2"
say ""
say "The firmware sweeps all 4096 rows and collapses the answers into runs, so"
say "the shape of the OTP fits on a screen. Three answers are possible and all"
say "three matter: ${BOLD}programmed${RESET}, ${BOLD}blank${RESET}, and"
say "${BOLD}REFUSED${RESET} — the hardware declining to hand a row over, which"
say "is the one this road came looking for."
say ""
OUT="$(exp_read_log "$SURVEY_S")"
echo "$OUT" | sed 's/^/    /'
echo

TOTALS="$(echo "$OUT" | grep -o 'totals:.*' | tail -1 || true)"
[[ -n "$TOTALS" ]] && ok "$TOTALS"

REFUSED="$(echo "$OUT" | grep -oE 'no row refused[^"]*|[0-9]+ rows refused[^"]*' | tail -1 || true)"
if [[ "$REFUSED" == no\ row\ refused* ]]; then
    say ""
    bad "No row refused a read."
    say ""
    say "That is a finding rather than a failure, and it is the one that decides"
    say "the next experiment. On a stock part, OTP is a place to ${BOLD}store${RESET} a"
    say "key, not a place that ${BOLD}hides${RESET} one from the core reading it. The"
    say "boundary this road needs has to come from somewhere else — which is"
    say "what the next experiment goes and builds."
elif [[ -n "$REFUSED" ]]; then
    say ""
    ok "$REFUSED"
    say ""
    say "Something on this part is already locked, before this firmware ran."
    say "Which rows, and what set the lock, is the thread to pull next."
fi

# ---------------------------------------------------------------------------
step 3 "The rows somebody else called a key"
say ""
say "Prior work outside this repository reads an ECDSA private key from rows"
say "0xE80-0xE8F, falling back to a compiled-in test key when they read zero."
say "It addresses them by hand, on the belief that a row is two bytes spaced"
say "eight bytes apart. The HAL says one 32-bit read returns ${BOLD}two${RESET}"
say "neighbouring rows, so a row is two bytes apart, and only the first 8 KiB"
say "is populated."
say ""
say "Take the first at its word and 0xE80 x 8 is byte 29,696, which is outside"
say "an 8 KiB window entirely. Read as a row number it lands inside. Above is"
say "what is actually there, read the way the HAL means it."
say ""
say "This firmware deliberately does not try the other way. An access outside"
say "the populated window is how you get a HardFault, and a HardFault here"
say "takes USB with it — leaving a board that says nothing at all."

# ---------------------------------------------------------------------------
echo
say "${BOLD}What you just saw${RESET}"
say ""
say "  * every OTP row on this part, classified"
say "  * whether any of them is already beyond this core's reach"
say "  * what is in the rows a signing experiment elsewhere trusted"
say ""
say "Nothing was written. Run it again as often as you like."
