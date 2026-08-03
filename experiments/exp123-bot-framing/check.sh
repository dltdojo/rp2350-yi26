#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp123 quick check — non-interactive verdict.
# Builds, then if the board is running this experiment, confirms that the host
# bound its storage driver, asked, was refused, and gave up without producing
# a disk or disturbing anything else.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # the evidence is in sysfs and the log
presence_check

USB_IFACE="cdc+msc"
USB_CARRIES="log+scsi"
USB_HOST="cdc_acm+usb-storage"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp123-bot-framing
UF2=target/exp123-bot-framing.uf2

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

if ! exp_running 123; then
    echo "SKIP  board is not running exp123 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board is running exp123"

# ---------------------------------------------------------------------------
# The board half. Every claim here is about what the operating system did,
# because a firmware saying "I declared a disk" is not evidence that anything
# believed it.

lsusb -v -d 1209:0001 2>/dev/null | grep -q 'bInterfaceClass *8 Mass Storage' \
    && pass "the descriptors declare a mass-storage interface" \
    || fail "the descriptors declare a mass-storage interface" "no class 0x08 interface"

# The kernel bound its storage driver. Contrast exp122, where the vendor
# interface is deliberately left with no driver at all: declaring a *class* is
# what invites one in.
MSC_DRIVER=""
for i in /sys/bus/usb/devices/*:1.*/; do
    [[ -e "$i/../idVendor" ]] || continue
    [[ "$(cat "$i/../idVendor" 2>/dev/null)" == "1209" ]] || continue
    [[ "$(cat "$i/bInterfaceClass" 2>/dev/null)" == "08" ]] || continue
    [[ -L "$i/driver" ]] && MSC_DRIVER="$(basename "$(readlink "$i/driver")")"
    MSC_PATH="$i"
done

[[ "$MSC_DRIVER" == "usb-storage" ]] \
    && pass "the kernel bound usb-storage to it" \
    || fail "the kernel bound usb-storage to it" "driver is '${MSC_DRIVER:-none}'"

# A SCSI host with nothing under it. This is the whole result in one number:
# the kernel believed the declaration enough to build a host, asked, and found
# nothing it could use.
TARGETS=-1
for h in ${MSC_PATH:-/nonexistent}host*; do
    [[ -e "$h" ]] || continue
    TARGETS="$(ls -d "$h"/target* 2>/dev/null | wc -l)"
done
if [[ "$TARGETS" == "0" ]]; then
    pass "a SCSI host exists with zero targets — asked, refused, no disk"
elif [[ "$TARGETS" == "-1" ]]; then
    fail "a SCSI host exists with zero targets" "no SCSI host was created at all"
else
    fail "a SCSI host exists with zero targets" "found $TARGETS — something answered, which is exp124's job"
fi

# And the firmware saw the interrogation. The count survives since boot, so
# this does not need the host to be asked again.
OUT="$(yi26 log --seconds 6 2>/dev/null)"
if echo "$OUT" | grep -qE 'idle: [1-9][0-9]* commands received, all refused'; then
    pass "the firmware logged and refused every command it received"
else
    fail "the firmware logged and refused every command" "$(echo "$OUT" | grep -o 'idle:.*' | tail -1)"
fi

# The serial port is not collateral damage. A host stuck retrying a broken
# disk resets the whole device, which takes CDC with it — the reason this
# firmware refuses in a well-formed way rather than staying silent.
[[ -e /dev/ttyACM0 ]] \
    && pass "the CDC port survived the interrogation" \
    || fail "the CDC port survived the interrogation" "the host may be resetting the device"

if yi26 bootsel > /dev/null 2>&1 && in_bootsel; then
    pass "still reboots itself with a storage interface declared"
    yi26 flash "$UF2" > /dev/null 2>&1 \
        && pass "and comes back" \
        || fail "and comes back" "the board is in BOOTSEL — run: yi26 flash $UF2"
else
    fail "still reboots itself with a storage interface declared" "the 1200-baud touch did not land"
fi

exit "$FAILED"
