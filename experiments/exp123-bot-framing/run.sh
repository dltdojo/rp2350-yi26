#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp123 interactive walkthrough — declare a disk, answer nothing, and read
# what a host asks one.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp123-bot-framing
UF2=target/exp123-bot-framing.uf2

echo "${BOLD}exp123 — what a host asks a disk${RESET}"
say ""
say "The board declares a mass-storage interface and declines every command it"
say "receives, printing each one first. Nothing here pretends to be a disk."
say "The point is to read the interrogation."
say ""
say "USB mass storage has almost no protocol: a 31-byte ${BOLD}Command Block Wrapper${RESET}"
say "out, an optional data phase, a 13-byte ${BOLD}Command Status Wrapper${RESET} back. The"
say "SCSI command sits inside the wrapper — the same SCSI that talks to a hard"
say "disk over a cable with nothing to do with USB."

# ---------------------------------------------------------------------------
step 1 "Build and flash"
say ""
say "Flashing re-enumerates the board, which is what makes the host interrogate"
say "it. The commands below arrive in the first two seconds after this."
say ""
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
run_cmd yi26 flash "$UF2"

# ---------------------------------------------------------------------------
step 2 "What it was asked"
say ""
run_cmd yi26 log --seconds 6
say ""
say "${BOLD}INQUIRY${RESET}, then ${BOLD}REQUEST SENSE${RESET}, four times over, and then silence."
say ""
say "That pairing is how an operating system thinks. It asks what you are; the"
say "answer fails; it asks ${DIM}why did that fail${RESET}; that fails too, so it learns"
say "nothing and tries again. After four rounds it concludes there is no usable"
say "medium and stops. The whole exchange takes under a second."

# ---------------------------------------------------------------------------
step 3 "What the kernel did about it"
say ""
say "Not the firmware's account — the operating system's:"
say ""
for i in /sys/bus/usb/devices/*:1.*/; do
    [[ -e "$i/../idVendor" ]] || continue
    [[ "$(cat "$i/../idVendor" 2>/dev/null)" == "1209" ]] || continue
    if [[ -L "$i/driver" ]]; then
        printf "    %-12s class=0x%s  %s\n" "$(basename "$i")" \
            "$(cat "$i/bInterfaceClass")" "$(basename "$(readlink "$i/driver")")"
    else
        printf "    %-12s class=0x%s  (no driver bound)\n" \
            "$(basename "$i")" "$(cat "$i/bInterfaceClass")"
    fi
done
say ""
for h in /sys/bus/usb/devices/*:1.*/host*; do
    [[ -e "$h" ]] || continue
    say "    $(basename "$h") exists, with ${BOLD}$(ls -d "$h"/target* 2>/dev/null | wc -l)${RESET} targets under it"
done
say ""
say "That is the result in one number. Declaring the ${BOLD}class${RESET} was enough for the"
say "kernel to load its storage driver and build a SCSI host; answering nothing"
say "was enough for the host to find no disk to put in it. Compare exp122,"
say "where the vendor interface has no driver at all — a class is an invitation."

# ---------------------------------------------------------------------------
step 4 "Why 'answer nothing' is not literally nothing"
say ""
say "The plan for this experiment said ${DIM}answer nothing${RESET}. Taken literally that is"
say "dangerous rather than minimal: a host whose bulk transfer never completes"
say "waits, times out, issues a mass-storage reset, retries, and eventually"
say "resets the whole USB device — ${BOLD}taking the CDC interface with it${RESET}, on a"
say "loop, and turning reflashing into a matter of catching a gap."
say ""
say "Stalling the endpoint is the specification's answer, and this driver does"
say "not offer it: ${DIM}endpoint_set_stalled${RESET} lives on the Bus, which ${DIM}UsbDevice::run()${RESET}"
say "owns."
say ""
say "So the reply is a ${BOLD}well-formed refusal${RESET}: end the data phase with a"
say "zero-length packet, then a status wrapper saying ${DIM}Command Failed${RESET} with the"
say "full length as residue. Every phase completes, nothing waits, and the host"
say "gives up politely. The evidence that it worked is above — four rounds in"
say "under a second, and this port still here:"
say ""
run_cmd ls /dev/ttyACM0

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp123 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. Mass storage is three phases and two structures. Everything a USB"
say "     stick does is those, repeated."
say "  2. Declaring a class invites a driver in. exp122 declared none and got"
say "     none; this declared 0x08 and the kernel arrived with usb-storage."
say "  3. A host decides whether a disk exists by asking, not by being told."
say "     Four INQUIRY attempts, no answers, no disk."
say "  4. Refusing well is a design decision. Silence would have been the"
say "     literal reading of the plan and the wrong thing to build."
say ""
say "Next: ${BOLD}exp124${RESET} starts answering — enough INQUIRY and READ CAPACITY for the"
say "host to agree a disk is there. No filesystem yet; an unformatted volume is"
say "the goal, and the host complaining that it cannot read the partition table"
say "is what success looks like."
