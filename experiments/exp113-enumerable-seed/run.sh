#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp113 interactive walkthrough — build a seed the lazy way, then watch the
# board that made it find it again.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp113-enumerable-seed
UF2=target/exp113-enumerable-seed.uf2

# The result lands about three seconds in — the firmware waits that long
# before doing anything CPU-bound, so USB can finish enumerating first.
FIRST_S=8
# How many extra boots to sample the timer with. The spread across them is
# the real finding.
SAMPLES=5

echo "${BOLD}exp113 — a seed you can count to${RESET}"
say ""
say "exp112 ended with a fix that looks reasonable: seed the software"
say "generator from something device-specific instead of a constant. Every"
say "board gets its own sequence, the reboot tell disappears, every test still"
say "passes."
say ""
say "This asks what that fix is worth. The answer is measured, by brute force,"
say "on the same chip that produced the seed."

# ---------------------------------------------------------------------------
step 1 "Build and convert"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
ok "UF2 ready ($(stat -c%s "$UF2") bytes)."

# ---------------------------------------------------------------------------
step 2 "Make a seed, then break it"
run_cmd yi26 flash "$UF2"
say ""
say "The firmware waits three seconds before starting, so USB can enumerate"
say "first. Heavy work at boot is the one thing that cannot be recovered from"
say "the host — the README explains what that cost during development."
say ""
OUT="$(exp_read_log "$FIRST_S")"
echo "$OUT" | sed 's/^/    /'
echo

CRACK_MS="$(echo "$OUT" | grep -o 'candidates in [0-9]* ms' | grep -o '[0-9]*' | head -1 || true)"
[[ -n "$CRACK_MS" ]] && bad "Recovered in ${BOLD}${CRACK_MS} ms${RESET} by a 150 MHz microcontroller."

# ---------------------------------------------------------------------------
step 3 "Now sample the part that was supposed to be unpredictable"
say ""
say "Rebooting ${SAMPLES} more times and recording the boot-timer value each"
say "time. That value is the only half an attacker does not simply read off"
say "the log."
say ""

VALUES=""
for i in $(seq 1 "$SAMPLES"); do
    yi26 flash "$UF2" > /dev/null 2>&1
    V="$(exp_read_log 6 | grep -o 'hidden value was [0-9]*' | grep -o '[0-9]*' | head -1 || true)"
    [[ -n "$V" ]] && { VALUES="$VALUES $V"; printf '    boot %d: %s us\n' "$i" "$V"; }
done
echo

if [[ -n "$VALUES" ]]; then
    MIN="$(echo $VALUES | tr ' ' '\n' | sort -n | head -1)"
    MAX="$(echo $VALUES | tr ' ' '\n' | sort -n | tail -1)"
    SPREAD=$(( MAX - MIN ))
    say "Range: ${BOLD}${MIN}${RESET} to ${BOLD}${MAX}${RESET} — a spread of ${BOLD}${SPREAD}${RESET} microseconds."
    say ""
    say "The search covers 2^24 candidates. The answer lives in a window of"
    say "about ${SPREAD}. Someone who has watched one board boot a handful of"
    say "times does not search 16 million possibilities; they search ${SPREAD}."
fi

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp113 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. A seed built from a public identity and a predictable timer"
say "     advertises many bits and delivers few. Both ingredients are"
say "     individually reasonable."
say "  2. Uniqueness is not unpredictability. The chip ID makes every board"
say "     different and contributes nothing against anyone holding one."
say "  3. Space is not entropy. The size of the field an attacker could"
say "     search is not the size of the field they will."
say ""
say "Next: ${BOLD}exp114${RESET} implements the two continuous health tests NIST SP 800-90B"
say "actually specifies — and refuses to emit output when they fail, which is"
say "what separates a health test from a printed percentage."
