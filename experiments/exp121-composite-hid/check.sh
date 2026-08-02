#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp121 quick check — non-interactive verdict.
# Builds both orderings, and if the board is running this experiment, checks
# that the host agrees it is a keyboard and that pressing a key reaches the
# kernel's input layer.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp121-composite-hid
UF2=target/exp121-composite-hid.uf2

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

# Both orderings must compile. The one nobody builds is the one that quietly
# stops working, and this pair is the experiment's second half.
if cargo build --release --quiet --features hid-first 2>/dev/null; then
    pass "the hid-first ordering compiles"
else
    fail "the hid-first ordering compiles" "cargo build --release --features hid-first"
fi

if cargo build --release --quiet 2>/dev/null && [[ -f "$ELF" ]]; then
    pass "the default ordering compiles ($(stat -c%s "$ELF") byte ELF)"
else
    fail "the default ordering compiles" "run: cargo build --release"
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

if ! exp_running 121; then
    echo "SKIP  board is not running exp121 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board is running exp121"

# ---------------------------------------------------------------------------
# The board half. Everything here asks the *host* what it thinks, because a
# firmware's opinion of its own descriptors is not evidence that they are
# valid.

# Three interfaces, in two functions. A descriptor mistake usually shows up as
# a board that does not enumerate at all, so getting this far is most of it.
IFACES="$(lsusb -v -d 1209:0001 2>/dev/null | grep -c 'bInterfaceNumber')"
[[ "$IFACES" == "3" ]] \
    && pass "the host sees three interfaces" \
    || fail "the host sees three interfaces" "saw $IFACES"

lsusb -v -d 1209:0001 2>/dev/null | grep -q 'bInterfaceClass *3 Human Interface Device' \
    && pass "one of them is a HID interface" \
    || fail "one of them is a HID interface" "no HID interface in the descriptors"

lsusb -v -d 1209:0001 2>/dev/null | grep -q 'bInterfaceProtocol *1 Keyboard' \
    && pass "declared as a boot-protocol keyboard" \
    || fail "declared as a boot-protocol keyboard" "the boot protocol claim is missing"

# The host's own opinion, and the one that matters: it bound a driver and made
# an input device. Nothing the firmware says can fake this.
KBD="$(ls /dev/input/by-id/*exp121*event-kbd 2>/dev/null | head -1)"
if [[ -n "$KBD" ]]; then
    pass "the host bound a keyboard driver ($(basename "$KBD"))"
else
    fail "the host bound a keyboard driver" "no *exp121*event-kbd under /dev/input/by-id"
fi

# And the keypress itself, read from the kernel's input layer rather than from
# a desktop's idea of what Scroll Lock means. GNOME does nothing with it, so
# `xset q` never changes — which would look exactly like the key never
# arriving.
if [[ -n "$KBD" && -r "$KBD" ]]; then
    EVENTS="$(mktemp)"
    trap 'rm -f "$EVENTS"' EXIT
    ( timeout 6 cat "$KBD" > "$EVENTS" 2>/dev/null ) &
    READER=$!
    sleep 1
    yi26 send k --seconds 2 > /dev/null 2>&1
    wait "$READER" 2>/dev/null
    if [[ -s "$EVENTS" ]]; then
        pass "pressing k reached the kernel's input layer ($(stat -c%s "$EVENTS") bytes of events)"
    else
        fail "pressing k reached the kernel's input layer" "no input events while the firmware said it pressed"
    fi
else
    echo "SKIP  cannot read the input event device — add yourself to the 'input' group to check the keypress"
fi

# The way back, tested last because it is the one that matters if anything
# above ever starts failing.
if yi26 bootsel > /dev/null 2>&1 && in_bootsel; then
    pass "still reboots itself with three interfaces declared"
    yi26 flash "$UF2" > /dev/null 2>&1 \
        && pass "and comes back" \
        || fail "and comes back" "the board is in BOOTSEL — run: yi26 flash $UF2"
else
    fail "still reboots itself with three interfaces declared" "the 1200-baud touch did not land"
fi

exit "$FAILED"
