#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp142 interactive walkthrough — two firmwares in two partitions with
# different versions, and the ROM booting the higher one. Then swap the
# versions and watch the other one boot: the ROM choosing, live.
#
# Built on exp139's lesson: each image is linked at 0x10000000 like any
# ordinary firmware, and tools/partimg places the table and both images. The
# only difference between the A image and the B image is a slot letter and a
# version, set here as build inputs.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
EXP="$(pwd)"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp142-two-images-one-version

# Build one image with a given slot and version, and convert it to a UF2.
build_image() { # slot major minor out.uf2
    EXP142_SLOT="$1" EXP142_MAJOR="$2" EXP142_MINOR="$3" cargo build --release --quiet
    elf2flash convert -b rp2350 "$ELF" "$4" > /dev/null
}
assemble_ab() { # a.uf2 b.uf2 out.uf2
    ( cd ../../tools/partimg && cargo run --quiet -- ab "$EXP/$1" "$EXP/$2" "$EXP/$3" )
}
which_slot() { yi26 log --seconds 8 2>/dev/null | grep -m1 -E 'I am slot [AB], version' || true; }

echo "${BOLD}exp142 — two images, one version number${RESET}"
say ""
say "exp139 booted one image from one partition. This puts two, with different"
say "versions, and lets the ROM pick — the A/B machinery exp138 found empty."

# ---------------------------------------------------------------------------
step 1 "How the ROM chooses"
say ""
say "Two partitions form an A/B pair: the B partition's table entry ${BOLD}links${RESET} to"
say "A. Each image carries a ${BOLD}VERSION${RESET} in its own IMAGE_DEF, and the ROM boots"
say "the partition whose image has the higher version. Same binary either slot,"
say "because the ROM remaps whichever partition it picks to 0x10000000."

# ---------------------------------------------------------------------------
step 2 "Build image A (v1.0) and image B (v2.0)"
say ""
say "One source, two builds — only EXP142_SLOT and the version differ."
run_cmd bash -c "cd '$EXP' && EXP142_SLOT=A EXP142_MAJOR=1 EXP142_MINOR=0 cargo build --release --quiet && elf2flash convert -b rp2350 '$ELF' target/imageA.uf2 && echo 'built A v1.0'"
run_cmd bash -c "cd '$EXP' && EXP142_SLOT=B EXP142_MAJOR=2 EXP142_MINOR=0 cargo build --release --quiet && elf2flash convert -b rp2350 '$ELF' target/imageB.uf2 && echo 'built B v2.0'"

# ---------------------------------------------------------------------------
step 3 "Assemble the A/B image"
say ""
say "partimg puts the A/B table at flash offset 0, image A at sector 1, image B"
say "at sector 17 — both unchanged, both linked at 0x10000000."
run_cmd bash -c "cd ../../tools/partimg && cargo run --quiet -- ab '$EXP/target/imageA.uf2' '$EXP/target/imageB.uf2' '$EXP/target/exp142-ab.uf2'"

# ---------------------------------------------------------------------------
step 4 "Flash it — B should win (v2.0 > v1.0)"
say ""
confirm "Flash the A/B image?" || { say ""; say "Nothing was flashed."; exit 0; }
run_cmd yi26 bootsel
run_cmd yi26 pflash target/exp142-ab.uf2
sleep 3
say ""
say "Which slot booted:"
say "  ${BOLD}$(which_slot | sed 's/.*] //')${RESET}"
say ""
say "${DIM}get_b_partition(0)${RESET} now returns 1, not exp139's -17: the ROM sees the"
say "A/B link. And the slot that is running is the one with the higher version."

# ---------------------------------------------------------------------------
step 5 "The flip — make A newer, and watch A win"
say ""
say "Nothing changes but A's version: v1.0 becomes ${BOLD}v3.0${RESET}, above B's v2.0."
confirm "Rebuild A as v3.0 and reflash?" || { say ""; say "Left as is — B is booted."; exit 0; }
build_image A 3 0 target/imageA.uf2
say "  built A v3.0"
assemble_ab target/imageA.uf2 target/imageB.uf2 target/exp142-flip.uf2
run_cmd yi26 bootsel
run_cmd yi26 pflash target/exp142-flip.uf2
sleep 3
say ""
say "Which slot booted now:"
say "  ${BOLD}$(which_slot | sed 's/.*] //')${RESET}"
say ""
say "Same two partitions, same link, same binaries — only the version numbers"
say "moved, and the ROM booted the other slot. That is the whole experiment:"
say "the choice the standard advice says you must hand-roll is in the ROM."
