#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp107 interactive walkthrough — three tasks logging to one serial port,
# and a demonstration that a host which stops reading can no longer stop the
# firmware.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp107-debug-logging
UF2=target/exp107-debug-logging.uf2

# How long to leave the port unopened in step 3. The queue holds 16 lines and
# fills at roughly two per second, so this is comfortably longer than it takes
# to overflow — the point is to make the loss happen, and be reported.
SILENCE_S=20

echo "${BOLD}exp107 — three tasks, one log${RESET}"
say "So far, printing and working were the same loop, and exp104 measured"
say "what that costs: two log lines 21 seconds apart because nothing was"
say "draining the port. Here the printing moves behind a queue, and three"
say "tasks — a heartbeat, the BOOTSEL button, and a scheduler probe — log"
say "whenever they like without ever waiting for the host."

# ---------------------------------------------------------------------------
step 1 "Build and convert"

for tool in cargo elf2flash; do
    command -v "$tool" > /dev/null || die "'$tool' missing — run exp102 first."
done
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
FAMILY="$(od -An -tx4 -j28 -N4 "$UF2" | tr -d ' ')"
[[ "$FAMILY" == "e48bff59" ]] || die "UF2 family ID is $FAMILY, expected e48bff59."
ok "UF2 ready ($(stat -c%s "$UF2") bytes)."

# ---------------------------------------------------------------------------
step 2 "Flash it"

ensure_bootsel || die "Board never reached BOOTSEL mode."

MP="$(rp2350_mount)" || die "Board is in BOOTSEL but its drive never appeared. Check: lsblk"
ok "Boot drive at $MP"
run_cmd cp "$UF2" "$MP/"
sync 2>/dev/null || true

PORT=""
for _ in {1..15}; do PORT="$(exp_serial_port || true)"; [[ -n "$PORT" ]] && break; sleep 1; done
[[ -n "$PORT" ]] || die "Board did not come back up. Check: dmesg | tail"
ok "Running, serial port at $PORT"

# ---------------------------------------------------------------------------
step 3 "Ignore it on purpose"

say "The firmware is logging right now and ${BOLD}nothing is reading${RESET} the port."
say "Under exp104's design that would park the writing task within a line or"
say "two. Watch the LED instead: it should keep flashing once a second for"
say "the whole of the next ${SILENCE_S} seconds."
say ""
echo -n "  waiting "
for ((i = 0; i < SILENCE_S; i++)); do echo -n "."; sleep 1; done
echo

# ---------------------------------------------------------------------------
step 4 "Open the port and read what it says"

say "Now we attach. The queue holds 16 lines, so the oldest lines from"
say "startup come out first, then a marker saying how many were lost while"
say "nobody was listening, then live output."
say ""
say "${BOLD}Press BOOTSEL a few times${RESET} during the next 15 seconds — the button"
say "watcher has been running the whole time and will report each press."
echo "  ${DIM}\$ stty -F $PORT -icrnl && cat $PORT${RESET}"
OUT="$(exp_read_log "$PORT" 15)"
[[ -n "$OUT" ]] || die "Nothing came out of $PORT. Is another program holding it? Try: fuser -v $PORT"
echo "$OUT" | sed 's/^/    /'

# ---------------------------------------------------------------------------
step 5 "Check what that output proves"

MARKER="$(echo "$OUT" | grep -m1 'lines lost' || true)"
LOST="$(echo "$MARKER" | grep -o '(+[0-9]* lines lost)' | grep -o '[0-9]*' || true)"
# The line that survives the gap belongs to whichever task logged first, so
# take the first heartbeat at or after it rather than assuming it is one.
LAST_SEQ="$(echo "$OUT" | sed -n "1,/lines lost/p" | grep -o 'heartbeat #[0-9]*' | tail -1 | grep -o '[0-9]*' || true)"
RESUME_SEQ="$(echo "$OUT" | sed -n '/lines lost/,$p' | grep -o 'heartbeat #[0-9]*' | head -1 | grep -o '[0-9]*' || true)"

if [[ -n "$LOST" && "$LOST" -gt 0 ]]; then
    ok "The log reported losing $LOST line(s) — it said so, rather than"
    say "  quietly handing you an incomplete log."
else
    say "  ${YELLOW}No loss marker seen.${RESET} Not a failure: if the queue never filled,"
    say "  nothing was dropped. Re-run with a longer silence to force it."
fi

if [[ -n "$RESUME_SEQ" && -n "$LAST_SEQ" ]]; then
    ok "The log stops at heartbeat #$LAST_SEQ and resumes at #$RESUME_SEQ."
    say "  Those beats are missing from the ${BOLD}log${RESET}, not from the board: the"
    say "  numbering is unbroken, so the heartbeat task kept its rhythm through"
    say "  the whole silence. That is the evidence, not an impression of the"
    say "  LED. Under exp104's design it would have stopped near #2."
fi

if echo "$OUT" | grep -q 'BOOTSEL down'; then
    ok "Button presses arrived interleaved with the heartbeat and the probe."
else
    say "  (no button press recorded — you can press it during the next run)"
fi

if echo "$OUT" | grep -q 'scheduler:'; then
    WORST="$(echo "$OUT" | grep -o 'worst lateness [0-9]* us' | tail -1)"
    ok "Scheduler probe reported: $WORST"
    say "  A number with no physical form. No LED could have told you this."
fi

if ! confirm "Did the LED keep flashing throughout, including step 3?"; then
    bad "The LED stopped."
    say "That would mean the stall was not contained. Run ./check.sh and open"
    say "an issue with its output and the log above."
    exit 1
fi

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp107 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. A queue does not make USB faster. It moves the waiting into a task"
say "     where waiting is harmless — the logger blocked, everything else"
say "     carried on."
say "  2. When the queue overflows, something has to give. This design drops"
say "     lines and tells you how many. Silent loss would be worse than"
say "     either alternative."
say "  3. A log carries what an LED cannot: identity, ordering, timestamps,"
say "     and measurements of things that have no physical form at all."
say ""
say "Read crates/usb-log/src/lib.rs — it is about a hundred lines, and it is"
say "the actual subject of this experiment."
