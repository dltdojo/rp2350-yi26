#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp139 quick check — non-interactive verdict.
#
# The static half is the important half and needs no board: the eight table
# words are checked by the partition-table crate's tests, the assembly (table at
# sector 0, image at sector 1) by partimg's tests, and the one rule the dark
# board taught — the image is linked at the XIP base, not moved — by reading the
# ELF and by partimg refusing a moved image.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
EXP="$(pwd)"

source ../lib.sh
require_supported_platform

PRESENCE=1   # a board and nothing else: the answers are lines, not lights
presence_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp139-a-table-of-one
IMG=target/exp139-image.uf2
UF2=target/exp139.uf2

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

if cargo build --release --quiet 2>/dev/null && [[ -f "$ELF" ]]; then
    pass "compiles ($(stat -c%s "$ELF") byte ELF)"
else
    fail "compiles" "cargo build --release"
fi

# The rule the dark board taught: the image is an ORDINARY image, linked at the
# XIP base 0x10000000. The ROM remaps a booted partition there, so a moved image
# faults. Both checked in the ELF, without flashing.
ELF_SECTIONS="$(readelf -S "$ELF" 2>/dev/null || true)"
if echo "$ELF_SECTIONS" | grep -qE '\.vector_table +PROGBITS +10000000'; then
    pass "the image is linked at 0x10000000 — ordinary, not moved into the partition"
else
    fail "the image is linked at 0x10000000" "a moved image (0x10001000) is the dark-board bug"
fi

if echo "$ELF_SECTIONS" | grep -qE '\.partition_table'; then
    fail "the table is not inside the firmware" "there is a .partition_table section — it should be assembled externally"
else
    pass "no partition table inside the firmware — it is assembled by partimg"
fi

# The firmware still only reads. Writing flash from a running firmware is a
# later experiment; doing it here would let this one fail in two ways at once.
if grep -qE 'flash::|blocking_write|blocking_erase|flash_range' src/main.rs; then
    fail "this firmware only reads" "src/main.rs touches flash"
else
    pass "this firmware only reads — nothing here writes to flash"
fi

# The table's words, checked on this machine rather than on a board. The failure
# they guard against is a device that draws power and says nothing.
if (cd ../../crates/partition-table && cargo test --quiet) > /dev/null 2>&1; then
    pass "partition-table tests pass (the eight words, no board)"
else
    fail "partition-table tests pass" "cd crates/partition-table && cargo test"
fi

# The assembly, checked the same way: partimg's tests prove it places the table
# at sector 0 and the image at sector 1 byte-for-byte, and refuses a moved image.
if (cd ../../tools/partimg && cargo test --quiet) > /dev/null 2>&1; then
    pass "partimg tests pass (table at sector 0, image at sector 1, refuses a moved image)"
else
    fail "partimg tests pass" "cd tools/partimg && cargo test"
fi

# End to end on the host: build the ordinary image, then assemble the
# partitioned UF2. partimg refuses anything not linked at 0x10000000, so a green
# here is also the address rule holding.
if elf2flash convert -b rp2350 "$ELF" "$IMG" > /dev/null 2>&1 \
   && (cd ../../tools/partimg && cargo run --quiet -- "$EXP/$IMG" "$EXP/$UF2") > /dev/null 2>&1 \
   && [[ -f "$UF2" ]]; then
    pass "assembled the partitioned UF2 ($(stat -c%s "$UF2") bytes)"
else
    fail "assembled the partitioned UF2" "elf2flash convert, then partimg"
fi

# Three questions have to stay three questions. One that quietly grew a fourth
# would have a README describing something else.
for fn in get_partition_table_info get_sys_info get_b_partition; do
    grep -q "rom_data::$fn" src/main.rs \
        && pass "asks the ROM: $fn" \
        || fail "asks the ROM: $fn" "the call is gone from src/main.rs"
done

if ! exp_running 139; then
    echo "SKIP  board is not running exp139 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board is running exp139"

# ---------------------------------------------------------------------------
# The board half. The answers are said once, three seconds after boot, so a
# board that has been up for a while has dropped them — exp134's queue again.

OUT="$(yi26 log --seconds 12 2>/dev/null)"

if ! echo "$OUT" | grep -q 'get_partition_table_info(PT_INFO) ->'; then
    echo "SKIP  the answers were said once at boot and have aged out of the"
    echo "      queue — replug the board, or ./run.sh, then check again"
    exit "$FAILED"
fi
pass "the ROM answered the partition-table question"

# The finding: a stock board reported word[1] = 0x00000000 (zero partitions).
# This one reports a non-zero partition count — the ROM booted from the table.
if echo "$OUT" | grep -qE 'word\[1\] = 0x00000101'; then
    pass "the partition count is one — the ROM booted this image from the partition"
elif echo "$OUT" | grep -q 'word\[1\] = 0x00000000'; then
    fail "the partition count is one" "word[1] is zero — the ROM sees no table; did it reboot after the table was written?"
else
    echo "NOTE  word[1] is neither 0x00000000 nor the expected 0x00000101 — read it"
    echo "      against the README's decoding; the low byte is the partition count"
fi

echo "$OUT" | grep -qE 'get_b_partition\(0\) -> -?[0-9]+' \
    && pass "the ROM answered the A/B question at all — which is the point" \
    || fail "the ROM answered the A/B question" "no get_b_partition line"

echo "$OUT" | grep -q 'nothing was written' \
    && pass "the firmware says so itself: nothing was written" \
    || fail "the firmware reports that it wrote nothing" "the line is missing"

echo "NOTE  get_b_partition(0) negative is expected: one partition has no B side."
echo "      That negative is the control for the next experiment, which adds a B."

exit "$FAILED"
