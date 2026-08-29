#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp144 quick check — non-interactive verdict.
#
# The static half needs no board. The board half, if a board is running exp144
# from an A/B pair, confirms the ROM's two answers: which half is running, and
# which half a dropped .uf2 would be routed into. It does **not** drop a file —
# that is destructive, needs the drive, and is what run.sh is for.
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
ELF=target/$TARGET/release/exp144-one-file-either-half

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

if readelf -S "$ELF" 2>/dev/null | grep -qE '\.vector_table +PROGBITS +10000000'; then
    pass "the image is linked at 0x10000000 — an ordinary image, placed by nobody"
else
    fail "the image is linked at 0x10000000" "a moved image is the exp139 dark-board bug"
fi

# No slot letter anywhere: the whole question is whether a file can be built
# without knowing which half it will end up in.
if grep -qE 'SLOT|slot_?[AB]|for_slot' src/main.rs build.rs; then
    fail "the firmware names no slot" "a slot letter has crept into the build"
else
    pass "the firmware names no slot — one file, either half"
fi

for fn in get_uf2_target_partition pick_ab_parition get_partition_table_info; do
    grep -q "rom_data::$fn" src/main.rs \
        && pass "asks the ROM: $fn" \
        || fail "asks the ROM: $fn" "the call is gone from src/main.rs"
done

# The out parameter of get_uf2_target_partition is a resident_partition_t —
# two words, location and flags. Reading it as one u32 was this experiment's
# first bug and produced a "partition number" of 4227989505.
if grep -q 'let mut target = \[0u32; 2\]' src/main.rs; then
    pass "get_uf2_target_partition is given two words, not one (resident_partition_t)"
else
    fail "get_uf2_target_partition gets two words" "a single u32 reads only the location"
fi

# Measured on hardware, not guessed from a header: 0x0010 is the flag that
# returns location/flags pairs, and 0x8000 asks about one partition.
if grep -q 'PT_LOCATION_AND_FLAGS: u32 = 0x0010' src/main.rs \
   && grep -q 'PT_SINGLE_PARTITION: u32 = 0x8000' src/main.rs; then
    pass "the partition-table info flags are the measured ones (0x0010, 0x8000)"
else
    fail "the partition-table info flags" "0x0002 is accepted and answers nothing — see the README"
fi

reboot_watcher_check

if (cd ../../tools/partimg && cargo test --quiet) > /dev/null 2>&1; then
    pass "partimg tests pass (A/B: table at sector 0, A at 1, B at 17)"
else
    fail "partimg tests pass" "cd tools/partimg && cargo test"
fi

sleep 5
if ! exp_running 144; then
    echo "SKIP  board is not running exp144 (or its serial did not enumerate just now)"
    echo "      — flash it with ./run.sh, or re-run this check; not an error"
    exit "$FAILED"
fi
pass "board is running exp144"

# ---------------------------------------------------------------------------
# The board half: the two answers, from the repeating idle line so a board that
# has been up for an hour still answers.

OUT="$(yi26 log --seconds 12 2>/dev/null || true)"

if ! echo "$OUT" | grep -q 'running partition'; then
    echo "SKIP  no 'running partition' line in the log — replug or ./run.sh"
    exit "$FAILED"
fi

RUNNING="$(echo "$OUT" | grep -m1 -oE 'running partition [0-9-]+' | grep -oE '[0-9-]+$')"
NEXT="$(echo "$OUT" | grep -m1 -oE 'next drop -> partition [0-9-]+' | grep -oE '[0-9-]+$')"

if [[ -n "$RUNNING" && "$RUNNING" != "-1" ]]; then
    pass "the ROM names the running half: partition $RUNNING (pick_ab_parition)"
else
    fail "the ROM names the running half" "pick_ab_parition returned $RUNNING"
fi

if [[ -n "$NEXT" && "$NEXT" != "-1" ]]; then
    pass "the ROM routes a dropped .uf2 to partition $NEXT (get_uf2_target_partition)"
else
    fail "the ROM routes a dropped .uf2" "get_uf2_target_partition returned $NEXT"
fi

if [[ -n "$RUNNING" && -n "$NEXT" && "$RUNNING" != "$NEXT" ]]; then
    pass "the routed half is not the running half — the answer an update wants"
else
    fail "the routed half is the running half" "a drop would land on the firmware that is running"
fi

echo "NOTE  this check does not drop a file. On this board, a UF2 written to the"
echo "      BOOTSEL drive is refused whenever a partition table is present — the"
echo "      measurement is in the README, and run.sh reproduces it with the"
echo "      no-table control that makes it a finding."

exit "$FAILED"
