#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp116 interactive walkthrough — claim the CDC interfaces from a browser
# and read the log endpoint.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PAGE="$(pwd)/cdc-log-viewer.html"

echo "${BOLD}exp116 — the log, in a browser${RESET}"
say ""
say "exp115 opened the board and described it. This one claims its interfaces,"
say "sends the two control transfers a CDC host has to send, and reads the"
say "endpoint the log comes out of."
say ""
say "No firmware changes. The board is printing exactly what it always"
say "printed; something else is listening."

# ---------------------------------------------------------------------------
step 1 "Make sure there is something to listen to"
if [[ "$(yi26 state)" == "absent" ]] && [[ ! -e /dev/ttyACM0 ]]; then
    say "${YELLOW}No serial port and no board found.${RESET}"
    say "If you detached earlier, put it back so we can start from a known state:"
    say ""
    say "    ${BOLD}yi26 attach${RESET}"
    say ""
    confirm "Run that now?" && run_cmd yi26 attach
fi
if [[ "$(yi26 state)" != "running" ]]; then
    die "Flash any experiment first — this page reads whatever is already printing."
fi
ok "Board is running and printing."
say "  A few lines of it, through the serial port, while we still have one:"
exp_read_log 3 | tail -4 | sed 's/^/    /'

# ---------------------------------------------------------------------------
step 2 "Take the interfaces from the kernel"
say ""
say "The kernel's ${DIM}cdc_acm${RESET} driver owns them — that ownership ${BOLD}is${RESET}"
say "/dev/ttyACM0 — and a USB interface has exactly one owner."
say ""
say "Chrome's WebUSB does ${BOLD}not${RESET} take it away for you. Measured, because the"
say "failure gives no hint: claiming returns EBUSY, and detaching first then"
say "claiming succeeds every time."
say ""
run_cmd yi26 detach
say ""
say "The serial port is gone now:"
run_cmd sh -c "ls /dev/ttyACM0 2>&1 || true"
say ""
say "So is ${DIM}yi26 log${RESET}. Flashing still works — ${DIM}yi26 bootsel${RESET} sends the same"
say "1200-baud request over a control transfer when there is no port to set a"
say "baud rate on. Without that, this step would have cost you the button."

# ---------------------------------------------------------------------------
step 3 "Open the page"
say ""
say "  ${BOLD}file://${PAGE}${RESET}"
say ""
if command -v google-chrome > /dev/null && confirm "Open it in Chrome now?"; then
    google-chrome "file://$PAGE" > /dev/null 2>&1 &
    sleep 2
    ok "Chrome launched."
fi
say ""
say "Press ${BOLD}Connect and stream${RESET}. If the browser remembers the permission from"
say "exp115 it will connect with no picker — the grant belongs to the file://"
say "origin and lasts until the browser restarts."
say ""

if ! confirm "Is the log scrolling in the page?"; then
    bad "It is not."
    say ""
    say "  ${BOLD}Unable to claim interface${RESET}   step 2 did not run, or something re-attached"
    say "  ${BOLD}connected but silent${RESET}        DTR was never asserted — the firmware waits"
    say "                              for it before writing a single byte"
    say "  ${BOLD}board fell into BOOTSEL${RESET}     BAUD is 1200 somewhere; flash anything"
    exit 1
fi

# ---------------------------------------------------------------------------
step 4 "Put it back"
say ""
say "Press ${BOLD}Disconnect${RESET} in the page first — while it holds the interfaces,"
say "nothing else can have them, including this script."
say ""
confirm "Disconnected?" || say "${YELLOW}Continuing anyway; the next command may fail with EBUSY.${RESET}"
run_cmd yi26 attach
say ""
run_cmd sh -c "ls -l /dev/ttyACM0 2>&1 || true"

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp116 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. A web page can claim a USB interface, drive the control pipe by"
say "     hand, and read a bulk endpoint — with no driver and no firmware"
say "     change. On a phone this is the only way in."
say "  2. An interface has one owner. The kernel had it, the browser wanted"
say "     it, and somebody had to say so out loud."
say "  3. The two control transfers are not ceremony. Without"
say "     SET_CONTROL_LINE_STATE the page connects, succeeds, and receives"
say "     nothing forever, because the firmware is waiting for DTR."
say ""
say "Next: ${BOLD}exp117${RESET} turns the same bulk pair around — the host types, the"
say "firmware reacts, and something waits on two things at once."
