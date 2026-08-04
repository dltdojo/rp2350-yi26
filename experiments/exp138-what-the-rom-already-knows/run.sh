#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp138 interactive walkthrough — ask the ROM what it already knows about
# A/B firmware slots, before building anything that assumes it does not.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp138-what-the-rom-already-knows
UF2=target/exp138.uf2

echo "${BOLD}exp138 — what the ROM already knows${RESET}"
say ""
say "Every guide to dual-firmware updates on a microcontroller opens the same"
say "way: the boot ROM is fixed silicon, it cannot know which slot you want,"
say "so you must hand-roll a bootloader that decides."
say ""
say "On most parts that is exactly right. This experiment asks whether it is"
say "right ${BOLD}here${RESET}, before an arc of experiments gets built on the assumption."

# ---------------------------------------------------------------------------
step 1 "Build and flash — and note what this one cannot do"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
say ""
say "This firmware ${BOLD}only reads${RESET}. ${DIM}check.sh${RESET} fails if a flash write ever"
say "appears in its source, because the point of starting here is that nothing"
say "on this road can brick a board yet."
say ""
run_cmd yi26 flash "$UF2"

# ---------------------------------------------------------------------------
step 2 "The three questions"
say ""
say "  ${BOLD}1.${RESET} Is there a partition table?      ${DIM}get_partition_table_info(PT_INFO)${RESET}"
say "  ${BOLD}2.${RESET} What chip is this?               ${DIM}get_sys_info(CHIP_INFO)${RESET}"
say "  ${BOLD}3.${RESET} Does partition 0 have a B side?  ${DIM}get_b_partition(0)${RESET}"
say ""
say "The third one is the experiment. A chip whose ROM cannot answer ${DIM}which"
say "partition is the other half of this pair${RESET} is a chip where A/B has to"
say "be built by hand."
say ""
run_cmd yi26 log --seconds 8

# ---------------------------------------------------------------------------
step 3 "Reading the words"
say ""
say "Raw before interpreted, on purpose: a decoded field that is wrong reads"
say "like a fact, and the word it came from reads like what it is."
say ""
say "  ${DIM}word[1] = 0x00000000${RESET}      the partition count. ${BOLD}Zero.${RESET}"
say "  ${DIM}word[2] = 0xffffe000${RESET}      sectors 0 to 8191 — all of it unpartitioned"
say "  ${DIM}get_b_partition(0) -> -17${RESET} no table to answer from"
say ""
say "So: nothing is divided, nothing is paired, and the ROM answered every"
say "question anyway. ${BOLD}The machinery is in the chip, and it is empty.${RESET}"

# ---------------------------------------------------------------------------
step 4 "What that changes"
say ""
say "The functions this board just answered from are the ones a hand-rolled"
say "bootloader exists to provide:"
say ""
say "  ${DIM}pick_ab_parition${RESET}   the ROM's own A/B chooser"
say "  ${DIM}explicit_buy${RESET}       confirm a provisional image, or it rolls back"
say "  ${DIM}ITEM_1BS_VERSION${RESET}   the version the ROM compares when it picks"
say "  ${DIM}IMAGE_TYPE_TBYB${RESET}    the flag that makes an image provisional"
say ""
say "None of that makes a custom bootloader pointless — it is the measurement"
say "that makes the comparison honest. What comes next writes a partition"
say "table and finds out what the ROM does with one."
say ""
say "${DIM}./check.sh${RESET} asserts the answers above, and that this firmware never"
say "wrote anything."
