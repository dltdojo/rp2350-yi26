#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp145 quick check — non-interactive verdict.
#
# The static half needs no board: the firmware has to keep three sectors of
# filesystem and no disk, refuse to write the half it is running from, and use
# flash offsets rather than XIP addresses. The board half, if a board is running
# exp145 from an A/B pair, confirms it is serving the volume and knows which
# half a drop belongs in. It does **not** drop a file — that writes flash, and
# run.sh is where that belongs.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1
presence_check

USB_IFACE="cdc+msc"
USB_CARRIES="log+scsi"
USB_HOST="cdc_acm+usb-storage"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp145-a-drive-of-our-own

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
    pass "the image is linked at 0x10000000 — an ordinary partition image"
else
    fail "the image is linked at 0x10000000" "a moved image is the exp139 dark-board bug"
fi

# The volume is three sectors of filesystem, not a disk. If a full-size RAM disk
# creeps back in, this experiment has become exp124 with extra steps.
if grep -q 'fat12::METADATA_BYTES' src/main.rs && ! grep -qE 'DISK_BYTES|\[u8; *DISK' src/main.rs; then
    pass "the volume is served from three sectors of filesystem, with no disk behind it"
else
    fail "the volume stores only its filesystem" "a full-size RAM disk is back in src/main.rs"
fi

# The three checks that stand between this and a bricked half.
if grep -q 'route.target_location == route.running_location' src/main.rs; then
    pass "refuses to install into the half it is running from"
else
    fail "refuses to install into the running half" "the guard is gone from install()"
fi
if grep -q 'span > slot_bytes' src/main.rs; then
    pass "refuses an image larger than the target slot"
else
    fail "refuses an oversized image" "the guard is gone from install()"
fi
if grep -q 'FAMILY_RP2350_ARM_S' src/main.rs && grep -q 'UF2_MAGIC_END' src/main.rs; then
    pass "takes only UF2 blocks with all three magic words and this chip's family"
else
    fail "checks the UF2 magic and family" "a sector that merely looks like a block would be taken"
fi

# embassy-rp's flash driver takes offsets from the start of flash. Passing an
# XIP address writes 0x10000000 bytes into the wrong place — a whole-chip miss.
if grep -q 'let offset = first \* SECTOR_BYTES' src/main.rs; then
    pass "flash is addressed by offset, not by XIP address"
else
    fail "flash is addressed by offset" "blocking_erase/blocking_write take flash offsets"
fi

# Completion comes from the file format, not from the transport.
if grep -q 'num_blocks' src/main.rs && grep -q 'taken >= self.expect' src/main.rs; then
    pass "knows the file is complete from UF2's own blockNo/numBlocks"
else
    fail "knows when the file is complete" "nothing on the wire says a file was closed — exp137"
fi

reboot_watcher_check

if (cd ../../crates/fat12 && cargo test --quiet) > /dev/null 2>&1; then
    pass "fat12 tests pass (including: metadata-only matches a full format's first three sectors)"
else
    fail "fat12 tests pass" "cd crates/fat12 && cargo test"
fi
if (cd ../../tools/partimg && cargo test --quiet) > /dev/null 2>&1; then
    pass "partimg tests pass (A/B: table at sector 0, A at 1, B at 17)"
else
    fail "partimg tests pass" "cd tools/partimg && cargo test"
fi

sleep 5
if ! exp_running 145; then
    echo "SKIP  board is not running exp145 (or its serial did not enumerate just now)"
    echo "      — flash it with ./run.sh, or re-run this check; not an error"
    exit "$FAILED"
fi
pass "board is running exp145"

# ---------------------------------------------------------------------------
# The board half.

if lsblk -no LABEL 2>/dev/null | grep -q 'DROP-A-UF2'; then
    pass "the host sees the volume this firmware serves (DROP-A-UF2)"
else
    fail "the host sees the volume" "no DROP-A-UF2 in lsblk — is the MSC interface up?"
fi

OUT="$(yi26 log --seconds 12 2>/dev/null || true)"

if ! echo "$OUT" | grep -q 'partition'; then
    echo "SKIP  no partition line in the log — replug or ./run.sh"
    exit "$FAILED"
fi

RUNNING="$(echo "$OUT" | grep -m1 -oE 'partition [0-9-]+,' | grep -oE '[0-9-]+')"
if [[ -n "$RUNNING" && "$RUNNING" != "-1" ]]; then
    pass "running from partition $RUNNING of an A/B pair"
else
    fail "running from a partition" "pick_ab_parition returned $RUNNING — is there a table?"
fi

if echo "$OUT" | grep -qE 'drop -> sectors [0-9]+\.\.[0-9]+'; then
    where="$(echo "$OUT" | grep -m1 -oE 'drop -> sectors [0-9]+\.\.[0-9]+')"
    pass "knows where a drop belongs: $where"
else
    fail "knows where a drop belongs" "get_uf2_target_partition named no target"
fi

echo "NOTE  this check does not drop a file. run.sh does, twice, and the board"
echo "      alternates halves on its own: v2.0 in partition 1, then v3.0 in 0,"
echo "      then v4.0 back in 1 — each one written by the firmware it replaced."

exit "$FAILED"
