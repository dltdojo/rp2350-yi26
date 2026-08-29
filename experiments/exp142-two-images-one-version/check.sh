#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp142 quick check — non-interactive verdict.
#
# The static half needs no board: each image is an ordinary 0x10000000-linked
# firmware that supplies its own IMAGE_DEF with a VERSION item, the A/B table's
# words are checked by the partition-table crate, and the two-image assembly by
# partimg. The board half, if a board is running exp142, confirms the ROM sees
# the A/B pair.
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
ELF=target/$TARGET/release/exp142-two-images-one-version

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

# Build the default image (slot A, v1.0) for the static checks.
if cargo build --release --quiet 2>/dev/null && [[ -f "$ELF" ]]; then
    pass "compiles ($(stat -c%s "$ELF") byte ELF)"
else
    fail "compiles" "cargo build --release"
fi

# Ordinary image, linked at the XIP base — the ROM remaps whichever partition it
# boots there, so both A and B are built exactly the same way (exp139's lesson).
ELF_SECTIONS="$(readelf -S "$ELF" 2>/dev/null || true)"
if echo "$ELF_SECTIONS" | grep -qE '\.vector_table +PROGBITS +10000000'; then
    pass "the image is linked at 0x10000000 — the ROM remaps the booted partition there"
else
    fail "the image is linked at 0x10000000" "a moved image is the exp139 dark-board bug"
fi

# This firmware supplies its OWN IMAGE_DEF with a VERSION item — that is the word
# the ROM compares for A/B. Check the source says so and the version item made it
# into the binary (its 2-byte-size header for item id 0x48 is 0x00000248).
if grep -q 'imagedef-none' Cargo.toml && grep -q 'ITEM_1BS_VERSION' src/main.rs; then
    pass "supplies its own IMAGE_DEF with a VERSION item (imagedef-none)"
else
    fail "supplies its own versioned IMAGE_DEF" "needs the imagedef-none feature and a VERSION item"
fi
if objdump -s -j .start_block "$ELF" 2>/dev/null | grep -q '48020000'; then
    pass "the VERSION item is in the built IMAGE_DEF"
else
    fail "the VERSION item is in the built IMAGE_DEF" "objdump .start_block has no 0x00000248 header"
fi

# This firmware only reads. Writing flash is a later experiment.
if grep -qE 'flash::|blocking_write|blocking_erase|flash_range' src/main.rs; then
    fail "this firmware only reads" "src/main.rs touches flash"
else
    pass "this firmware only reads — nothing here writes to flash"
fi

reboot_watcher_check

# The A/B table's ten words, and partimg's two-image assembly, both on the
# machine — a wrong word here boots the wrong slot, or nothing.
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

# The A/B assembly, on the host. The already-built image stands in for both
# slots — the placement (table at sector 0, A at 1, B at 17) is what is under
# test, not the versions, and partimg's own tests cover the version-carrying
# bytes. Reusing the one build keeps this check from rebuilding the firmware
# twice, which is heavy and needlessly churns the board's USB.
if elf2flash convert -b rp2350 "$ELF" target/image.uf2 >/dev/null 2>&1 \
   && (cd ../../tools/partimg && cargo run --quiet -- ab "$EXP/target/image.uf2" "$EXP/target/image.uf2" "$EXP/target/exp142-ab.uf2") >/dev/null 2>&1 \
   && [[ -f target/exp142-ab.uf2 ]]; then
    pass "assembled an A/B image ($(stat -c%s target/exp142-ab.uf2) bytes: table at sector 0, A at 1, B at 17)"
else
    fail "assembled an A/B image" "elf2flash convert, then partimg ab"
fi

for fn in get_partition_table_info get_b_partition; do
    grep -q "rom_data::$fn" src/main.rs \
        && pass "asks the ROM: $fn" \
        || fail "asks the ROM: $fn" "the call is gone from src/main.rs"
done

# Let the USB stack settle after the builds above, before reading the board's
# serial to confirm the right firmware.
#
# This comment used to say that the SKIP below was nusb enumeration going
# briefly empty under load. That was wrong, and exp143 found the real cause: the
# `yi26` wrapper in lib.sh rebuilds the host tool when it is stale, and it used
# to do that from whatever directory the caller stood in — here, an experiment
# directory whose `.cargo/config.toml` pins `target = thumbv8m.main-none-eabihf`.
# The host tool was compiled for a Cortex-M33, the build failed, `yi26` returned
# nothing, and the board half reported "board is not running exp142" against a
# board that was running it perfectly. Fixed in lib.sh; kept written down here
# because a wrong cause in a comment is worse than no comment.
sleep 2
if ! exp_running 142; then
    echo "SKIP  board is not running exp142 (or its serial did not enumerate just now)"
    echo "      — flash it with ./run.sh, or re-run this check; not an error"
    exit "$FAILED"
fi
pass "board is running exp142"

# ---------------------------------------------------------------------------
# The board half. Whichever slot booted, the ROM must report the A/B pair.

OUT="$(yi26 log --seconds 12 2>/dev/null)"

if ! echo "$OUT" | grep -q 'get_b_partition(0) ->'; then
    echo "SKIP  the answers were said once at boot and have aged out — replug or ./run.sh"
    exit "$FAILED"
fi

if echo "$OUT" | grep -q 'get_b_partition(0) -> 1'; then
    pass "the ROM reports partition 1 is the B side of 0 — the A/B pair is seen"
else
    fail "the ROM sees the A/B pair" "get_b_partition(0) is not 1 — is the B link in the table?"
fi

if echo "$OUT" | grep -qE 'I am slot [AB], version'; then
    slot_line="$(echo "$OUT" | grep -m1 -E 'I am slot [AB], version')"
    pass "a slot booted and named itself: ${slot_line#*] }"
else
    fail "a slot named itself" "no 'I am slot X' line"
fi

echo "NOTE  which slot booted is the one with the higher version. Swap the"
echo "      versions (run.sh does this) and the other slot boots — the ROM"
echo "      choosing, live."

exit "$FAILED"
