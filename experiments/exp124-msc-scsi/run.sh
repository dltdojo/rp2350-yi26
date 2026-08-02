#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp124 interactive walkthrough — answer enough SCSI that the host agrees a
# disk is there.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp124-msc-scsi
UF2=target/exp124-msc-scsi.uf2
MODEL="exp124 ram disk"

find_dev() {
    for d in /sys/block/*/; do
        [[ -r "$d/device/model" ]] || continue
        local m; m="$(cat "$d/device/model" 2>/dev/null)"
        [[ "${m%"${m##*[![:space:]]}"}" == "$MODEL" ]] && basename "$d" && return 0
    done
    return 1
}

echo "${BOLD}exp124 — enough answers that the host agrees a disk is there${RESET}"
say ""
say "exp123 refused everything and the kernel built a SCSI host with nothing in"
say "it. This answers."
say ""
say "${BOLD}Wrong answers are worse than refusals.${RESET} exp123's risk was a host left"
say "waiting; this one's is a host that believes you. Claim a size in"
say "${DIM}READ CAPACITY${RESET} and then fail to produce those blocks, and the kernel"
say "retries and resets while the device looks perfectly healthy — much harder"
say "to diagnose than a device that plainly says no."
say ""
say "So nothing here is pretended. There is a real disk: 64 KiB of RAM, read"
say "and written for real. It forgets everything on reset, and within one power"
say "cycle it behaves exactly as it claims to."

# ---------------------------------------------------------------------------
step 1 "Build and flash"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
run_cmd yi26 flash "$UF2"
sleep 3

# ---------------------------------------------------------------------------
step 2 "The negotiation, from the firmware's side"
say ""
run_cmd yi26 log --seconds 6
say ""
say "Read the order. ${BOLD}INQUIRY${RESET} — what are you. ${BOLD}TEST UNIT READY${RESET} — is there"
say "media. ${BOLD}READ CAPACITY${RESET} — how big. ${BOLD}READ(10) lba 0${RESET} — and only then does it"
say "look at sector zero. Every question is asked because the previous one was"
say "answered, which is exactly why exp123 never got past the first."

# ---------------------------------------------------------------------------
step 3 "The same negotiation, from the host's side"
say ""
if DEV="$(find_dev)"; then
    ok "The kernel made a block device: ${BOLD}/dev/$DEV${RESET}"
    say ""
    run_cmd lsblk -o NAME,VENDOR,MODEL,SIZE,RM,FSTYPE "/dev/$DEV"
    say ""
    say "${DIM}VENDOR${RESET} and ${DIM}MODEL${RESET} are the strings from the INQUIRY response — fixed"
    say "width, space padded, which is how SCSI has always done it. ${DIM}RM${RESET} is bit 7"
    say "of the same response. ${DIM}SIZE${RESET} is READ CAPACITY having been believed."
else
    bad "No block device appeared. The host did not accept the disk."
fi

# ---------------------------------------------------------------------------
step 4 "What success looks like, which is nothing"
say ""
say "${DIM}FSTYPE${RESET} above is empty, and there is no partition line under the disk."
say ""
say "That is this experiment finishing, not falling short. Sector zero is 512"
say "zero bytes; a partition table it is not. The kernel reads it, finds"
say "nothing to report, and ${BOLD}says nothing at all${RESET} — no warning, no complaint,"
say "no error. An unformatted volume is silence, and knowing what absence looks"
say "like is part of reading a system."
say ""
say "For contrast, the drive that appears while flashing — the RP2350"
say "bootloader — ${BOLD}is${RESET} formatted, and the kernel announces its partition."

# ---------------------------------------------------------------------------
step 5 "Both halves, still"
say ""
say "It is a disk and it is still the thing reporting on itself:"
say ""
run_cmd ls /dev/ttyACM0
say ""
say "And it can still be replaced without touching a button:"
run_cmd yi26 bootsel
if in_bootsel; then
    ok "In BOOTSEL."
    run_cmd yi26 flash "$UF2"
else
    bad "It did not reboot — that is the failure this step exists to catch."
fi

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp124 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. A host decides a disk exists by asking a specific sequence, and each"
say "     question depends on the last one being answered."
say "  2. Answering is a promise. READ CAPACITY says how many blocks exist and"
say "     READ(10) has to produce them, so this disk is real RAM rather than a"
say "     number."
say "  3. Two byte orders in one packet: the transport wrapper is"
say "     little-endian, everything SCSI inside it is big-endian."
say "  4. An unformatted volume produces silence, not an error."
say ""
say "Next: ${BOLD}exp125${RESET} writes a FAT12 boot sector, a file allocation table and a"
say "root directory into those blocks by hand — and the volume mounts, with one"
say "file on it."
