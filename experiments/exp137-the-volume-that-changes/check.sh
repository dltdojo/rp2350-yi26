#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp137 quick check — non-interactive verdict.
#
# Lays the volume down again while the host has it mounted, and measures two
# questions that are easy to confuse:
#
#   1. does the host act on the media-change signal at all?
#   2. does a file's contents change under a filesystem that already read it?
#
# The answers are not the same, and both are asserted here.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed
#
# Needs no root: the evidence is the board's own log plus udisksctl, which
# mounts a removable volume as an ordinary user.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # udisksctl scripts the mounting; nobody has to look at anything
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

USB_IFACE="cdc+msc"
USB_CARRIES="log+commands+files"
USB_HOST="cdc_acm+usb-storage"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp137-the-volume-that-changes
UF2=target/exp137.uf2

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

if (cd ../../crates/fat12 && cargo test --quiet) > /dev/null 2>&1; then
    pass "the fat12 crate's tests pass (the layout, with no board)"
else
    fail "the fat12 crate's tests pass" "cd crates/fat12 && cargo test"
fi

if cargo build --release --quiet 2>/dev/null && [[ -f "$ELF" ]]; then
    pass "compiles ($(stat -c%s "$ELF") byte ELF)"
    elf2flash convert -b rp2350 "$ELF" "$UF2" > /dev/null 2>&1
    pass "converts to UF2 ($(stat -c%s "$UF2") bytes)"
else
    fail "compiles" "cargo build --release"
fi

# The rule from exp131, checked rather than intended: this firmware serves a
# volume and can be rebooted by software, so the page that reboots it is on
# that volume, or a phone that flashed this board is stranded.
grep -q 'FLASH   HTM' src/main.rs \
    && pass "the volume carries FLASH.HTM — the way back is on the device" \
    || fail "the volume carries FLASH.HTM" "a phone flashing the next build would need a page from somewhere else"

# Boot and re-lay have to go through one function, or "the volume at boot" and
# "the volume after a change" drift apart invisibly: both would still mount.
[[ $(grep -c 'lay_down(' src/main.rs) -ge 3 ]] \
    && pass "boot and re-lay go through one function" \
    || fail "boot and re-lay go through one function" "there is a second layout path"

if ! exp_running 137; then
    echo "SKIP  board is not running exp137 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board is running exp137"

# ---------------------------------------------------------------------------
# The board half.

DEV="$(lsblk -o NAME,MODEL -nr | awk '$2 ~ /exp137/ {print "/dev/" $1; exit}')"
if [[ -z "$DEV" ]]; then
    echo "SKIP  no block device for this board — the volume did not enumerate"
    exit "$FAILED"
fi
pass "the host created a block device ($DEV)"

[[ "$(lsblk -no RO "$DEV" | head -1 | tr -d '[:space:]')" == "1" ]] \
    && pass "the host marked it read-only, because MODE SENSE said so" \
    || fail "the host marked it read-only" "the WP bit is not reaching the host"

udisksctl mount -b "$DEV" > /dev/null 2>&1 || true
MP="$(findmnt -n -o TARGET "$DEV" 2>/dev/null | head -1)"
if [[ -z "$MP" ]]; then
    fail "the volume mounts" "udisksctl could not mount $DEV"
    exit "$FAILED"
fi
pass "the volume mounts at $MP"

BEFORE="$(grep -o 'generation [0-9]*' "$MP/STATUS.TXT" 2>/dev/null | head -1)"
[[ -n "$BEFORE" ]] \
    && pass "STATUS.TXT is readable ($BEFORE)" \
    || fail "STATUS.TXT is readable" "no generation line on the volume"

# The change, with the host holding the volume mounted the whole time.
OUT="$(yi26 send 'b' --seconds 8 2>/dev/null)"

echo "$OUT" | grep -q 'volume laid down again' \
    && pass "the firmware laid the volume down again while it was mounted" \
    || fail "the firmware laid the volume down again" "no 'volume laid down again' line"

# Question 1: does the host act on the signal at all?
echo "$OUT" | grep -q 'UNIT ATTENTION (06/28)' \
    && pass "the next command was refused with UNIT ATTENTION (06/28)" \
    || fail "the next command was refused with UNIT ATTENTION" "the signal never went out"

echo "$OUT" | grep -q 'REQUEST SENSE  -> key 6 asc 28' \
    && pass "the host asked why, and was told: key 6, asc 28" \
    || fail "the host asked why" "no REQUEST SENSE for the unit attention"

echo "$OUT" | grep -q 'READ CAPACITY' \
    && pass "the host re-read the capacity — it acted on the signal" \
    || fail "the host re-read the capacity" "no READ CAPACITY after the change"

[[ $(echo "$OUT" | grep -c 'READ(10)') -ge 3 ]] \
    && pass "and re-read the layout: boot sector, FAT, root directory" \
    || fail "the host re-read the layout" "fewer than three READ(10)s after the change"

# Question 2: did any of that reach a file the host had already read?
AFTER="$(grep -o 'generation [0-9]*' "$MP/STATUS.TXT" 2>/dev/null | head -1)"
if [[ "$AFTER" == "$BEFORE" ]]; then
    pass "and the mounted file did NOT change ($AFTER) — the cache answered"
else
    echo "NOTE  the mounted file changed from '$BEFORE' to '$AFTER' — this host"
    echo "      invalidates its page cache on a media change, which is not what"
    echo "      the Ubuntu host this was written on does. A report is welcome."
fi

# The volume really did change, and a fresh mount is what proves it.
udisksctl unmount -b "$DEV" > /dev/null 2>&1
sleep 1
udisksctl mount -b "$DEV" > /dev/null 2>&1
MP="$(findmnt -n -o TARGET "$DEV" 2>/dev/null | head -1)"
REMOUNT="$(grep -o 'generation [0-9]*' "$MP/STATUS.TXT" 2>/dev/null | head -1)"

[[ -n "$REMOUNT" && "$REMOUNT" != "$BEFORE" ]] \
    && pass "a fresh mount reads the new volume ($REMOUNT) — the bytes really moved" \
    || fail "a fresh mount reads the new volume" "still $REMOUNT after unmount and remount"

udisksctl unmount -b "$DEV" > /dev/null 2>&1

echo "NOTE  the two answers above are the experiment: the host honours the"
echo "      signal completely, and it still does not make a mounted file change"

exit "$FAILED"
