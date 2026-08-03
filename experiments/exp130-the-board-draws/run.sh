#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp130 interactive walkthrough — the board runs the draw and serves the page
# that shows it, and a browser arrives between the TRNG and the room.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp130-the-board-draws
UF2=target/exp130-the-board-draws.uf2
MODEL="exp130 draw"

echo "${BOLD}exp130 — the board draws${RESET}"
say ""
say "exp129 drew numbers with ${DIM}yi26 send${RESET} and nothing in between. This one puts"
say "the draw behind a page, and serves the page off the board itself — which"
say "is the form the job is actually for, and a different security picture."

# ---------------------------------------------------------------------------
step 1 "Build and flash"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
run_cmd yi26 flash "$UF2"
ok "Two interfaces: a read-only volume, and the port the draw travels on."

# ---------------------------------------------------------------------------
step 2 "The volume, and the bit exp126 left clear"
say ""
run_cmd yi26 log --seconds 5
say ""
say "${DIM}MODE SENSE(6) -> READ-ONLY (WP set)${RESET}. exp126 left that bit at zero and"
say "the volume was writable — which is why an Android phone created a"
say "${BOLD}LOST.DIR${RESET} on it within a minute of mounting. A host writes to your device"
say "unless you tell it not to, and a draw appliance should not be scribbled on."
say ""
DEV=""
for d in /sys/block/*/; do
    [[ -r "$d/device/model" ]] || continue
    M="$(cat "$d/device/model" 2>/dev/null)"
    [[ "${M%"${M##*[![:space:]]}"}" == "$MODEL" ]] && DEV="$(basename "$d")"
done
if [[ -n "$DEV" ]]; then
    run_cmd lsblk -o NAME,RO,SIZE,LABEL "/dev/$DEV"
    say ""
    say "${BOLD}RO is 1.${RESET} The host was told, and believed it."
fi

# ---------------------------------------------------------------------------
step 3 "Draw, with nothing in between"
say ""
run_cmd yi26 send '2100-2567'
run_cmd yi26 send '2100-2567'
say ""
say "That is exp129, still working, while the kernel holds the storage"
say "interface. Two owners, one device — exp122's lesson, in production."

# ---------------------------------------------------------------------------
step 4 "Now put a browser in the way"
say ""
say "Open ${BOLD}INDEX.HTM${RESET} from the volume that just mounted. On Linux, the kernel"
say "owns the serial interfaces and a browser cannot have them until it lets"
say "go:"
say ""
say "  ${DIM}yi26 detach${RESET}     then open the page, press Connect, press Draw"
say "  ${DIM}yi26 attach${RESET}     to give the port back afterwards"
say ""
say "On a phone there is no ${DIM}cdc_acm${RESET} and nothing to move aside — open the file"
say "from the Files app and choose Chrome. ${BOLD}Do not type a file:// URL${RESET}: scoped"
say "storage blocks it and the symptom does not name the cause."

# ---------------------------------------------------------------------------
step 5 "What changed, and it is not the presentation"
say ""
say "In exp129 the only thing between the chip's TRNG and you was ${DIM}yi26 log${RESET},"
say "whose source is in this repository. Now there is a browser, a page, and a"
say "screen. The number you read is ${BOLD}a claim about what the device said${RESET}, not"
say "the thing the device said."
say ""
say "So the page prints the board's own line underneath the big number. Two"
say "views of one event, on one screen, and anybody standing there can compare"
say "them. That is the whole mechanism — no cryptography, just refusing to be"
say "the only witness."
say ""
say "And the page checks its own provenance. The firmware announces its page"
say "build at boot; the page knows its own; if they differ it says so. A page"
say "off the board and a stale copy saved on the phone weeks ago look"
say "identical in the address bar, and that is a real way to be fooled."

# ---------------------------------------------------------------------------
step 6 "It can still be reflashed, including from a phone"
run_cmd yi26 bootsel
if in_bootsel; then
    ok "Rebooted itself. On a phone, exp117's page does the same thing."
    run_cmd yi26 flash "$UF2"
else
    bad "It did not reboot — that is the failure this step exists to catch."
fi

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp130 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. A device can declare its volume read-only and a host will honour it,"
say "     which is the difference between exp126's LOST.DIR and this one's"
say "     untouched volume."
say "  2. The storage interface and the serial interface work at once, with"
say "     different owners, while a real job runs over one of them."
say "  3. Putting a browser between the device and the room changes what the"
say "     audience is trusting. The answer is not a stronger promise, it is a"
say "     second view of the same event that anyone present can read."
say ""
say "What is ${BOLD}not${RESET} proved is that the draw was fair — exp111 drew that line and"
say "exp129 restates it. The claim is mechanism, not outcome."
