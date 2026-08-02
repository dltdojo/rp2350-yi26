#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp121 interactive walkthrough — one cable, two functions, and what build
# order does to every number in the descriptors.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp121-composite-hid
UF2=target/exp121-composite-hid.uf2
UF2_HID_FIRST=target/exp121-hid-first.uf2

descriptors() {
    lsusb -v -d 1209:0001 2>/dev/null \
        | grep -E 'bInterfaceNumber|bInterfaceClass|bEndpointAddress' \
        | sed 's/^ *//' | sed 's/^/    /'
}

echo "${BOLD}exp121 — one cable, two functions${RESET}"
say ""
say "The board becomes a keyboard and stays the thing reporting on itself, on"
say "one cable. That is the shape a phone needs: one port, and the device"
say "under test is already in it."
say ""
say "${BOLD}This is the first experiment here that changes the USB descriptors${RESET}, and"
say "that risk is different in kind. A wrong descriptor does not misbehave —"
say "it fails to enumerate. The board draws power, appears in no listing, and"
say "the 1200-baud reflash cannot reach it because there is nothing to reach."
say "The only way back is a hand on BOOTSEL."
say ""
say "It was built in two steps for that reason: declare the keyboard and press"
say "nothing, check it enumerates and still reboots, and only then teach it to"
say "press a key. Both are in this source; the split was in the doing."

# ---------------------------------------------------------------------------
step 1 "Build and flash"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
run_cmd yi26 flash "$UF2"

# ---------------------------------------------------------------------------
step 2 "Ask the host what it thinks it is holding"
say ""
say "The firmware's opinion of its own descriptors is not evidence. This is"
say "the operating system's:"
say ""
descriptors
say ""
say "Three interfaces in two functions, each with its own Interface"
say "Association Descriptor — which is the ${DIM}0xef/0x02/0x01${RESET} triple every"
say "firmware here has set since exp104 finally doing its job."
say ""
if ls /dev/input/by-id/*exp121*event-kbd > /dev/null 2>&1; then
    ok "And Linux bound a keyboard driver: $(basename "$(ls /dev/input/by-id/*exp121*event-kbd | head -1)")"
else
    bad "No keyboard input device appeared — the host did not accept the HID interface."
fi

# ---------------------------------------------------------------------------
step 3 "Press a key"
say ""
say "Nothing is pressed unless asked. The command arrives on exp118's OUT"
say "endpoint, which is that endpoint doing a second job."
say ""
run_cmd yi26 send k
say ""
say "${BOLD}Do not go looking in xset q.${RESET} Modern desktops bind nothing to Scroll"
say "Lock, so the key arrives and the desktop ignores it — which looks exactly"
say "like the key never arriving. The kernel's input layer is where the truth"
say "is, and ${DIM}./check.sh${RESET} reads it directly."
say ""
say "Scroll Lock was chosen for that: the host records it and nothing acts on"
say "it. A device that presses ${DIM}a${RESET} presses it into whatever window has focus."

# ---------------------------------------------------------------------------
step 4 "The same firmware, built the other way round"
say ""
say "One line moved, and every number the host sees changes with it."
say ""
run_cmd cargo build --release --features hid-first
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2_HID_FIRST"
run_cmd yi26 flash "$UF2_HID_FIRST"
say ""
descriptors
say ""
say "The CDC pair moved from interfaces 0 and 1 to 1 and 2; the notification"
say "endpoint from ${DIM}0x81${RESET} to ${DIM}0x82${RESET}, the bulk IN from ${DIM}0x82${RESET} to ${DIM}0x83${RESET}. The bulk"
say "OUT kept ${DIM}0x01${RESET}, because IN and OUT endpoints are numbered separately —"
say "which is why ${DIM}0x01${RESET} and ${DIM}0x81${RESET} are not the same endpoint."
say ""
say "${BOLD}Nothing in this repository needed changing to survive that.${RESET} Watch:"
run_cmd yi26 detach
say "  ${DIM}Interfaces 1 and 2 this time, not 0 and 1 — found by class, not memory.${RESET}"
run_cmd yi26 attach
say ""
say "That is what all the insistence on reading descriptors rather than"
say "remembering them was for. It stopped being a style preference here."

# ---------------------------------------------------------------------------
step 5 "Put the default back"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
run_cmd yi26 flash "$UF2"

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp121 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. One device can be two functions, and the host drives them"
say "     separately — a keyboard and a log on the same cable."
say "  2. The IAD triple was a promise about nothing until now."
say "  3. A HID keyboard reports keys ${BOLD}held${RESET}, not keys pressed. The release"
say "     is what stops it repeating forever."
say "  4. Build order decides every interface and endpoint number, and code"
say "     that reads the descriptors does not care."
say ""
say "Next: ${BOLD}exp122${RESET} takes the class drivers away entirely — a vendor-specific"
say "interface with two bulk endpoints and no operating-system driver to claim"
say "it, which is where WebUSB stops needing anything detached first."
