#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp122 quick check — non-interactive verdict.
# Builds, then if the board is running this experiment, confirms that the
# kernel took the CDC pair and left the vendor interface alone, and that both
# can be used at the same time.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # yi26 echo claims the vendor interface directly
presence_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp122-vendor-bulk
UF2=target/exp122-vendor-bulk.uf2

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

if ! exp_running 122; then
    echo "SKIP  board is not running exp122 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board is running exp122"

# ---------------------------------------------------------------------------
# The board half. The claim under test is about what the *operating system*
# does, so the operating system is what gets asked.

lsusb -v -d 1209:0001 2>/dev/null | grep -q 'bInterfaceClass *255 Vendor Specific Class' \
    && pass "the descriptors declare a vendor-specific interface" \
    || fail "the descriptors declare a vendor-specific interface" "no class 0xFF interface"

# Which interfaces the kernel took, read from sysfs. This is the experiment:
# the CDC pair has a driver, the vendor interface does not, and neither fact is
# something the firmware can assert about itself.
CDC_BOUND=0 VENDOR_BOUND=0 VENDOR_SEEN=0
for i in /sys/bus/usb/devices/*:1.*/; do
    [[ -e "$i/../idVendor" ]] || continue
    [[ "$(cat "$i/../idVendor" 2>/dev/null)" == "1209" ]] || continue
    CLASS="$(cat "$i/bInterfaceClass" 2>/dev/null)"
    case "$CLASS" in
        02|0a) [[ -L "$i/driver" ]] && CDC_BOUND=$((CDC_BOUND + 1)) ;;
        ff)    VENDOR_SEEN=1; [[ -L "$i/driver" ]] && VENDOR_BOUND=1 ;;
    esac
done

(( CDC_BOUND == 2 )) \
    && pass "the kernel bound a driver to both CDC interfaces" \
    || fail "the kernel bound a driver to both CDC interfaces" "bound $CDC_BOUND of 2"

if (( VENDOR_SEEN == 1 )) && (( VENDOR_BOUND == 0 )); then
    pass "and left the vendor interface alone — nothing to detach"
elif (( VENDOR_SEEN == 0 )); then
    fail "and left the vendor interface alone" "no class 0xFF interface in sysfs"
else
    fail "and left the vendor interface alone" "something bound a driver to it: $(basename "$(readlink /sys/bus/usb/devices/*:1.*/driver 2>/dev/null | tail -1)")"
fi

# The serial port has to survive the whole exchange. exp116's route costs it
# for as long as a browser holds the interfaces; this one costs nothing, and
# that difference is the reason the experiment exists.
BEFORE="$(ls /dev/ttyACM* 2>/dev/null | head -1)"
OUT="$(yi26 echo 'hello vendor' --seconds 4 2>&1)"
AFTER="$(ls /dev/ttyACM* 2>/dev/null | head -1)"

echo "$OUT" | grep -q 'HELLO VENDOR' \
    && pass "the vendor interface echoed the bytes back, uppercased" \
    || fail "the vendor interface echoed the bytes back" "$(echo "$OUT" | tr '\n' ' ')"

if [[ -n "$BEFORE" && "$BEFORE" == "$AFTER" ]]; then
    pass "and $BEFORE was never taken away — two owners, at once"
else
    fail "and the serial port was never taken away" "before='$BEFORE' after='$AFTER'"
fi

# Non-printable bytes, because "it echoed" is a weaker claim than "it echoed
# these exact bytes" and uppercasing must not touch what is not a letter.
#
# `--json` rather than the plain output, and not for tidiness: the reply
# contains a NUL, and bash drops NUL bytes out of a command substitution with a
# warning. The JSON escapes control bytes to \u0000, so the shell never has to
# carry one — which is the same reason `yi26 log --json` exists.
BIN="$(yi26 echo 'a\x00\xffz' --json --seconds 4 2>&1)"
echo "$BIN" | grep -q '"received_bytes":4' \
    && pass "four raw bytes went out and four came back" \
    || fail "four raw bytes went out and four came back" "$(echo "$BIN" | tr '\n' ' ')"

# And uppercasing left the bytes that are not letters alone. 'a' became 'A',
# 'z' became 'Z', NUL and 0xff are untouched — which is what proves the
# firmware transformed the payload rather than something echoing it blindly.
echo "$BIN" | grep -q '"received":"A' \
    && pass "the letters were uppercased and the raw bytes were not" \
    || fail "the letters were uppercased and the raw bytes were not" "$(echo "$BIN" | tr '\n' ' ')"

if yi26 bootsel > /dev/null 2>&1 && in_bootsel; then
    pass "still reboots itself with a third interface declared"
    yi26 flash "$UF2" > /dev/null 2>&1 \
        && pass "and comes back" \
        || fail "and comes back" "the board is in BOOTSEL — run: yi26 flash $UF2"
else
    fail "still reboots itself with a third interface declared" "the 1200-baud touch did not land"
fi

exit "$FAILED"
