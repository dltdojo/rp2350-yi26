#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp143 quick check — non-interactive verdict.
#
# The static half needs no board: the TBYB bit has to actually be in the built
# IMAGE_DEF (and absent from the permanent build), the buy has to be a real ROM
# call with the 4 KiB scratch buffer §5.5.12.3 requires, and the A/B assembly is
# exp142's, unchanged. The board half, if a board is running exp143, reads what
# the ROM did — a trial with a clock, or an image that was bought.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
EXP="$(pwd)"

source ../lib.sh
require_supported_platform

PRESENCE=1
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp143-the-image-that-is-never-bought

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

# The permanent build: no flags, slot A, v1.0.
if cargo build --release --quiet 2>/dev/null && [[ -f "$ELF" ]]; then
    pass "compiles ($(stat -c%s "$ELF") byte ELF)"
else
    fail "compiles" "cargo build --release"
fi

# exp139's lesson, inherited: a partition image is linked at the XIP base and
# placed by partimg, never moved by the linker.
if readelf -S "$ELF" 2>/dev/null | grep -qE '\.vector_table +PROGBITS +10000000'; then
    pass "the image is linked at 0x10000000 — the ROM remaps the booted partition there"
else
    fail "the image is linked at 0x10000000" "a moved image is the exp139 dark-board bug"
fi

if grep -q 'imagedef-none' Cargo.toml && grep -q 'ITEM_1BS_VERSION' src/main.rs; then
    pass "supplies its own IMAGE_DEF with a VERSION item (imagedef-none)"
else
    fail "supplies its own versioned IMAGE_DEF" "needs the imagedef-none feature and a VERSION item"
fi

# The bit the whole experiment is about, checked in the bytes rather than in the
# source. IMAGE_TYPE for a Secure Arm RP2350 executable is 0x1021, so the item
# word is 0x10210142 — and 0x90210142 with TBYB (0x8000) set. Little-endian in
# the dump: `42012110` and `42012190`.
image_type_word() { objdump -s -j .start_block "$ELF" 2>/dev/null | grep -oE '42012[0-9a-f]{3}' | head -1; }

if [[ "$(image_type_word)" == "42012110" ]]; then
    pass "the permanent build is not marked provisional (IMAGE_TYPE 0x10210142)"
else
    fail "the permanent build is not marked provisional" "IMAGE_TYPE item is $(image_type_word), expected 42012110"
fi

if EXP143_SLOT=B EXP143_MAJOR=2 EXP143_TBYB=1 cargo build --release --quiet 2>/dev/null \
   && [[ "$(image_type_word)" == "42012190" ]]; then
    pass "EXP143_TBYB=1 sets the TBYB bit in the built IMAGE_DEF (0x90210142)"
else
    fail "EXP143_TBYB=1 sets the TBYB bit" "IMAGE_TYPE item is $(image_type_word), expected 42012190"
fi

# The buy is the ROM's, not ours, and it needs somewhere to put a flash sector.
if grep -q 'rom_data::explicit_buy' src/main.rs; then
    pass "the buy is the ROM's own explicit_buy (§5.5.12.3)"
else
    fail "the buy is the ROM's own explicit_buy" "the call is gone from src/main.rs"
fi
if grep -q 'align(4096)' src/main.rs && grep -q '4096' src/main.rs; then
    pass "explicit_buy is given a 4 KiB, 4 KiB-aligned scratch buffer"
else
    fail "explicit_buy has its scratch buffer" "the ROM needs 4 KiB aligned to 4 KiB"
fi

# The trial is entered by a flash update boot and by nothing else. 0x4 is
# REBOOT2_FLAG_REBOOT_TYPE_FLASH_UPDATE; a normal boot will not run an unbought
# provisional image at all.
if grep -q 'REBOOT_FLASH_UPDATE: u32 = 0x4' src/main.rs; then
    pass "the trial is started by reboot(FLASH_UPDATE), the only path in"
else
    fail "the trial is started by reboot(FLASH_UPDATE)" "the reboot type is gone from src/main.rs"
fi

reboot_watcher_check

# Unchanged from exp142, and load-bearing here: a wrong word in the table, or a
# misplaced image, and there is no B side to try.
if (cd ../../crates/partition-table && cargo test --quiet) > /dev/null 2>&1; then
    pass "partition-table tests pass (the A/B table's words, no board)"
