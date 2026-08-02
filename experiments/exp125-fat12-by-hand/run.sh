#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp125 interactive walkthrough — write a filesystem by hand and watch a
# host mount it.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp125-fat12-by-hand
UF2=target/exp125-fat12-by-hand.uf2
MODEL="exp125 fat12"

find_dev() {
    for d in /sys/block/*/; do
        [[ -r "$d/device/model" ]] || continue
        local m; m="$(cat "$d/device/model" 2>/dev/null)"
        [[ "${m%"${m##*[![:space:]]}"}" == "$MODEL" ]] && basename "$d" && return 0
    done
    return 1
}

echo "${BOLD}exp125 — a filesystem written by hand${RESET}"
say ""
say "exp124 offered 64 KiB of zeros and the host mounted nothing, because a"
say "sector of zeros is not an empty filesystem — it is the absence of one."
say "This writes the bytes that make it a filesystem."
say ""
say "There is no filesystem driver here. Nothing parses paths or allocates"
say "clusters. A boot sector, one FAT and a root directory are laid into an"
say "array at boot, and the host does all the interpreting. That is the claim"
say "worth taking away: ${BOLD}a filesystem is an arrangement of bytes that other"
say "software has agreed to read.${RESET}"

# ---------------------------------------------------------------------------
step 1 "Check the arithmetic before it reaches a board"
say ""
say "The part most likely to be wrong is the 12-bit packing, where two entries"
say "share three bytes. A mistake there makes a volume that mounts and is"
say "${BOLD}wrong${RESET}, which is worse than one that fails — so it is tested here, on"
say "this machine, with no hardware involved."
say ""
run_cmd sh -c "cd ../../crates/fat12 && cargo test"

# ---------------------------------------------------------------------------
step 2 "Build and flash"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
run_cmd yi26 flash "$UF2"
sleep 4

# ---------------------------------------------------------------------------
step 3 "What the firmware says it built"
say ""
run_cmd yi26 log --seconds 5
say ""
say "${BOLD}125 clusters.${RESET} That number, not the string \"FAT12\" in the boot sector, is"
say "what makes this FAT12: a host counts the clusters — total sectors, minus"
say "reserved, FAT and root-directory sectors — and under 4085 means twelve-bit"
say "entries. The string is documentation for people."

# ---------------------------------------------------------------------------
step 4 "What the host makes of it"
say ""
if DEV="$(find_dev)"; then
    run_cmd lsblk -o NAME,VENDOR,MODEL,SIZE,FSTYPE,LABEL,MOUNTPOINT "/dev/$DEV"
    say ""
    say "${DIM}FSTYPE${RESET} was empty in exp124 and is ${BOLD}vfat${RESET} now. ${DIM}LABEL${RESET} came out of the"
    say "volume-label directory entry — not the copy in the boot sector, which"
    say "most software ignores, which is why the layout writes both."
    say ""
    MP="$(lsblk -no MOUNTPOINT "/dev/$DEV" 2>/dev/null | head -1)"
    if [[ -z "$MP" ]]; then
        say "Not auto-mounted, so mount it:"
        run_cmd udisksctl mount -b "/dev/$DEV"
        MP="$(lsblk -no MOUNTPOINT "/dev/$DEV" 2>/dev/null | head -1)"
    fi
    if [[ -n "$MP" ]]; then
        say ""
        run_cmd ls -la "$MP"
        say ""
        run_cmd cat "$MP/README.TXT"
    fi
else
    bad "No block device appeared."
fi

# ---------------------------------------------------------------------------
step 5 "The timestamp is not the time you wrote"
say ""
say "The firmware stamps ${BOLD}12:00${RESET} into that file. Look at what is displayed."
say ""
say "FAT has no timezone field — it stores wall-clock digits and nothing about"
say "which wall. Whatever reads the volume applies its own idea of an offset,"
say "so the same bytes show a different time on a different machine. Worth"
say "knowing before treating a FAT timestamp as a fact."

# ---------------------------------------------------------------------------
step 6 "Unmount before anything reboots"
say ""
say "Pulling a mounted filesystem out from under a host produces errors that"
say "have nothing to do with the experiment."
say ""
if DEV="$(find_dev)"; then
    run_cmd udisksctl unmount -b "/dev/$DEV" || say "  ${DIM}(already unmounted)${RESET}"
fi
run_cmd yi26 bootsel
if in_bootsel; then
    ok "In BOOTSEL, with a filesystem still declared moments earlier."
    run_cmd yi26 flash "$UF2"
else
    bad "It did not reboot — that is the failure this step exists to catch."
fi

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp125 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. A filesystem is bytes in an agreed arrangement. Nothing on this"
say "     board parses a path or allocates a cluster."
say "  2. The format is decided by arithmetic, not by a label. Cluster count"
say "     under 4085 is what FAT12 means."
say "  3. Two FAT entries share three bytes, and that packing is the part"
say "     worth testing on a machine where you can see the failure."
say "  4. Every field constrains the others. Reserved sectors, FAT size and"
say "     root entries decide where the data begins, and a wrong one produces"
say "     a volume that mounts and lies."
say ""
say "Next: ${BOLD}exp126${RESET} puts exp116's page on this volume as INDEX.HTM. Plug the"
say "board into anything with a browser and its debug interface is already"
say "there — which closes a loop that opened in exp101."
