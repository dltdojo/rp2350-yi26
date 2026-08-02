#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp115 interactive walkthrough — a browser reads the board's descriptors.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PAGE="$(pwd)/usb-inspector.html"

echo "${BOLD}exp115 — what is inside this device?${RESET}"
say ""
say "No firmware in this experiment. The board keeps running whatever you"
say "flashed last; the deliverable is one HTML file that asks the browser to"
say "open it and report what it finds."
say ""
say "This is also where the browser track's one host-side obstacle gets"
say "cleared, on the smallest possible experiment."

# ---------------------------------------------------------------------------
step 1 "The obstacle"
say "A serial port and a mounted drive are already yours to open. The raw USB"
say "device node is not — it is root-only, and WebUSB claims the interface"
say "directly. Without a rule, Chrome's first Connect fails with ${BOLD}Access denied${RESET},"
say "which names nothing you could search for."
say ""
if yi26 udev > /dev/null 2>&1; then
    ok "Raw USB access is already available on this machine."
else
    say "${YELLOW}Not yet available.${RESET} One command, one password:"
    say ""
    say "    ${BOLD}yi26 udev --install${RESET}"
    say ""
    say "It prints what it will run first, and ${DIM}yi26 udev --explain${RESET} gives you the"
    say "commands to type yourself instead."
    die "Run that, then start this again."
fi

# ---------------------------------------------------------------------------
step 2 "What the board should say"
say "Before opening anything, here is the answer from the host side. The page"
say "has to arrive at the same tree by a completely different route."
say ""
if [[ "$(yi26 state)" != "running" ]]; then
    die "No board running one of these firmwares. Flash any experiment first."
fi
lsusb -d 1209:0001 -v 2>/dev/null \
  | grep -E "bDeviceClass|bDeviceSubClass|bDeviceProtocol|bNumInterfaces|bInterfaceNumber|bInterfaceClass|bEndpointAddress|wMaxPacketSize|iProduct" \
  | sed 's/^ */    /'
echo

# ---------------------------------------------------------------------------
step 3 "Open the page"
say ""
say "  ${BOLD}file://${PAGE}${RESET}"
say ""
say "Open it ${BOLD}directly from the filesystem${RESET} — double-click it, or hand the file"
say "to your browser. There is deliberately no local web server here: a server"
say "is fine on a desktop and impossible on a phone, and the phone is where"
say "this track is going."
say ""
say "On Android the equivalent is the ${BOLD}Files app -> Open with Chrome${RESET}, which"
say "hands the browser a content:// URI. Typing a file:///sdcard/... URL into"
say "Chrome does ${BOLD}not${RESET} work — scoped storage blocks it."
say ""

if command -v google-chrome > /dev/null; then
    if confirm "Open it in Chrome now?"; then
        google-chrome "file://$PAGE" > /dev/null 2>&1 &
        sleep 2
        ok "Chrome launched."
    fi
fi

say ""
say "In the page: press ${BOLD}Connect${RESET}, choose the board in the picker Chrome puts"
say "up, and allow it. That picker is a native dialog and the click is a"
say "required user gesture — no script can do it for you, which is the point."
say ""
say "The permission is asked once. After that ${DIM}navigator.usb.getDevices()${RESET}"
say "returns the device with no picker and no click."
say ""

if ! confirm "Did the page open the device and print a descriptor tree?"; then
    bad "It did not."
    say ""
    say "  ${BOLD}Access denied${RESET}          the udev rule — step 1, then replug"
    say "  ${BOLD}No device chosen${RESET}       try the 'Any device…' button; the filter is"
    say "                        1209:0001 and somebody else may hold that ID"
    say "  ${BOLD}no WebUSB${RESET}              Firefox and Safari do not implement it"
    say "  ${BOLD}nothing at all${RESET}         check the file opened as file:// and not as text"
    exit 1
fi

# ---------------------------------------------------------------------------
step 4 "Compare"
say ""
say "Press ${BOLD}Copy report${RESET} in the page and put it next to the output from step 2."
say "Two routes to the same device: one through the kernel's USB stack and"
say "lsusb, one through a browser sandbox. They should agree on every number."
say ""
say "The interesting rows are the endpoints. Interface 0 has one interrupt IN"
say "endpoint of 8 bytes — that is where a CDC device reports line-state"
say "changes, and it is how exp105's 1200-baud trick reaches the firmware."
say "Interface 1 has bulk IN and OUT at 64 bytes, and the IN one is the log."
say ""
say "exp116 claims those two interfaces and reads that endpoint."

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp115 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. A web page can open a USB device and read its descriptors, with no"
say "     driver, no install, and no firmware change."
say "  2. Opening it is the part that needs permission. Rendering the tree is"
say "     not — the browser already had those strings from enumeration, which"
say "     is why this page opens the device rather than only describing it."
say "  3. The file is the whole deliverable. No server, no network, no build."
say "     That is what makes the same page work on a phone."
