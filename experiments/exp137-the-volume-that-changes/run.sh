#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp137 interactive walkthrough — the volume is laid down again while the
# host is looking at it, and the host is told.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp137-the-volume-that-changes
UF2=target/exp137.uf2

find_dev() {
    lsblk -o NAME,MODEL -nr | awk '$2 ~ /exp137/ {print "/dev/" $1; exit}'
}

echo "${BOLD}exp137 — a volume that changes while you are looking at it${RESET}"
say ""
say "Every volume this repository has served was laid down once at boot and"
say "never touched again. ${DIM}docs/platforms.md${RESET} says why, and names what is"
say "missing: a device that changes a file after the host has mounted the"
say "volume is fighting the host's cache, and real devices answer that with a"
say "media-change signal — SCSI ${BOLD}UNIT ATTENTION${RESET}."
say ""
say "This repository has never sent one. This firmware does."

# ---------------------------------------------------------------------------
step 1 "Build and flash"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
run_cmd yi26 flash "$UF2"
ok "Serving a volume with a generation number on it."

# ---------------------------------------------------------------------------
step 2 "Mount it and read the file that will change"
sleep 2
DEV="$(find_dev)"
if [[ -z "$DEV" ]]; then
    warn "No block device appeared for this board."
    exit 1
fi
run_cmd udisksctl mount -b "$DEV"
MP="$(findmnt -n -o TARGET "$DEV" | head -1)"
run_cmd cat "$MP/STATUS.TXT"
say ""
say "Generation 1. The host has now read it, which is the part that matters:"
say "from here on it has an opinion about what that file says."

# ---------------------------------------------------------------------------
step 3 "Change the volume underneath it"
say ""
say "One byte on the serial port. The firmware lays the ${BOLD}whole volume${RESET} down"
say "again — not just the file — because that is what the signal it is about"
say "to send actually claims."
say ""
run_cmd yi26 send b --seconds 8
say ""
say "Read that log from the top. The board reported the change on the very"
say "next command, and then watch what the host does with it:"
say ""
say "  ${BOLD}UNIT ATTENTION (06/28)${RESET}   the medium may have changed"
say "  ${BOLD}REQUEST SENSE${RESET}            the host asks why, and is told"
say "  ${BOLD}READ CAPACITY${RESET}            it re-reads how big the disk is"
say "  ${BOLD}READ(10) × 6${RESET}             boot sector, FAT, root directory, data"
say ""
say "The host did everything right. It believed the device completely."

# ---------------------------------------------------------------------------
step 4 "So read the file again"
run_cmd cat "$MP/STATUS.TXT"
say ""
say "${BOLD}Unchanged.${RESET} Same generation, same timestamp."
say ""
say "That is the finding, and it is not a bug in anything. ${BOLD}UNIT ATTENTION is"
say "a notification, not an invalidation.${RESET} The block layer honoured it in"
say "full; the filesystem above it had already decided what those bytes say,"
say "and its page cache is the whole reason mounting was fast."

# ---------------------------------------------------------------------------
step 5 "Prove the bytes really moved"
run_cmd udisksctl unmount -b "$DEV"
run_cmd udisksctl mount -b "$DEV"
MP="$(findmnt -n -o TARGET "$DEV" | head -1)"
run_cmd cat "$MP/STATUS.TXT"
say ""
say "Generation 2. It was there the whole time."

# ---------------------------------------------------------------------------
step 6 "What this settles"
say ""
say "  ${BOLD}1.${RESET} The signal works, and a Linux host acts on all of it."
say "  ${BOLD}2.${RESET} A mounted file's contents still do not change."
say "  ${BOLD}3.${RESET} A volume whose contents are correct ${BOLD}at every mount${RESET} is a real"
say "     capability, and it is a smaller one than it sounds."
say ""
say "For ${DIM}docs/platforms.md${RESET} that is a qualified answer: the log can come"
say "back as a file, if whoever is reading it unmounts between reads. On a"
say "phone that is a person pulling down a notification shade — which is not"
say "the zero-friction return path that page was hoping for."
say ""
run_cmd udisksctl unmount -b "$DEV"
say "${DIM}./check.sh${RESET} asserts both answers separately, and prints a NOTE rather"
say "than a failure if your host answers the second one differently."
