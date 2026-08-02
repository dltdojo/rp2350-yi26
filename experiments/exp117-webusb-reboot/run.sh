#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp117 interactive walkthrough — a web page puts the board into BOOTSEL.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PAGE="$(pwd)/reboot.html"

echo "${BOLD}exp117 — the request whose success looks like failure${RESET}"
say ""
say "The last experiment on this track that changes no firmware. exp105 taught"
say "the board to reboot when the host sets 1200 baud, and every firmware here"
say "has done it since. Nothing new is taught to the board — something new is"
say "doing the asking."

# ---------------------------------------------------------------------------
step 1 "Check what is on the board"
if in_bootsel; then
    die "The board is already in BOOTSEL. Flash something first, or there is nothing to reboot."
fi
run_cmd yi26 doctor
say ""
say "Whatever is flashed has to be exp105 or later. ${DIM}audit.sh${RESET} can tell you"
say "for certain — it reads the setting out of the .uf2, not out of the source."

# ---------------------------------------------------------------------------
step 2 "Give the interface to the browser"
say ""
say "The kernel's ${DIM}cdc_acm${RESET} driver owns it, and an interface has exactly one"
say "owner. Chrome does not take it away for you."
say ""
run_cmd yi26 detach
say ""
say "On Android none of this step exists. There is no ${DIM}cdc_acm${RESET} to move aside,"
say "so the page simply works — the platform with the fewest tools needs the"
say "fewest steps."

# ---------------------------------------------------------------------------
step 3 "Open the page and press the button"
say ""
say "  ${DIM}${PAGE}${RESET}"
say ""
say "Double-click it, or open it from your file manager. Not a web server:"
say "a server is fine here and impossible on a phone, and the phone is where"
say "this whole track is going."
say ""
say "Expect a run of things that look like breakage. The transfer may return"
say "success, or it may reject — ${BOLD}neither means anything${RESET}, because the chip"
say "resets while the request is in flight. The line to watch for is"
say "${BOLD}disconnect event${RESET}. The device going away is the only unambiguous"
say "evidence the page has."
pause "Press the button, then come back."

# ---------------------------------------------------------------------------
step 4 "Check it from outside the browser"
say ""
say "The page says it worked. That is the page's opinion of itself, so here is"
say "somebody else's:"
say ""
run_cmd yi26 state
run_cmd lsusb -d 2e8a:000f
if in_bootsel; then
    ok "A web page rebooted a microcontroller."
    run_cmd yi26 drive
    say ""
    say "That drive is where a .uf2 goes. On a phone this is the Files app, and"
    say "the loop is closed: build in the cloud, download, reboot from a page,"
    say "drag the file on."
else
    bad "The board is not in BOOTSEL."
    say "Either the button was not pressed, or this firmware has no 1200-baud"
    say "watcher. ${DIM}experiments/audit.sh${RESET} reads that from the .uf2."
fi

# ---------------------------------------------------------------------------
step 5 "Put it back"
say ""
say "Flashing needs no browser and no button either."
say ""
if in_bootsel; then
    say "Give it any .uf2 from this repository, for example:"
    say "  ${DIM}yi26 flash ../exp119-cancelled-reads/target/exp119-cancelled-reads.uf2${RESET}"
    say ""
    say "Flashing also gives the interface back to the kernel, so ${DIM}yi26 attach${RESET}"
    say "is not needed afterwards."
else
    run_cmd yi26 attach
fi

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp117 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. A page can change the board's state, not only read it — and this one"
say "     needed no firmware change to do it."
say "  2. It takes ${BOLD}one${RESET} control transfer, where a serial API needs two. The"
say "     dance exists to defeat a driver's optimisation, and when you are the"
say "     driver there is no optimisation to defeat."
say "  3. Success and failure look identical from the transfer. The page waits"
say "     for the disconnect instead, because that is the part that is not"
say "     ambiguous."
say "  4. Anything that can open your board can also reboot it. Convenient"
say "     here, and worth thinking about elsewhere — ${DIM}audit.sh${RESET} says so at"
say "     more length."
say ""
say "Next: ${BOLD}exp120${RESET} turns exp118 around — the page sends bytes rather than only"
say "receiving them, which is what makes a phone an input device and not just a"
say "screen."
