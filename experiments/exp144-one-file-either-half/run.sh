#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp144 interactive walkthrough — ask the ROM where a dropped file would go,
# then drop one and find out what it actually does.
#
# The asking half works and is the useful half. The dropping half is where this
# experiment turns into a measurement of something else: a board with a
# partition table does not consume a UF2 written to its BOOTSEL drive at all.
# Both halves are here because the second is the reason the first matters.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
EXP="$(pwd)"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp144-one-file-either-half

build_version() { # major out.uf2
    EXP144_MAJOR="$1" EXP144_MINOR=0 cargo build --release --quiet
    elf2flash convert -b rp2350 "$ELF" "$2" > /dev/null 2>&1
}
version_now() { yi26 port --json 2>/dev/null | sed -n 's/.*"product":"\([^"]*\)".*/\1/p'; }
# Does the drive still hold the file after a remount? The ROM consumes a UF2 it
# accepts and reboots; a file that is still listed was never taken, and a
# remount is what tells the difference — the host's own cache will show it
# either way until the filesystem is re-read.
survives_remount() { # returns 0 if the file is still there after a remount
    local dev
    dev="$(lsblk -no PATH,LABEL | awk '$2=="RP2350"{print $1; exit}')"
    [[ -n "$dev" ]] || return 1
    udisksctl unmount -b "$dev" > /dev/null 2>&1 || true
    udisksctl mount -b "$dev" > /dev/null 2>&1 || true
    sleep 1
    ls /media/*/RP2350/*.uf2 > /dev/null 2>&1
}

echo "${BOLD}exp144 — one file, either half${RESET}"
say ""
say "The question the whole update road came from: a user drops ${BOLD}one${RESET} file, and"
say "the correct half of an A/B pair is written — no for_slotA in the filename."

# ---------------------------------------------------------------------------
step 1 "Build an A/B pair and flash it"
say ""
say "Same source, two versions, no slot letter anywhere in the build. v2.0 is"
say "higher, so the ROM boots it — exp142's result, reused as the ground here."
run_cmd bash -c "cd '$EXP' && EXP144_MAJOR=1 EXP144_MINOR=0 cargo build --release --quiet && elf2flash convert -b rp2350 '$ELF' target/v1.uf2 >/dev/null 2>&1 && echo 'built v1.0'"
run_cmd bash -c "cd '$EXP' && EXP144_MAJOR=2 EXP144_MINOR=0 cargo build --release --quiet && elf2flash convert -b rp2350 '$ELF' target/v2.uf2 >/dev/null 2>&1 && echo 'built v2.0'"
( cd ../../tools/partimg && cargo run --quiet -- ab "$EXP/target/v1.uf2" "$EXP/target/v2.uf2" "$EXP/target/exp144-ab.uf2" )
confirm "Flash the A/B image?" || { say ""; say "Nothing was flashed."; exit 0; }
run_cmd yi26 bootsel
run_cmd yi26 pflash target/exp144-ab.uf2
sleep 4
say "  running now: ${BOLD}$(version_now)${RESET}"

# ---------------------------------------------------------------------------
step 2 "Ask the ROM where a dropped file would go"
say ""
say "Two calls, and neither needs a drive. ${DIM}get_uf2_target_partition${RESET} answers"
say "the routing question from the table alone; ${DIM}pick_ab_parition${RESET} names the half"
say "holding the better image, which is the half that is running."
run_cmd yi26 log --seconds 8
say ""
say "The ROM knows the answer: the running half is 1, and a dropped .uf2 goes"
say "to partition 0. ${BOLD}That is the right answer${RESET} — the other half."

# ---------------------------------------------------------------------------
step 3 "Now actually drop one"
say ""
say "A third build, v3.0, as an ordinary .uf2 — no partimg, no placement, no"
say "slot in the name. Exactly what a user would be handed."
build_version 3 target/v3.uf2
say "  built v3.0 ($(stat -c%s target/v3.uf2) bytes, addressed at 0x10000000)"
confirm "Copy it onto the BOOTSEL drive?" || { say ""; say "Nothing was dropped."; exit 0; }
say ""
set +e
yi26 flash target/v3.uf2
FLASH_RC=$?
set -e
sleep 3
say ""
say "  running now: ${BOLD}$(version_now)${RESET}   (yi26 flash exit code: $FLASH_RC)"
if [[ "$(version_now)" == *"v3.0"* ]]; then
    say ""
    say "${BOLD}It landed.${RESET} Compare the running partition in the log with the one the"
    say "ROM predicted above."
    run_cmd yi26 log --seconds 8
else
    say ""
    say "${BOLD}It did not land.${RESET} The board is still in BOOTSEL and the version did not"
    say "change. This is the measured result, not a mistake in the copy:"
    if survives_remount; then
        say "  the file is ${BOLD}still on the drive after a remount${RESET} — unexpected; the ROM"
        say "  neither consumed it nor discarded it."
    else
        say "  the file ${BOLD}vanished on remount${RESET} — the host's FAT cache was showing a"
        say "  write the board never took. exp137's lesson, one layer down."
    fi
    say ""
    say "The control that makes this a finding rather than a broken cable: erase"
    say "the table and the identical file flashes. Step 4."
fi

# ---------------------------------------------------------------------------
step 4 "The control — the same file, with no partition table"
say ""
say "${DIM}yi26 nuke${RESET} erases the first 64 KiB, table and all. Then a plain image is"
say "flashed over PICOBOOT so there is something to run, and the same v3.0 file"
say "is dropped on the same drive by the same command."
confirm "Erase the table and repeat the drop?" || { say ""; say "Left as is."; exit 0; }
run_cmd yi26 nuke
sleep 2
run_cmd yi26 pflash target/v1.uf2
sleep 4
say "  running now: ${BOLD}$(version_now)${RESET}"
run_cmd yi26 flash target/v3.uf2
sleep 3
say ""
say "  running now: ${BOLD}$(version_now)${RESET}"
say ""
say "Same host, same cable, same drive, same file, same command — and with no"
say "partition table it flashes. So the drop that failed above failed ${BOLD}because${RESET}"
say "the board had a table, which is the opposite of what the road expected:"
say "the table is what makes A/B routing possible, and it is also what stops"
say "the drive from taking a file at all."
say ""
say "Put the pair back with ${DIM}yi26 bootsel && yi26 pflash target/exp144-ab.uf2${RESET}"
say "when you want the A/B board again."
