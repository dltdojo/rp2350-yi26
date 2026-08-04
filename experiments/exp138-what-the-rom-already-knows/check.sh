#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp138 quick check — non-interactive verdict.
#
# Flashes nothing, writes nothing, and asks the board what the ROM told it.
# Everything this experiment claims is in three log lines, so the check is
# mostly about whether those lines say what the README says they say.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

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
ELF=target/$TARGET/release/exp138-what-the-rom-already-knows
UF2=target/exp138.uf2

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

if cargo build --release --quiet 2>/dev/null && [[ -f "$ELF" ]]; then
    pass "compiles ($(stat -c%s "$ELF") byte ELF)"
    elf2flash convert -b rp2350 "$ELF" "$UF2" > /dev/null 2>&1
    pass "converts to UF2 ($(stat -c%s "$UF2") bytes)"
else
    fail "compiles" "cargo build --release"
fi

# The claim that makes this experiment safe to run on anybody's board, and the
# reason this road starts here rather than one experiment further on.
if grep -qE 'flash::|blocking_write|blocking_erase|flash_range' src/main.rs; then
    fail "this firmware only reads" "src/main.rs touches flash"
else
    pass "this firmware only reads — nothing here writes to flash"
fi

# Three questions have to stay three questions. One that quietly grew a fourth
# would have a README describing something else.
for fn in get_partition_table_info get_sys_info get_b_partition; do
    grep -q "rom_data::$fn" src/main.rs \
        && pass "asks the ROM: $fn" \
        || fail "asks the ROM: $fn" "the call is gone from src/main.rs"
done

if ! exp_running 138; then
    echo "SKIP  board is not running exp138 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board is running exp138"

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

# The finding, and the reason the rest of this road exists: the machinery is
# there and there is nothing in it yet.
if echo "$OUT" | grep -q 'word\[1\] = 0x00000000'; then
    pass "the partition count is zero — this board has no table"
else
    echo "NOTE  this board reports a non-zero partition count, which no board in"
    echo "      this repository had when exp138 was written. Read the words"
    echo "      against the README's decoding — you have a partitioned board."
fi

echo "$OUT" | grep -qE 'get_b_partition\(0\) -> -?[0-9]+' \
    && pass "the ROM answered the A/B question at all — which is the point" \
    || fail "the ROM answered the A/B question" "no get_b_partition line"

echo "$OUT" | grep -q 'nothing was written' \
    && pass "the firmware says so itself: nothing was written" \
    || fail "the firmware reports that it wrote nothing" "the line is missing"

echo "NOTE  a negative get_b_partition on a stock board is the expected answer:"
echo "      the ROM understands the question and has no table to answer from"

exit "$FAILED"
