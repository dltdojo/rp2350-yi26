#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp139 interactive walkthrough — put a partition table where the ROM looks,
# and move the firmware out of its way.
#
# This is the first script in this repository that can leave a board that does
# not boot. It no longer costs a hand on the button, though: a board with no
# bootable image drops into BOOTSEL by itself, and PICOBOOT (`yi26 nuke`,
# exp141's recover.html) reaches it — which is what the recovery below uses.
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
say "nothing about your workflow changes. ${BOLD}If it does not, the board does not"
say "enumerate as application firmware${RESET} — but a board that finds no bootable"
say "image drops into BOOTSEL on its own, so it comes back as ${BOLD}2e8a:000f${RESET} and"
say "PICOBOOT reaches it. On 2026-08-04 the honoured table then made the drag"
say "drive ${BOLD}refuse every dragged .uf2${RESET}, so the recovery is not a drag:"
say ""
say "  ${BOLD}yi26 nuke${RESET}   erase the table over PICOBOOT, then reflash a known-good"
say "              image with ${BOLD}yi26 pflash${RESET} — or open exp141's recover.html"
say ""
say "This flashes with ${BOLD}yi26 pflash${RESET}, not ${DIM}yi26 flash${RESET}: PICOBOOT writes the UF2's"
say "absolute addresses raw, so the table and the image land where they are"
say "addressed instead of being routed by the drive's UF2-family logic. That is"
say "the difference between ${DIM}the image did not boot${RESET} and ${DIM}the drive put it"
say "elsewhere${RESET} — see the README's ${DIM}Expected output${RESET}."
say ""
confirm "Flash it?" || { say ""; say "Nothing was flashed. The UF2 is at ${DIM}$UF2${RESET} when you want it."; exit 0; }

run_cmd yi26 bootsel
run_cmd yi26 pflash "$UF2"

# ---------------------------------------------------------------------------
step 5 "The same three questions"
say ""
say "Same instrument as exp138, deliberately: if the questions changed, a"
say "different answer would not mean anything."
say ""
run_cmd yi26 log --seconds 8
say ""
say "A non-zero partition count, one partition over sectors 1..1023 — and"
say "${DIM}get_b_partition(0)${RESET} still negative, because one partition has no B side."
say "That last one is the control for the experiment after this."
