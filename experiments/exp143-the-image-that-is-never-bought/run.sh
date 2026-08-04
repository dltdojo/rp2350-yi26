#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp143 interactive walkthrough — an image that boots, runs, and is taken back
# unless it says it wants to stay.
#
# Two arms, same binary. Slot B is marked try-before-you-buy in its own
# IMAGE_DEF; in the first arm it never calls `explicit_buy` and the ROM hands
# the board back to slot A, over and over. In the second it buys itself, and
# from then on it is simply the firmware.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
EXP="$(pwd)"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp143-the-image-that-is-never-bought

build_image() { # slot major tbyb buy out.uf2
    EXP143_SLOT="$1" EXP143_MAJOR="$2" EXP143_MINOR=0 EXP143_TBYB="$3" EXP143_BUY="$4" \
        cargo build --release --quiet
    elf2flash convert -b rp2350 "$ELF" "$5" > /dev/null 2>&1
}
assemble_ab() { # a.uf2 b.uf2 out.uf2
    ( cd ../../tools/partimg && cargo run --quiet -- ab "$EXP/$1" "$EXP/$2" "$EXP/$3" )
}
slot_now() { yi26 port --json 2>/dev/null | sed -n 's/.*"product":"\([^"]*\)".*/\1/p'; }

# Print which image is enumerated, once a second, for as long as asked. This is
# the instrument for this experiment: a trial image is on the bus for about
# sixteen seconds, and the port is where that shows without needing the log.
watch_slots() { # seconds
    local start now last="" p
    start="$(date +%s)"
    while (( $(date +%s) - start < $1 )); do
        p="$(slot_now)"; [[ -z "$p" ]] && p="(gone)"
        if [[ "$p" != "$last" ]]; then
            now=$(( $(date +%s) - start ))
            printf "    %+4ds  %s\n" "$now" "$p"
            last="$p"
        fi
        sleep 0.4
    done
}

echo "${BOLD}exp143 — the image that is never bought${RESET}"
say ""
say "exp142 let the ROM choose between two images by version. This one adds the"
say "part that makes an update survivable: an image can be ${BOLD}provisional${RESET}, and the"
say "ROM takes the board back unless the image asks to stay."

# ---------------------------------------------------------------------------
step 1 "What try-before-you-buy actually is"
say ""
say "One bit — ${DIM}IMAGE_TYPE_TBYB${RESET}, 0x8000 — in image B's own IMAGE_DEF. It makes"
say "three things true at once:"
say ""
say "  · a plain reset ${BOLD}will not${RESET} boot that image, however high its version"
say "  · the only way in is ${DIM}reboot(FLASH_UPDATE, update_base)${RESET} — a flash update boot"
say "  · once in, a clock is running, and the image is taken back when it runs out"
say ""
say "The image stops being provisional by calling ${DIM}explicit_buy${RESET}, which rewrites"
say "that bit out of the flash sector the image is running from. Not calling it"
say "is the whole rollback: nothing has to fail, and nothing has to be detected."

# ---------------------------------------------------------------------------
step 2 "Build A (v1.0, permanent) and B (v2.0, provisional, never buys)"
say ""
say "One source, two builds. B is the higher version ${BOLD}and${RESET} the one marked TBYB."
run_cmd bash -c "cd '$EXP' && EXP143_SLOT=A EXP143_MAJOR=1 EXP143_MINOR=0 cargo build --release --quiet && elf2flash convert -b rp2350 '$ELF' target/imageA.uf2 >/dev/null 2>&1 && echo 'built A v1.0, permanent'"
run_cmd bash -c "cd '$EXP' && EXP143_SLOT=B EXP143_MAJOR=2 EXP143_MINOR=0 EXP143_TBYB=1 EXP143_BUY=0 cargo build --release --quiet && elf2flash convert -b rp2350 '$ELF' target/imageB-nobuy.uf2 >/dev/null 2>&1 && echo 'built B v2.0, provisional, never buys'"
assemble_ab target/imageA.uf2 target/imageB-nobuy.uf2 target/exp143-nobuy.uf2

# ---------------------------------------------------------------------------
step 3 "Flash it — and watch which slot the ROM starts"
say ""
say "B is v2.0 against A's v1.0. exp142 says the higher version wins. Watch it"
say "lose, because an unbought provisional image is not a current image."
confirm "Flash the A/B image?" || { say ""; say "Nothing was flashed."; exit 0; }
run_cmd yi26 bootsel
run_cmd yi26 pflash target/exp143-nobuy.uf2
sleep 4
say ""
say "  running now: ${BOLD}$(slot_now)${RESET}"

# ---------------------------------------------------------------------------
step 4 "The trial, and the taking back"
say ""
say "Slot A hands the board to B on purpose, fifteen seconds in — that is what a"
say "field update does after it has written the new image. B comes up, says it"
say "will not buy, and the ROM's clock takes the board back to A. Then A tries"
say "again, and it happens again: an image that is never bought is never kept."
say ""
watch_slots 75
say ""
say "The board is cycling. Slot A is up for about fifteen seconds at a time,"
say "which is the window ${DIM}yi26 bootsel${RESET} needs — or send it anything"
say "(${DIM}yi26 send hold${RESET}) while A is up and it will stop trying."

# ---------------------------------------------------------------------------
step 5 "The same image, buying itself"
say ""
say "Nothing changes but ${DIM}EXP143_BUY${RESET}: the same B, which now calls ${DIM}explicit_buy${RESET}"
say "six seconds into its trial. Watch the TBYB bit leave the flash."
confirm "Rebuild B as the one that buys, and reflash?" || { say ""; say "Left cycling."; exit 0; }
build_image B 2 1 1 target/imageB-buy.uf2
say "  built B v2.0, provisional, buys"
assemble_ab target/imageA.uf2 target/imageB-buy.uf2 target/exp143-buy.uf2
say ""
say "Catching slot A's window to reflash:"
for _ in $(seq 1 100); do [[ "$(slot_now)" == "exp143 slot A" ]] && break; sleep 0.4; done
run_cmd yi26 bootsel
run_cmd yi26 pflash target/exp143-buy.uf2
say ""
say "A boots, hands over, B buys itself, and then resets itself once to prove"
say "the buy stuck — a plain reset now boots the slot that was provisional."
watch_slots 60
say ""
say "  running now: ${BOLD}$(slot_now)${RESET}"
say ""
say "Read the log for the two lines that matter:"
run_cmd yi26 log --seconds 8
say ""
say "That is the whole experiment. The rollback was not built out of a broken"
say "image, a checksum, or a bootloader of ours: it is what happens by default"
say "when nobody says ${BOLD}keep this${RESET}."
