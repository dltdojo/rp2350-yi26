#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp122 interactive walkthrough — an interface no operating system claims.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp122-vendor-bulk
UF2=target/exp122-vendor-bulk.uf2

drivers() {
    for i in /sys/bus/usb/devices/*:1.*/; do
        [[ -e "$i/../idVendor" ]] || continue
        [[ "$(cat "$i/../idVendor" 2>/dev/null)" == "1209" ]] || continue
        if [[ -L "$i/driver" ]]; then
            printf "    %-12s class=0x%s  %s\n" "$(basename "$i")" \
                "$(cat "$i/bInterfaceClass")" "$(basename "$(readlink "$i/driver")")"
        else
            printf "    %-12s class=0x%s  ${BOLD}(no driver bound)${RESET}\n" \
                "$(basename "$i")" "$(cat "$i/bInterfaceClass")"
        fi
    done
}

echo "${BOLD}exp122 — an interface nobody claims${RESET}"
say ""
say "Every interface so far has had a ${BOLD}class${RESET}: CDC-ACM since exp104, HID in"
say "exp121. A class is a promise about behaviour, and an operating system that"
say "recognises the promise loads a driver and takes the interface. That is"
say "where ${DIM}/dev/ttyACM0${RESET} comes from — and it is also why exp116 has to run"
say "${DIM}yi26 detach${RESET} before a browser can have the port."
say ""
say "This one declares class ${BOLD}0xFF${RESET}: vendor specific, which is USB for ${DIM}no"
say "promise at all${RESET}. Nothing knows what to do with it, so nothing claims it."

# ---------------------------------------------------------------------------
step 1 "Build and flash"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
run_cmd yi26 flash "$UF2"

# ---------------------------------------------------------------------------
step 2 "Ask the kernel which interfaces it took"
say ""
say "Not the firmware's opinion. The operating system's, out of sysfs:"
say ""
drivers
say ""
say "Two interfaces claimed, one left alone. Nothing to detach, and nothing"
say "given up to use it."

# ---------------------------------------------------------------------------
step 3 "Talk to the interface nobody owns"
say ""
say "There is no ${DIM}/dev${RESET} entry for a vendor interface, so there is nothing for a"
say "shell to redirect into. Talking to it means claiming the interface and"
say "submitting bulk transfers — ${DIM}yi26 echo --explain${RESET} says why that has no"
say "one-liner."
say ""
run_cmd yi26 echo "hello vendor"
say ""
say "Uppercased on the way back, deliberately. A plain echo cannot tell a"
say "firmware that handled your bytes from a host stack that looped them back"
say "somewhere below; a change only this firmware makes can."

# ---------------------------------------------------------------------------
step 4 "The part worth staying for"
say ""
say "The serial port never went anywhere:"
say ""
run_cmd ls /dev/ttyACM0
say ""
say "So both halves work at once. Watch the CDC log report vendor traffic while"
say "the kernel still owns the CDC pair:"
say ""
( yi26 log --seconds 6 2>/dev/null | sed 's/^/    /' ) &
LOGGER=$!
sleep 2
yi26 echo "two owners" > /dev/null 2>&1
wait "$LOGGER" 2>/dev/null || true
say ""
say "That ${DIM}echo #N${RESET} line arrived over CDC, which the kernel is driving, and"
say "describes traffic on an interface a userspace program is driving. Neither"
say "had to wait for the other."

# ---------------------------------------------------------------------------
step 5 "For contrast, exp116's route"
say ""
say "What it costs to take a ${BOLD}class${RESET} interface from its driver:"
say ""
run_cmd yi26 detach
run_cmd ls /dev/ttyACM0 || say "  ${DIM}...gone, for as long as anything else holds those interfaces.${RESET}"
run_cmd yi26 attach
say ""
say "That is the trade this experiment removes."

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp122 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. Class 0xFF means no promise, which means no driver, which means"
say "     nothing to displace before you can use the interface."
say "  2. A device can have both: an interface the operating system drives and"
say "     one it will not touch, working at the same time."
say "  3. Without a class there is no library either. Two raw endpoints, and"
say "     what arrives is what the endpoint gives you."
say ""
say "Next: ${BOLD}exp123${RESET} declares a mass-storage interface and answers nothing —"
say "just decodes and prints the command blocks the host sends, which is the"
say "first look at what a disk is actually asked to do."
