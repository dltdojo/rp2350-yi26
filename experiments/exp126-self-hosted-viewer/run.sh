#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp126 interactive walkthrough — the board carries its own debug interface.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp126-self-hosted-viewer
UF2=target/exp126-self-hosted-viewer.uf2
MODEL="exp126 viewer"
PAGE=../exp116-webusb-cdc-log/cdc-log-viewer.html

find_dev() {
    for d in /sys/block/*/; do
        [[ -r "$d/device/model" ]] || continue
        local m; m="$(cat "$d/device/model" 2>/dev/null)"
        [[ "${m%"${m##*[![:space:]]}"}" == "$MODEL" ]] && basename "$d" && return 0
    done
    return 1
}

echo "${BOLD}exp126 — the board carries its own debug interface${RESET}"
say ""
say "Plug this board into anything with a browser and a file manager, and the"
say "page that reads its log is already on it. No download, no repository, no"
say "second computer."
say ""
say "${BOLD}This closes a loop that opened in exp101.${RESET} The ${DIM}RP2350${RESET} drive that appears"
say "when you hold BOOTSEL is not a real disk — the bootrom synthesises a FAT"
say "volume on the fly, ${DIM}INFO_UF2.TXT${RESET} and all, and ARM's DAPLink does the same"
say "with ${DIM}MBED.HTM${RESET}. exp101 used that drive without asking what it was."
say "This is what it was."

# ---------------------------------------------------------------------------
step 1 "What this needed that exp125 did not"
say ""
say "exp125's file was 324 bytes and fitted in one cluster, so its directory"
say "entry pointed at the only cluster it had and the file allocation table"
say "was never asked a question."
say ""
say "This page is ${BOLD}$(stat -c%s "$PAGE") bytes${RESET} — thirty-eight clusters — and the directory"
say "entry holds only the ${BOLD}first${RESET} of them. Following the rest is what the table"
say "is for, and it is the part worth testing where you can see it fail:"
say ""
run_cmd sh -c "cd ../../crates/fat12 && cargo test"

# ---------------------------------------------------------------------------
step 2 "Build and flash"
say ""
say "The page is embedded with ${DIM}include_bytes!${RESET} pointing at exp116's actual file."
say "Two copies of a nineteen-kilobyte page would drift, and the copy on the"
say "board is the one nobody would think to check."
say ""
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
run_cmd yi26 flash "$UF2"
sleep 4

# ---------------------------------------------------------------------------
step 3 "What came off the board"
say ""
run_cmd yi26 log --seconds 5
say ""
if DEV="$(find_dev)"; then
    MP="$(lsblk -no MOUNTPOINT "/dev/$DEV" 2>/dev/null | head -1)"
    if [[ -z "$MP" ]]; then
        run_cmd udisksctl mount -b "/dev/$DEV"
        MP="$(lsblk -no MOUNTPOINT "/dev/$DEV" 2>/dev/null | head -1)"
    fi
    if [[ -n "$MP" ]]; then
        run_cmd ls -la "$MP"
        say ""
        say "And the bytes survived thirty-eight chained clusters intact:"
        if cmp -s "$MP/INDEX.HTM" "$PAGE"; then
            ok "INDEX.HTM is byte-identical to exp116's page."
        else
            bad "INDEX.HTM differs from exp116's page — check the cluster chain."
        fi
    fi
else
    bad "No block device appeared."
fi

# ---------------------------------------------------------------------------
step 4 "Read the log through the page the board gave you"
say ""
say "On Linux the kernel's ${DIM}cdc_acm${RESET} driver owns the serial interfaces, and an"
say "interface has exactly one owner:"
say ""
run_cmd yi26 detach
say ""
if DEV="$(find_dev)"; then
    MP="$(lsblk -no MOUNTPOINT "/dev/$DEV" 2>/dev/null | head -1)"
    [[ -n "$MP" ]] && say "  Open: ${BOLD}${MP}/INDEX.HTM${RESET}"
fi
say ""
say "Open it from the file manager — double-click the drive, double-click the"
say "file. That is not a shortcut, it is ${BOLD}the${RESET} way this is meant to be used:"
say "on a phone it is the only way, and the phone is where this track has been"
say "going since exp115."
say ""
say "Then press ${BOLD}Connect and stream${RESET}."
pause "Do that, then come back."
say ""
say "Everything you just read arrived over the CDC interface, through a page"
say "that arrived over the mass-storage interface, off the same cable."

# ---------------------------------------------------------------------------
step 5 "Put it back"
if DEV="$(find_dev)"; then
    udisksctl unmount -b "/dev/$DEV" > /dev/null 2>&1 || true
fi
say "Close the browser tab first — it holds the interfaces."
pause "Closed?"
run_cmd yi26 attach || say "  ${DIM}Something still has them; 'yi26 doctor' names it.${RESET}"

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp126 complete — and so is the browser track.${RESET}"
say ""
say "What you just proved:"
say "  1. A device can carry the software that debugs it, on a volume it"
say "     synthesises out of its own RAM."
say "  2. A file longer than one cluster is why the file allocation table"
say "     exists, and a chain that is wrong in one link still mounts."
say "  3. The bootloader drive from exp101 was doing this all along."
say ""
say "The whole track, in one sentence: a phone with one USB port can now"
say "flash this board (${BOLD}exp117${RESET}), talk to it (${BOLD}exp120${RESET}), and read its log"
say "(${BOLD}exp116${RESET}) — with the page for all three coming off the board itself."
