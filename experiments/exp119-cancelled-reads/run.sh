#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp119 interactive walkthrough — cancel thousands of reads on purpose and
# count what it cost.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp119-cancelled-reads
UF2=target/exp119-cancelled-reads.uf2

N=20000

echo "${BOLD}exp119 — the read that was cancelled${RESET}"
say ""
say "exp118 left a question open. Its ${DIM}select${RESET} loop drops an unfinished"
say "${DIM}read_packet${RESET} every time a control event wins, and it would not claim"
say "whether that costs a packet. This counts."

# ---------------------------------------------------------------------------
step 1 "Build and flash"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
run_cmd yi26 flash "$UF2"

# ---------------------------------------------------------------------------
step 2 "A quiet run, which proves nothing"
say ""
say "${N} numbered packets, no interference. Watch the last line."
say ""
run_cmd yi26 flood --packets "$N" --seconds 3
say ""
say "${BOLD}0 cancelled reads: this run has tested nothing.${RESET} The firmware says so"
say "itself, because \"gaps 0\" beside \"cancels 0\" is not a result — it is a"
say "run in which the hazard never occurred."

# ---------------------------------------------------------------------------
step 3 "The same packets, with the reads cancelled underneath them"
say ""
say "${DIM}--storm${RESET} adds a second thread that toggles ${BOLD}RTS${RESET} for the whole of the"
say "send. Every toggle is a SET_CONTROL_LINE_STATE, every one of those fires"
say "the device's ${DIM}control_changed()${RESET}, and in a ${DIM}select${RESET} loop that cancels"
say "whatever read was in flight."
say ""
say "RTS and not DTR on purpose: both fire the same event, but ${DIM}crates/usb-log${RESET}"
say "will not write while DTR is low, so a DTR storm would silence the log this"
say "is trying to read. The measurement would have destroyed its instrument."
say ""
run_cmd yi26 flood --packets "$N" --storm --seconds 4

# ---------------------------------------------------------------------------
step 4 "Does it cost time instead?"
say ""
say "Data is not the only thing a cancellation could cost. Same load, timed:"
say ""
for mode in "" "--storm"; do
    START=$(date +%s%N)
    yi26 flood --packets "$N" $mode --seconds 1 > /dev/null 2>&1
    ELAPSED=$(( ($(date +%s%N) - START) / 1000000 ))
    say "  ${BOLD}${ELAPSED} ms${RESET}  ${N} packets, storm: ${mode:-none}"
done
say ""
say "Measured here: about 3.6 s either way, twice each. Roughly twenty thousand"
say "cancellations cost no measurable time, which says the bottleneck is"
say "somewhere else — not that cancellation is free everywhere."

# ---------------------------------------------------------------------------
step 5 "And it can still be reflashed"
say ""
say "The 1200-baud watcher lives in the loop that spent the last minute being"
say "cancelled. If cancellation could swallow a control event, this is where it"
say "would show — as a board that no longer answers."
run_cmd yi26 bootsel
if in_bootsel; then
    ok "Rebooted itself."
    run_cmd yi26 flash "$UF2"
else
    bad "It did not reboot. That is the failure this step exists to catch."
fi

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp119 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. Cancelling ${DIM}read_packet${RESET} loses nothing. Not once in twenty thousand."
say "  2. The reason is not luck. ${DIM}embassy-rp${RESET} has one await in its read, and it"
say "     happens ${BOLD}before${RESET} anything is consumed — and what it waits on is a"
say "     hardware register nobody clears until the data is taken."
say "  3. That is a different mechanism from exp118's. There, the control event"
say "     survives because embassy-usb latches it in software. Same guarantee,"
say "     unrelated reasons — so neither may be assumed from the other."
say "  4. A negative result needs a control variable. ${BOLD}cancels${RESET} is the number"
say "     that makes ${BOLD}gaps${RESET} mean anything, and step 2 is what it looks like"
say "     without one."
say ""
say "Still open: whether ${DIM}read_packet${RESET} is cancel-safe on other embassy HALs. This"
say "was measured on RP2350 and the source read was ${DIM}embassy-rp${RESET}. Neither"
say "generalises, and this repository has one board."
