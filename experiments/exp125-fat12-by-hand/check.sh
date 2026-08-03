#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp125 quick check — non-interactive verdict.
# Runs the layout crate's own tests, then if the board is running this
# experiment, mounts the volume it offers and reads the file back.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # the volume mounts, and the layout crate runs under cargo test
presence_check

USB_IFACE="cdc+msc"
USB_CARRIES="log+files"
USB_HOST="cdc_acm+usb-storage"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp125-fat12-by-hand
UF2=target/exp125-fat12-by-hand.uf2

MODEL="exp125 fat12"
LABEL="YI26 EXP125"
FILE="README.TXT"

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

# The layout arithmetic is checked on this machine before any of it reaches a
# board. Two 12-bit entries share three bytes, and getting that wrong makes a
# volume that mounts and is wrong — which is worse than one that fails.
#
# `cd`, not `--manifest-path`. That flag chooses which crate is built; it does
# not choose which configuration applies. Cargo finds `.cargo/config.toml` by
# walking up from the *current directory*, and this directory's copy pins
# `target = thumbv8m.main-none-eabihf` — so from here the host tests get
# cross-compiled for the board and fail on a missing panic handler. Which is
# exactly what this check reported, against a crate whose tests were fine.
if (cd ../../crates/fat12 && cargo test --quiet) > /dev/null 2>&1; then
    pass "the fat12 crate's own tests pass (packing, layout, cluster count)"
else
    fail "the fat12 crate's own tests pass" "cargo test --manifest-path crates/fat12/Cargo.toml"
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

if ! exp_running 125; then
    echo "SKIP  board is not running exp125 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board is running exp125"

# ---------------------------------------------------------------------------
# The board half. Everything below is the host's reading of bytes this
# firmware wrote, which is the only thing that settles whether the layout is
# right.

# By model, not by name: `sda` is whatever the kernel had spare. The trailing
# space matters — SCSI strings are padded, not terminated.
DEV=""
for d in /sys/block/*/; do
    [[ -r "$d/device/model" ]] || continue
    M="$(cat "$d/device/model" 2>/dev/null)"
    [[ "${M%"${M##*[![:space:]]}"}" == "$MODEL" ]] && DEV="$(basename "$d")"
done

if [[ -n "$DEV" ]]; then
    pass "the host created a block device (/dev/$DEV)"
else
    fail "the host created a block device" "no /sys/block entry with model '$MODEL'"
    exit "$FAILED"
fi

# The whole experiment in one field. exp124's was empty.
FSTYPE="$(lsblk -no FSTYPE "/dev/$DEV" 2>/dev/null | head -1)"
[[ "$FSTYPE" == "vfat" ]] \
    && pass "the kernel recognises a FAT filesystem on it (FSTYPE=vfat)" \
    || fail "the kernel recognises a FAT filesystem" "FSTYPE is '${FSTYPE:-empty}'"

# Read out of the volume label *directory entry*, not the boot sector copy —
# which is why the layout writes both and only one of them is believed.
FOUND_LABEL="$(lsblk -no LABEL "/dev/$DEV" 2>/dev/null | head -1)"
[[ "$FOUND_LABEL" == "$LABEL" ]] \
    && pass "and reads the volume label from the root directory ($FOUND_LABEL)" \
    || fail "and reads the volume label" "got '${FOUND_LABEL:-none}', expected '$LABEL'"

# Mount it if the desktop has not already, and put it back the way it was.
MOUNTED_BY_US=0
MP="$(lsblk -no MOUNTPOINT "/dev/$DEV" 2>/dev/null | head -1)"
if [[ -z "$MP" ]]; then
    MP="$(udisksctl mount -b "/dev/$DEV" 2>/dev/null | sed -n 's/.* at \(.*\)\.$/\1/p')"
    [[ -n "$MP" ]] && MOUNTED_BY_US=1
fi

if [[ -n "$MP" && -d "$MP" ]]; then
    pass "the volume mounts at $MP"
    if [[ -f "$MP/$FILE" ]] && grep -q "written by hand" "$MP/$FILE"; then
        pass "and $FILE reads back with the bytes the firmware laid down ($(stat -c%s "$MP/$FILE") bytes)"
    else
        fail "and $FILE reads back correctly" "the file is missing or its contents are wrong"
    fi
else
    fail "the volume mounts" "udisksctl could not mount /dev/$DEV"
fi

# Unmounted before anything reboots the board. Pulling a mounted filesystem
# out from under a host is how you get errors that have nothing to do with the
# experiment.
if [[ "$MOUNTED_BY_US" == "1" ]]; then
    udisksctl unmount -b "/dev/$DEV" > /dev/null 2>&1 \
        && pass "and unmounts cleanly" \
        || fail "and unmounts cleanly" "something still has it open"
else
    udisksctl unmount -b "/dev/$DEV" > /dev/null 2>&1
    echo "NOTE  the volume was already mounted when this started; it has been unmounted"
fi

[[ -e /dev/ttyACM0 ]] \
    && pass "the CDC port survived being a filesystem as well" \
    || fail "the CDC port survived" "the host may be resetting the device"

if yi26 bootsel > /dev/null 2>&1 && in_bootsel; then
    pass "still reboots itself while offering a mountable volume"
    yi26 flash "$UF2" > /dev/null 2>&1 \
        && pass "and comes back" \
        || fail "and comes back" "the board is in BOOTSEL — run: yi26 flash $UF2"
else
    fail "still reboots itself while offering a mountable volume" "the 1200-baud touch did not land"
fi

exit "$FAILED"
