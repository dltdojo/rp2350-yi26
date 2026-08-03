#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp131 interactive walkthrough — everything a phone ever needs is on the
# drive, including the way to replace the firmware.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp131-the-volume-is-the-app-drawer
UF2=target/exp131-the-volume-is-the-app-drawer.uf2
MODEL="exp131 drawer"

echo "${BOLD}exp131 — the volume is the app drawer${RESET}"
say ""
say "exp126 ended by claiming that after that flash, the local machine needs"
say "nothing it did not already have. ${BOLD}It was not true.${RESET} To put the ${BOLD}next${RESET}"
say "firmware on, a phone has to reboot the board into BOOTSEL — and the page"
say "that does that was not on the board. It was in this repository."
say ""
say "This one carries it, and not one of the three pages was written here."

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
step 4 "Look at what is on the drive"
say ""
say "Mount the volume and list it. Three pages and a README, and each page is"
say "one of three questions a person actually has:"
say ""
say "  ${BOLD}INDEX.HTM${RESET}   what this board ${BOLD}does${RESET}      — the draw"
say "  ${BOLD}LOG.HTM${RESET}     how to ${BOLD}read${RESET} it        — the firmware's own log, live"
say "  ${BOLD}FLASH.HTM${RESET}   how to ${BOLD}replace${RESET} it     — into BOOTSEL, from here"
say ""
say "Not one of them was written for this experiment. All three are embedded"
say "from the experiment that owns them, and ${DIM}check.sh${RESET} fails if a copy ever"
say "appears in this directory. What is new here is the ${BOLD}composition${RESET}."
say ""
say "${BOLD}FLASH.HTM${RESET} is exp117's page under a name that says what you want from it."
say "In a file listing beside the other two, \"reboot\" does not answer ${DIM}into what?${RESET}"

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
echo "${GREEN}${BOLD}exp131 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. A phone that has this board has everything, permanently. Nothing on"
say "     that drive has to be downloaded, including the page that puts the"
say "     board back into its bootloader."
say "  2. Carrying the flash page is a property of the ${BOLD}chain${RESET}, not of one"
say "     build. Flash something that omits it and the way back is gone —"
say "     which you find out at the worst possible moment. check.sh asserts it."
say "  3. exp130 argued that the log is the second view. On a phone that was"
say "     advice nobody could follow until LOG.HTM was on the volume."
say ""
say "And not one of the three pages was written here. They are embedded from"
say "the experiments that own them, so a page cannot exist in two versions."
say ""
say "Cost: 79 of 125 clusters. The log viewer is half of it. A board with less"
say "SRAM has to choose — and the rule above says which one is not on the list."
