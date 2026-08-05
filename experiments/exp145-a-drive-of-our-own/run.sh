#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp145 interactive walkthrough — serve a volume, accept a dropped .uf2, and
# write it into the half of the A/B pair that is not running.
#
# The last item on the update road, and the control the road was built to
# measure against: exp144 established that the ROM's own drive will not take a
# file once a partition table exists. This one takes it.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
EXP="$(pwd)"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp145-a-drive-of-our-own

build_version() { # major out.uf2
    EXP145_MAJOR="$1" EXP145_MINOR=0 cargo build --release --quiet
    elf2flash convert -b rp2350 "$ELF" "$2" > /dev/null 2>&1
}
version_now() { yi26 port --json 2>/dev/null | sed -n 's/.*"product":"\([^"]*\)".*/\1/p'; }
volume_dev() { lsblk -no PATH,LABEL | awk '$2=="DROP-A-UF2"{print $1; exit}'; }
volume_mount() {
    local dev; dev="$(volume_dev)"
    [[ -n "$dev" ]] || return 1
    udisksctl mount -b "$dev" > /dev/null 2>&1 || true
    lsblk -no MOUNTPOINT "$dev" | grep -v '^$' | head -1
}
# Drop a file and wait for the board to come back on a new version. The device
# vanishes mid-write on purpose — it reboots as soon as the last UF2 block
# arrives, which is exactly what the ROM's own drive does when it accepts one.
drop() { # file
    local m; m="$(volume_mount)" || { say "  ${RED}no DROP-A-UF2 volume${RESET}"; return 1; }
    say "  volume at $m"
    cp "$1" "$m/" 2>/dev/null || true
    sync 2>/dev/null || true
    for _ in $(seq 1 40); do
        sleep 0.5
        [[ -n "$(version_now)" ]] && break
    done
}

echo "${BOLD}exp145 — a drive of our own${RESET}"
say ""
say "exp144 asked the ROM where a dropped file belongs and got the right answer,"
say "and then dropped one and watched the ROM's drive refuse it — because there"
say "was a partition table. This serves the volume itself and does the write."

# ---------------------------------------------------------------------------
step 1 "What is being built"
say ""
say "An ordinary application, running from one half of an A/B pair, that also"
say "presents a small FAT12 volume. It keeps ${BOLD}three sectors${RESET} — boot sector, FAT,"
say "root directory — and no disk at all. Every other sector the host writes is"
say "read for UF2 blocks and thrown away."
say ""
say "It knows the file is complete because ${DIM}UF2 blocks carry blockNo/numBlocks${RESET}."
say "Nothing on the wire says a file was closed; exp137 is the record of how"
say "little a host will tell a device. The file format says it instead."

# ---------------------------------------------------------------------------
step 2 "Build v1.0 and v2.0, and flash the pair"
say ""
run_cmd bash -c "cd '$EXP' && EXP145_MAJOR=1 EXP145_MINOR=0 cargo build --release --quiet && elf2flash convert -b rp2350 '$ELF' target/v1.uf2 >/dev/null 2>&1 && echo 'built v1.0'"
run_cmd bash -c "cd '$EXP' && EXP145_MAJOR=2 EXP145_MINOR=0 cargo build --release --quiet && elf2flash convert -b rp2350 '$ELF' target/v2.uf2 >/dev/null 2>&1 && echo 'built v2.0'"
( cd ../../tools/partimg && cargo run --quiet -- ab "$EXP/target/v1.uf2" "$EXP/target/v2.uf2" "$EXP/target/exp145-ab.uf2" )
confirm "Flash the A/B pair over PICOBOOT?" || { say ""; say "Nothing was flashed."; exit 0; }
run_cmd yi26 bootsel
run_cmd yi26 pflash target/exp145-ab.uf2
sleep 5
say ""
say "  running now: ${BOLD}$(version_now)${RESET}"
run_cmd yi26 log --seconds 6

# ---------------------------------------------------------------------------
step 3 "Drop v3.0 on it"
say ""
say "An ordinary .uf2, no placement, no slot in the name — the same file exp144"
say "handed to the ROM's drive and had refused."
build_version 3 target/v3.uf2
say "  built v3.0 ($(stat -c%s target/v3.uf2) bytes)"
confirm "Copy it onto the DROP-A-UF2 volume?" || { say ""; say "Nothing was dropped."; exit 0; }
say ""
drop target/v3.uf2
say ""
say "  running now: ${BOLD}$(version_now)${RESET}"
run_cmd yi26 log --seconds 6
say ""
say "The version changed and the partition changed with it. The firmware that"
say "was running wrote the new one into the half it was not in, and rebooted;"
say "the ROM picked the higher version, which is exp142 doing the last step."

# ---------------------------------------------------------------------------
step 4 "Again — and watch it alternate"
say ""
say "The half that is now free is the one that was running a minute ago."
build_version 4 target/v4.uf2
say "  built v4.0"
confirm "Drop v4.0 too?" || { say ""; say "Left on v3.0."; exit 0; }
say ""
drop target/v4.uf2
say ""
say "  running now: ${BOLD}$(version_now)${RESET}"
run_cmd yi26 log --seconds 6

# ---------------------------------------------------------------------------
step 5 "What it cost, and what it cannot do"
say ""
say "Against the ROM's own path, which is free and already in the chip:"
say ""
say "  · about ${BOLD}4.5 KiB${RESET} more flash than the same firmware without the volume"
say "  · ${BOLD}67 KiB${RESET} of SRAM — 1.5 for the filesystem, 64 for the staged image"
say "  · around ${BOLD}390 lines${RESET} over a plain firmware, most of them SCSI"
say ""
say "And the thing worth writing on the wall: this updater lives ${BOLD}inside the"
say "application${RESET}. If the running firmware is broken, there is no volume, no"
say "SCSI, and no way in — while the ROM's BOOTSEL is there whatever you have"
say "done to flash. A hand-rolled bootloader buys you the write the ROM refused,"
say "and it costs you the one guarantee the ROM was giving you for free."
