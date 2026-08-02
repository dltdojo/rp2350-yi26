#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp110 interactive walkthrough — the same slow hardware, awaited and
# blocked on, with the cost of the difference measured.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp110-await-not-block
AWAIT_UF2=target/exp110-await.uf2
BLOCK_UF2=target/exp110-blocking.uf2

WATCH_S=10

echo "${BOLD}exp110 — awaiting is not the same as waiting${RESET}"
say ""
say "exp109 was careful about one line without dwelling on it: it awaited the"
say "TRNG instead of blocking on it. Both wait exactly as long — the hardware"
say "takes what it takes. This is about what happens to everything else."
say ""
say "Three tasks in both builds: one asks for 4096 random bytes (about 880 ms"
say "of hardware time), one wants to wake every 100 ms and reports how late it"
say "was, and one flashes the LED."

# ---------------------------------------------------------------------------
step 1 "Build both"
run_cmd cargo build --release --features blocking
run_cmd elf2flash convert -b rp2350 "$ELF" "$BLOCK_UF2"
ok "Blocking build ready."
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$AWAIT_UF2"
ok "Awaiting build ready."

# ---------------------------------------------------------------------------
step 2 "Await"
run_cmd yi26 flash "$AWAIT_UF2"
say ""
say "Reading for ${WATCH_S} seconds. Watch ${BOLD}worst lateness${RESET} on the probe lines."
say ""
A="$(exp_read_log "$WATCH_S")"
echo "$A" | sed 's/^/    /'
echo
A_WORST="$(echo "$A" | grep -o 'worst lateness [0-9]*' | grep -o '[0-9]*' | sort -n | tail -1 || true)"
[[ -n "$A_WORST" ]] && ok "Worst lateness while awaiting: ${BOLD}${A_WORST} us${RESET}"

# ---------------------------------------------------------------------------
step 3 "Block"
say ""
say "Same source, one call changed. ${DIM}blocking_fill_bytes${RESET} instead of"
say "${DIM}fill_bytes(..).await${RESET}."
say ""
run_cmd yi26 flash "$BLOCK_UF2"
say ""
B="$(exp_read_log "$WATCH_S")"
echo "$B" | sed 's/^/    /'
echo
B_WORST="$(echo "$B" | grep -o 'worst lateness [0-9]*' | grep -o '[0-9]*' | sort -n | tail -1 || true)"
[[ -n "$B_WORST" ]] && bad "Worst lateness while blocking: ${BOLD}${B_WORST} us${RESET}"

if [[ -n "$A_WORST" && -n "$B_WORST" && "$A_WORST" -gt 0 ]]; then
    say ""
    say "That is a factor of about ${BOLD}$(( B_WORST / A_WORST ))${RESET}, for the same hardware wait."
fi

# ---------------------------------------------------------------------------
step 4 "Put the good one back"
say "This is also a measurement. Flashing away from the blocking build has to"
say "get through a task that holds the CPU for 880 ms at a time — the"
say "1200-baud watcher is a task like any other."
START=$(date +%s%N)
run_cmd yi26 flash "$AWAIT_UF2"
ELAPSED=$(( ($(date +%s%N) - START) / 1000000 ))
ok "Reflashed from the blocking build in ${ELAPSED} ms."
say "  Measured here: about 5.5 s from the awaiting build, 5.8 s from the"
say "  blocking one. It still works at this request size — and nothing"
say "  defends that margin. See the README."

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp110 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. Awaiting and blocking wait the same length of time. Only one of"
say "     them lets anything else happen meanwhile."
say "  2. An Embassy executor is cooperative. A task that does not yield is"
say "     not interrupted — not by a timer, not by the USB stack, not by the"
say "     logger that was going to tell you about it."
say "  3. The stall is only visible because something measured it. Nothing"
say "     failed, nothing panicked, and the LED kept flashing."
say ""
say "Next: ${BOLD}exp111${RESET} asks whether the bytes from exp109 are actually random —"
say "and compares them against exp108's sensor readings, which also look it."