else
    fail "partition-table tests pass" "cd crates/partition-table && cargo test"
fi
if (cd ../../tools/partimg && cargo test --quiet) > /dev/null 2>&1; then
    pass "partimg tests pass (A/B: table at sector 0, A at 1, B at 17)"
else
    fail "partimg tests pass" "cd tools/partimg && cargo test"
fi
if elf2flash convert -b rp2350 "$ELF" target/image.uf2 >/dev/null 2>&1 \
   && (cd ../../tools/partimg && cargo run --quiet -- ab "$EXP/target/image.uf2" "$EXP/target/image.uf2" "$EXP/target/exp143-ab.uf2") >/dev/null 2>&1 \
   && [[ -f target/exp143-ab.uf2 ]]; then
    pass "assembled an A/B image ($(stat -c%s target/exp143-ab.uf2) bytes: table at sector 0, A at 1, B at 17)"
else
    fail "assembled an A/B image" "elf2flash convert, then partimg ab"
fi

# Let the USB stack settle: the builds above leave nusb enumeration briefly
# unable to see the board on this host.
sleep 5
if ! exp_running 143; then
    echo "SKIP  board is not running exp143 (or its serial did not enumerate just now)"
    echo "      — flash it with ./run.sh, or re-run this check; not an error"
    exit "$FAILED"
fi
pass "board is running exp143"

# ---------------------------------------------------------------------------
# The board half. Which arm is on the board is visible in the product string,
# because that string is built from the TBYB bit in flash, not from a build flag.

PRODUCT="$(yi26 port --json 2>/dev/null | sed -n 's/.*"product":"\([^"]*\)".*/\1/p')"
echo "NOTE  enumerated as: $PRODUCT"

# A trial image is on the bus for about sixteen seconds and then the port goes
# away under the reader — a broken pipe here is the rollback happening, not a
# failure, so the log is read with the error tolerated.
OUT="$(yi26 log --seconds 14 2>/dev/null || true)"

case "$PRODUCT" in
    *"slot A"*)
        if echo "$OUT" | grep -q 'trying the other slot in'; then
            pass "slot A is up and will hand the board to the provisional image"
        else
            echo "SKIP  slot A's lines have aged out — replug or ./run.sh"
            exit "$FAILED"
        fi
        ;;
    *provisional*)
        # A trial image is never more than seventeen seconds old, so its boot
        # lines are always still in the log.
        if echo "$OUT" | grep -qE 'watchdog as the ROM left it: enable=true, time=1[0-9]{7} us'; then
            wd="$(echo "$OUT" | grep -m1 -oE 'time=[0-9]+ us' | head -1)"
            pass "a trial clock is running: the ROM armed the watchdog (${wd})"
        else
            fail "a trial clock is running" "no watchdog time near the 16.7 s maximum in the log"
        fi
        if echo "$OUT" | grep -q 'TBYB set'; then
            pass "the running image reads its own TBYB bit as set, from flash"
        else
            fail "the running image is provisional" "no 'TBYB set' line"
        fi
        ;;
    *bought*)
        # A bought image runs forever, so its boot lines are long gone. The
        # repeating idle line carries the same reading, taken from flash.
        if ! echo "$OUT" | grep -q 'IMAGE_TYPE'; then
            echo "SKIP  no IMAGE_TYPE line in the log — replug or ./run.sh"
            exit "$FAILED"
        fi
        if echo "$OUT" | grep -q 'TBYB clear'; then
            pass "the bought image reads its own TBYB bit as cleared, from flash"
        else
            fail "the bought image reads TBYB as cleared" "the log still says TBYB set"
        fi
        if echo "$OUT" | grep -q 'slot B'; then
            pass "slot B is what a plain reset boots now — the buy stuck"
        else
            fail "slot B survived" "the log does not say slot B"
        fi
        ;;
    *)
        echo "SKIP  unrecognised product string; not an error"
        exit "$FAILED"
        ;;
esac

echo "NOTE  the two arms are the same binary: EXP143_BUY decides whether the"
echo "      image calls explicit_buy. Nothing is broken in the arm that rolls"
echo "      back — it simply never asks to stay."

exit "$FAILED"
