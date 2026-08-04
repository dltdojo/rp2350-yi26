#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp139 interactive walkthrough — put a partition table where the ROM looks,
# and move the firmware out of its way.
#
# This is the first script in this repository that can leave a board that does
# not boot, and — measured on 2026-08-04 — it costs a physical BOOTSEL press to
# recover. The ROM launches the sector-1 image, it crashes before USB, and the
# board goes dark: no application firmware and no BOOTSEL, so PICOBOOT cannot
# reach it. Only unplug/hold/replug brings it back; then `yi26 nuke` +
# `yi26 pflash` restore a known-good image.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp139-a-table-of-one
UF2=target/exp139.uf2

echo "${BOLD}exp139 — a table of one${RESET}"
say ""
say "exp138 asked a stock board what it knew about firmware slots: the"
say "machinery is in the ROM, and there is nothing in it. This puts the"
say "smallest possible something in it — one partition, no A/B."

# ---------------------------------------------------------------------------
step 1 "The thing nobody tells you first"
say ""
say "The ROM looks for a block loop at ${BOLD}flash offset 0${RESET}. That is either your"
say "firmware's IMAGE_DEF or a partition table. ${BOLD}They cannot both be there.${RESET}"
say ""
say "  ${DIM}before${RESET}                         ${DIM}after${RESET}"
say "  image at 0x10000000            table at 0x10000000"
say "                                 image at 0x10001000"
say ""
say "So writing a table is not adding one. It is ${BOLD}moving your firmware${RESET}."

# ---------------------------------------------------------------------------
step 2 "The words, checked before anything is flashed"
run_cmd bash -c "cd ../../crates/partition-table && cargo test --quiet 2>&1 | tail -3"
say ""
say "Eight words go to flash offset 0. A wrong one produces a board that does"
say "not boot and ${BOLD}cannot say why${RESET} — no log, no USB, no error. That is the"
say "least debuggable failure in this repository, so the check for it runs"
say "here, on your machine, rather than on the board."

# ---------------------------------------------------------------------------
step 3 "Build, and look at where things landed"
run_cmd cargo build --release
run_cmd bash -c "readelf -S $ELF | grep -E 'partition_table|vector_table|start_block'"
say ""
say "The table at ${BOLD}0x10000000${RESET}, the image at ${BOLD}0x10001000${RESET}. Nothing was"
say "installed to do that: a memory.x of our own, and a linker section."
say "${DIM}picotool partition create${RESET} is the usual answer and it was not needed."
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"

# ---------------------------------------------------------------------------
step 4 "What flashing this costs if it is wrong"
say ""
say "If the ROM accepts the table and boots the image, USB comes back and"
say "nothing about your workflow changes. ${BOLD}It did not.${RESET} Measured on 2026-08-04:"
say "the ROM launched the sector-1 image, it crashed before USB, and the board"
say "went ${BOLD}dark${RESET} — no application firmware and ${BOLD}no BOOTSEL${RESET}. So PICOBOOT cannot"
say "reach it, and the recovery is a ${BOLD}physical BOOTSEL press${RESET}:"
say ""
say "  ${BOLD}1.${RESET} unplug, ${BOLD}2.${RESET} hold BOOTSEL, ${BOLD}3.${RESET} replug, ${BOLD}4.${RESET} release"
say "  then ${BOLD}yi26 nuke${RESET} and ${BOLD}yi26 pflash exp138.uf2${RESET} to restore a known-good image"
say ""
say "This flashes with ${BOLD}yi26 pflash${RESET}, not ${DIM}yi26 flash${RESET}, so the result is readable:"
say "PICOBOOT writes the UF2's absolute addresses raw, table and image where they"
say "are addressed, instead of letting the drive route blocks by UF2 family. That"
say "is why the dark board means ${DIM}the image cannot run where it is${RESET} and not"
say "${DIM}the drive put it elsewhere${RESET} — see the README's ${DIM}Expected output${RESET}."
say ""
confirm "Flash it?" || { say ""; say "Nothing was flashed. The UF2 is at ${DIM}$UF2${RESET} when you want it."; exit 0; }

run_cmd yi26 bootsel
run_cmd yi26 pflash "$UF2"

# ---------------------------------------------------------------------------
step 5 "What the board does now — and what it should do once fixed"
say ""
say "${BOLD}As of 2026-08-04 the board goes dark here.${RESET} The image is linked to run"
say "in place at 0x10001000, but the ROM remaps a booted partition's start to the"
say "XIP base 0x10000000, so it faults on its first absolute address. Expect no"
say "log below, and recover with the physical BOOTSEL press from step 4."
say ""
if yi26_state=$(yi26 state 2>/dev/null); [ "$yi26_state" = running ]; then
    run_cmd yi26 log --seconds 8
    say ""
    say "It booted — so this image is fixed. The success reading is exp138's"
    say "instrument, unchanged: a non-zero partition count, one partition over"
    say "sectors 1..1023, and ${DIM}get_b_partition(0)${RESET} still negative (one partition"
    say "has no B side) — the control for the experiment after this."
else
    say "Board state: ${BOLD}${yi26_state:-absent}${RESET}. If it is dark, do the BOOTSEL"
    say "press, then: ${DIM}yi26 nuke && yi26 pflash ../exp138-what-the-rom-already-knows/target/exp138.uf2${RESET}"
fi
