#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp139 interactive walkthrough — one partition table at flash offset 0, an
# ordinary image in the partition, and the ROM booting it.
#
# The one rule that makes it work, learned the hard way (a board that went dark
# on 2026-08-04): a partition image is linked at 0x10000000 like any other,
# because the ROM remaps a booted partition's start to that address. So the
# image is built normally, and the table + placement are a post-link step
# (tools/partimg). If you moved the image instead, it would go dark and cost a
# physical BOOTSEL press to recover — see the README's "If it goes dark".
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
EXP="$(pwd)"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp139-a-table-of-one
IMG=target/exp139-image.uf2
UF2=target/exp139.uf2

echo "${BOLD}exp139 — a table of one${RESET}"
say ""
say "exp138 asked a stock board what it knew about firmware slots: the"
say "machinery is in the ROM, and there is nothing in it. This puts the"
say "smallest possible something in it — one partition, no A/B — and boots from it."

# ---------------------------------------------------------------------------
step 1 "The thing nobody tells you first"
say ""
say "The ROM looks for a block loop at ${BOLD}flash offset 0${RESET}. That is either your"
say "firmware's IMAGE_DEF or a partition table. ${BOLD}They cannot both be there.${RESET}"
say "So the table takes sector 0 and the image goes into the partition after it."
say ""
say "But a partition image is ${BOLD}not${RESET} linked where it physically sits. The ROM"
say "remaps a booted partition's start to the XIP base ${BOLD}0x10000000${RESET}, so the"
say "image is built like any ordinary firmware — linked at 0x10000000 — and only"
say "its ${BOLD}placement${RESET} changes: table at sector 0, image at sector 1."

# ---------------------------------------------------------------------------
step 2 "The words, checked before anything is flashed"
run_cmd bash -c "cd ../../crates/partition-table && cargo test --quiet 2>&1 | tail -3"
say ""
say "Eight words go to flash offset 0. A wrong one produces a board that does"
say "not boot and ${BOLD}cannot say why${RESET}. That is the least debuggable failure in"
say "this repository, so the check for it runs here, on your machine."

# ---------------------------------------------------------------------------
step 3 "Build an ordinary image, then assemble the partitioned one"
run_cmd cargo build --release
run_cmd bash -c "readelf -S $ELF | grep -E 'vector_table|start_block'"
say ""
say "Note the vector table at ${BOLD}0x10000000${RESET} — an ordinary image, not moved."
say "There is no memory.x and no partition table inside it."
run_cmd elf2flash convert -b rp2350 "$ELF" "$IMG"
say ""
say "Now ${BOLD}partimg${RESET} places the table at sector 0 and this image at sector 1."
say "${DIM}picotool partition create${RESET} is the usual answer and it was not needed."
run_cmd bash -c "cd ../../tools/partimg && cargo run --quiet -- one '$EXP/$IMG' '$EXP/$UF2'"

# ---------------------------------------------------------------------------
step 4 "Flash it over PICOBOOT"
say ""
say "This flashes with ${BOLD}yi26 pflash${RESET}: PICOBOOT writes the UF2's absolute"
say "addresses raw — table to sector 0, image to sector 1 — then REBOOT2 boots"
say "the partition. If the image had been linked at 0x10001000 instead, it would"
say "go ${BOLD}dark${RESET} here and cost a physical BOOTSEL press; the README's ${DIM}If it goes"
say "dark${RESET} has the recovery. This image is linked at 0x10000000, so it boots."
say ""
confirm "Flash it?" || { say ""; say "Nothing was flashed. The UF2 is at ${DIM}$UF2${RESET} when you want it."; exit 0; }

run_cmd yi26 bootsel
run_cmd yi26 pflash "$UF2"

# ---------------------------------------------------------------------------
step 5 "The same three questions — now with a partition"
say ""
say "Same instrument as exp138, deliberately: if the questions changed, a"
say "different answer would not mean anything."
say ""
if yi26_state=$(yi26 state 2>/dev/null); [ "$yi26_state" = running ]; then
    run_cmd yi26 log --seconds 8
    say ""
    say "In ${DIM}get_partition_table_info(PT_INFO)${RESET}, word[1]'s low byte is the"
    say "partition count: ${BOLD}0${RESET} on a stock board, ${BOLD}1${RESET} now. And ${DIM}get_b_partition(0)${RESET}"
    say "is still negative — one partition has no B side. That negative is the"
    say "control for the experiment after this, which gives partition 0 a B."
else
    say "Board state: ${BOLD}${yi26_state:-absent}${RESET}. If it went dark, the image was not"
    say "linked at 0x10000000. BOOTSEL press, then: ${DIM}yi26 nuke && yi26 pflash ../exp138-what-the-rom-already-knows/target/exp138.uf2${RESET}"
fi
