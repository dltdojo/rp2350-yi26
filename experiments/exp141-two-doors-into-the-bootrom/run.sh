#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp141 interactive walkthrough — confirm a browser can claim the bootrom's
# PICOBOOT interface, the flash port that is not the drag-and-drop drive.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PAGE="$PWD/picoboot.html"

echo "${BOLD}exp141 — two doors into the bootrom${RESET}"
say ""
say "On 2026-08-04 this repository found that dragging a .uf2 onto a phone's"
say "BOOTSEL drive stopped working — Android writes to that drive unreliably,"
say "and it is neither a file nor an app problem. That threatens the whole"
say "premise: a phone, one cable, no second computer."
say ""
say "This is the way out, and it starts by confirming the way out exists."

# ---------------------------------------------------------------------------
step 1 "BOOTSEL has two doors, not one"
say ""
say "  ${BOLD}Interface 0${RESET}  Mass Storage — the drive you drag onto."
say "               Chrome's WebUSB blocks it; Android writes to it badly."
say "  ${BOLD}Interface 1${RESET}  Vendor 0xFF — ${BOLD}PICOBOOT${RESET}, the port picotool drives."
say "               0xFF is claimable, and exp122/exp132 already claimed it."
say ""
say "So put the board into BOOTSEL and let us look at the second door."
run_cmd yi26 bootsel
sleep 2
say ""
say "The two interfaces, read off the real device:"
run_cmd bash -c "lsusb -v -d 2e8a:000f 2>/dev/null | grep -E 'bInterfaceClass|Transfer Type *Bulk' | head -6"

# ---------------------------------------------------------------------------
step 2 "Open the page and claim PICOBOOT"
say ""
say "The page only ${BOLD}reads${RESET}: it claims the interface, resets it, and reads"
say "the status. It sends no flash command — check.sh fails if one is ever in"
say "it. Nothing here can brick the board, and BOOTSEL is the recovery state"
say "anyway."
say ""
say "Open it in ${BOLD}Chrome or Edge${RESET} (desktop is the cleanest first test):"
say ""
say "  ${DIM}file://$PAGE${RESET}"
say ""
say "Press ${BOLD}Connect${RESET}, pick ${DIM}RP2350 Boot${RESET} from the dialog, and read the status."
say ""
say "What confirms it: ${BOLD}claimed interface 1${RESET}, ${BOLD}IF_RESET accepted${RESET}, and a"
say "16-byte status with ${BOLD}dStatusCode=0${RESET}. That is a browser driving the"
say "bootrom's flash interface — the thing the drag-and-drop drive could not"
say "reliably be."

# ---------------------------------------------------------------------------
step 3 "Put a real firmware back"
say ""
say "The board is in BOOTSEL. Leaving it there is harmless, but you probably"
say "want a firmware running again:"
say ""
say "  ${DIM}yi26 flash ../exp138-what-the-rom-already-knows/target/exp138.uf2${RESET}"
say ""
say "That is the drag-and-drop route working on a desktop, for now. The point"
say "of this experiment is the one after it: doing the same write from the"
say "browser, over PICOBOOT, with no drive at all."
say ""
say "${DIM}./check.sh${RESET} asserts the page is read-only and, with a board in BOOTSEL,"
say "that the PICOBOOT interface it depends on is really there."
