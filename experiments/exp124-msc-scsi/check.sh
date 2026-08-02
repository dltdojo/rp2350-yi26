#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp124 quick check — non-interactive verdict.
# Builds, then if the board is running this experiment, confirms the host
# accepted the disk: a block device of the right size, with no filesystem on
# it, and no errors anywhere.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp124-msc-scsi
UF2=target/exp124-msc-scsi.uf2

MODEL="exp124 ram disk"
EXPECT_SIZE=65536

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

if cargo build --release --quiet 2>/dev/null && [[ -f "$ELF" ]]; then
    pass "compiles ($(stat -c%s "$ELF") byte ELF)"
else
    fail "compiles" "run: cargo build --release"
    exit 1
fi

if elf2flash convert -b rp2350 "$ELF" "$UF2" > /dev/null 2>&1 && [[ -f "$UF2" ]]; then
    pass "converts to UF2 ($(stat -c%s "$UF2") bytes)"
else
    fail "converts to UF2" "run: elf2flash convert -b rp2350 $ELF $UF2"
    exit 1
fi
FAMILY="$(od -An -tx4 -j28 -N4 "$UF2" | tr -d ' ')"
[[ "$FAMILY" == "e48bff59" ]] \
    && pass "UF2 family ID is e48bff59 (rp2350-arm-s)" \
    || fail "UF2 family ID is e48bff59 (rp2350-arm-s)" "got: $FAMILY"

if yi26 markers "$UF2" | grep -q 'yi26-cfg:auto-reboot=on'; then
    pass "auto-reboot is compiled in (the board can still be reflashed)"
else
    fail "auto-reboot is compiled in" "a descriptor experiment without a way back needs a hand on BOOTSEL"
fi

if ! exp_running 124; then
    echo "SKIP  board is not running exp124 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board is running exp124"

# ---------------------------------------------------------------------------
# The board half. exp123 proved a host can be made to give up; this proves it
# can be convinced, and everything below is the host's own account.

# Find the block device by the INQUIRY strings the firmware sends. Not by
# name: sda is whatever the kernel had spare, and on a machine with disks it
# will not be sda at all.
# The trailing space is not a typo, and leaving it out is how this check
# failed the first time it was run. SCSI strings are fixed-width and
# space-padded rather than terminated — `inquiry()` writes 16 bytes of product
# id — and sysfs hands the padding back untouched: `[exp124 ram disk ]`.
DEV=""
for d in /sys/block/*/; do
    [[ -r "$d/device/model" ]] || continue
    M="$(cat "$d/device/model" 2>/dev/null)"
    [[ "${M%"${M##*[![:space:]]}"}" == "$MODEL" ]] && DEV="$(basename "$d")"
done

if [[ -n "$DEV" ]]; then
    pass "the host created a block device from the INQUIRY strings (/dev/$DEV)"
else
    fail "the host created a block device" "no /sys/block entry with model '$MODEL' — the host did not accept the disk"
    exit "$FAILED"
fi

# Size, in bytes, from the kernel rather than from the firmware. This is
# READ CAPACITY having been believed: 128 blocks of 512, minus the off-by-one
# that reporting the *last* LBA invites.
SIZE=$(( $(cat "/sys/block/$DEV/size") * 512 ))
[[ "$SIZE" == "$EXPECT_SIZE" ]] \
    && pass "and sized it at $((SIZE / 1024)) KiB, which is what READ CAPACITY claimed" \
    || fail "and sized it correctly" "kernel says $SIZE bytes, firmware claims $EXPECT_SIZE"

# Removable, from the one bit set in the INQUIRY response.
[[ "$(cat "/sys/block/$DEV/removable" 2>/dev/null)" == "1" ]] \
    && pass "and marked it removable, from bit 7 of the INQUIRY response" \
    || fail "and marked it removable" "the RMB bit did not survive"

# No filesystem and no partitions, which is this experiment's *goal* rather
# than a shortfall. An all-zero sector zero is not a partition table, the
# kernel finds nothing to report, and says nothing — the absence is the
# result. exp125 is what puts something there.
if lsblk -no FSTYPE "/dev/$DEV" 2>/dev/null | grep -q .; then
    fail "the volume is unformatted, as intended" "something has a filesystem on it: $(lsblk -no NAME,FSTYPE "/dev/$DEV" | tr '\n' ' ')"
else
    pass "the volume is unformatted — no filesystem, no partitions, no complaint"
fi

# The firmware's side: it served real blocks, not just descriptors. A device
# that answers READ CAPACITY and then cannot produce blocks is the failure
# this experiment was designed to avoid.
OUT="$(yi26 log --seconds 6 2>/dev/null)"
if echo "$OUT" | grep -qE 'idle: [0-9]+ commands, [1-9][0-9]* blocks read'; then
    pass "the firmware served real blocks: $(echo "$OUT" | grep -oE '[0-9]+ blocks read' | tail -1)"
else
    fail "the firmware served real blocks" "$(echo "$OUT" | grep -o 'idle:.*' | tail -1)"
fi

[[ -e /dev/ttyACM0 ]] \
    && pass "the CDC port survived being a disk as well" \
    || fail "the CDC port survived" "the host may be resetting the device"

if yi26 bootsel > /dev/null 2>&1 && in_bootsel; then
    pass "still reboots itself while pretending to be a disk"
    yi26 flash "$UF2" > /dev/null 2>&1 \
        && pass "and comes back" \
        || fail "and comes back" "the board is in BOOTSEL — run: yi26 flash $UF2"
else
    fail "still reboots itself while pretending to be a disk" "the 1200-baud touch did not land"
fi

exit "$FAILED"
