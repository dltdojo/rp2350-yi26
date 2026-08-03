#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp126 quick check — non-interactive verdict.
# Runs the layout crate's tests, then mounts the volume the board offers and
# checks that INDEX.HTM on it is byte-identical to exp116's page.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=2   # check.sh mounts and diffs unattended; the claim needs one browser tap
presence_check

USB_IFACE="cdc+msc"
USB_CARRIES="log+files"
USB_HOST="cdc_acm+usb-storage+webusb"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp126-self-hosted-viewer
UF2=target/exp126-self-hosted-viewer.uf2

MODEL="exp126 viewer"
LABEL="YI26 EXP126"
PAGE=../../tools/pages/log.html

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

# `cd`, not `--manifest-path`: that flag chooses the crate, not the
# configuration, and this directory's .cargo/config.toml cross-compiles.
if (cd ../../crates/fat12 && cargo test --quiet) > /dev/null 2>&1; then
    pass "the fat12 crate's tests pass, including multi-cluster chains"
else
    fail "the fat12 crate's tests pass" "cd crates/fat12 && cargo test"
fi

# The page is embedded from the repository's log tool, not copied. Two copies
# of a nineteen-kilobyte page would drift, and the one on the board is the copy
# nobody would think to check. exp116 built this page and still keeps its own
# frozen copy; the maintained one lives in tools/pages/ and is the one that
# ships, so a fix there reaches this board by rebuilding and nothing else.
grep -q 'include_bytes!("../../../tools/pages/log.html")' src/main.rs \
    && pass "the firmware embeds the log tool rather than a copy of it" \
    || fail "the firmware embeds the log tool" "src/main.rs should include_bytes! tools/pages/log.html"

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

if ! exp_running 126; then
    if [[ "$(yi26 state 2>/dev/null)" == "detached" ]]; then
        echo "SKIP  the interfaces are detached — run 'yi26 attach' to check the board half"
    else
        echo "SKIP  board is not running exp126 — flash it with ./run.sh (not an error)"
    fi
    exit "$FAILED"
fi
pass "board is running exp126"

# ---------------------------------------------------------------------------
# The board half.

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

FSTYPE="$(lsblk -no FSTYPE "/dev/$DEV" 2>/dev/null | head -1)"
[[ "$FSTYPE" == "vfat" ]] \
    && pass "with a FAT filesystem on it (FSTYPE=vfat)" \
    || fail "with a FAT filesystem on it" "FSTYPE is '${FSTYPE:-empty}'"

MOUNTED_BY_US=0
MP="$(lsblk -no MOUNTPOINT "/dev/$DEV" 2>/dev/null | head -1)"
if [[ -z "$MP" ]]; then
    MP="$(udisksctl mount -b "/dev/$DEV" 2>/dev/null | sed -n 's/.* at \(.*\)\.$/\1/p')"
    [[ -n "$MP" ]] && MOUNTED_BY_US=1
fi

if [[ -n "$MP" && -d "$MP" ]]; then
    pass "the volume mounts at $MP"

    # The claim this whole experiment rests on, and the only check that can
    # settle it: nineteen kilobytes across thirty-eight chained clusters, read
    # back through the host's own filesystem driver. A chain that is wrong in
    # one link still mounts, and still produces a file of the right length.
    if [[ -f "$MP/INDEX.HTM" ]] && cmp -s "$MP/INDEX.HTM" "$PAGE"; then
        pass "INDEX.HTM on the board is byte-identical to exp116's page ($(stat -c%s "$PAGE") bytes)"
    elif [[ -f "$MP/INDEX.HTM" ]]; then
        fail "INDEX.HTM is byte-identical to exp116's page" "same name, different bytes — check the cluster chain"
    else
        fail "INDEX.HTM is on the volume" "the root directory does not list it"
    fi

    [[ -f "$MP/README.TXT" ]] \
        && pass "and README.TXT is there beside it, on its own chain" \
        || fail "and README.TXT is there beside it" "the second file is missing"
else
    fail "the volume mounts" "udisksctl could not mount /dev/$DEV"
fi

if [[ "$MOUNTED_BY_US" == "1" ]]; then
    udisksctl unmount -b "/dev/$DEV" > /dev/null 2>&1 \
        && pass "and unmounts cleanly" \
        || fail "and unmounts cleanly" "something still has it open"
else
    udisksctl unmount -b "/dev/$DEV" > /dev/null 2>&1
    echo "NOTE  the volume was already mounted when this started; it has been unmounted"
fi

[[ -e /dev/ttyACM0 ]] \
    && pass "the CDC port is still there — the page has something to read" \
    || fail "the CDC port is still there" "without it the page has nothing to stream"

if yi26 bootsel > /dev/null 2>&1 && in_bootsel; then
    pass "still reboots itself while serving its own debug page"
    yi26 flash "$UF2" > /dev/null 2>&1 \
        && pass "and comes back" \
        || fail "and comes back" "the board is in BOOTSEL — run: yi26 flash $UF2"
else
    fail "still reboots itself while serving its own debug page" "the 1200-baud touch did not land"
fi

echo "NOTE  opening INDEX.HTM and pressing Connect is a human's job by design —"
echo "      the WebUSB picker is a native dialog behind a required user gesture."
echo "      The README's Expected output is a real capture, read from the page"
echo "      the board itself served."

exit "$FAILED"
