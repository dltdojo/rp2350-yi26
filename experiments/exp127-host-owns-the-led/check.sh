#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp127 quick check — non-interactive verdict.
# Builds, then if the board is running this experiment, sends the two commands
# and confirms the firmware reports the pad following them.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=3   # an eye on the LED — check.sh gets the pad, not the light
presence_check

USB_IFACE="cdc"
USB_CARRIES="log+commands"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp127-host-owns-the-led
UF2=target/exp127-host-owns-the-led.uf2

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
    fail "auto-reboot is compiled in" "built with --no-default-features? this board will need BOOTSEL by hand"
fi

# ---------------------------------------------------------------------------
# The source guard this experiment needs, and the reason it needs one.
#
# The whole evidential claim here rests on reading SIO GPIO_IN — the pad —
# rather than SIO GPIO_OUT, which only hands back the value just written.
# `Output` exposes the second and not the first, so swapping `Flex` back to
# `Output` and `is_high()` back to `is_set_high()` would leave every log line
# looking identical, every check below passing, and the experiment proving
# nothing at all. A silent downgrade that all the tests survive is exactly the
# failure exp112 is about, so it gets caught here rather than trusted.
if grep -q 'Flex::new(p\.PIN_25)' src/main.rs; then
    pass "the LED is a Flex, so the pad can be read back"
else
    fail "the LED is a Flex" "Output cannot read GPIO_IN — the readback would be an echo"
fi

if grep -q 'led\.is_high()' src/main.rs; then
    pass "the readback reads GPIO_IN (led.is_high), not just GPIO_OUT"
else
    fail "the readback reads GPIO_IN" "is_set_high() alone proves only that a store happened"
fi

# Same citation guard exp118 added, for the same reason. This README claims the
# byte travels on `endpoint 0x01 OUT bulk 64 bytes`, and cites exp115's capture
# for it. exp118 shipped that sentence with the wrong address, and nothing
# noticed because prose is not checked. It is checked here.
TREE=../exp115-webusb-enumerate/README.md
if [[ -f "$TREE" ]]; then
    BAD=""
    while IFS= read -r addr; do
        [[ -z "$addr" ]] && continue
        grep -qF "$addr" "$TREE" || BAD="$BAD [$addr]"
    done < <(grep -rhoE 'endpoint 0x[0-9a-f]{2}' README.md src/main.rs run.sh | sort -u)
    if [[ -z "$BAD" ]]; then
        pass "every endpoint address cited here appears in exp115's captured tree"
    else
        fail "every endpoint address cited here appears in exp115's captured tree" "not in it:$BAD"
    fi
else
    echo "SKIP  exp115's README is missing, so citations cannot be checked against it"
fi

if ! exp_running 127; then
    echo "SKIP  board is not running exp127 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board is running exp127"

# ---------------------------------------------------------------------------
# The board half.
#
# Same drain as exp118, for the same reason: crates/usb-log holds sixteen
# lines and writes none of them until the host asserts DTR, so a board nobody
# has listened to has a queue of stale idle lines waiting to be flushed.
yi26 log --seconds 2 > /dev/null 2>&1

ON="$(yi26 send '\x01' --seconds 3 2>/dev/null)"
echo "$ON" | grep -q 'cmd #[0-9]*: 0x01 led on' \
    && pass "0x01 was accepted as a command" \
    || fail "0x01 was accepted as a command" "no 'cmd #N: 0x01 led on' line"

# The point of the whole experiment: not that the firmware said "on", but that
# the pin reads back at the level it was asked for.
echo "$ON" | grep -q 'led on (OUT high, pad high)' \
    && pass "the pad reads high after 0x01" \
    || fail "the pad reads high after 0x01" "$(echo "$ON" | grep -o '(OUT .*)' | tail -1)"

OFF="$(yi26 send '\x00' --seconds 3 2>/dev/null)"
echo "$OFF" | grep -q 'cmd #[0-9]*: 0x00 led off' \
    && pass "0x00 was accepted as a command" \
    || fail "0x00 was accepted as a command" "no 'cmd #N: 0x00 led off' line"

echo "$OFF" | grep -q 'led off (OUT low, pad low)' \
    && pass "the pad reads low after 0x00" \
    || fail "the pad reads low after 0x00" "$(echo "$OFF" | grep -o '(OUT .*)' | tail -1)"

# A disagreement between the two registers would be real news, and it must
# never be reported as a pass by a grep that only looked for the happy case.
if echo "$ON$OFF" | grep -qE 'OUT high, pad low|OUT low, pad high'; then
    fail "OUT and the pad agree" "the pin did not follow the write — see the log"
else
    pass "OUT and the pad agree on every command"
fi

# Anything that is not one of the two commands is refused by name, not
# silently ignored. 0x41 is 'A'.
BAD="$(yi26 send 'A' --seconds 3 2>/dev/null)"
echo "$BAD" | grep -q '0x41 is not a command' \
    && pass "an unknown byte is refused and named" \
    || fail "an unknown byte is refused and named" "no '0x41 is not a command' line"

# Six bytes in one packet. This firmware has no way to delimit messages, so it
# says so rather than acting on the first byte — which would make `led on`
# mean 0x6c and turn a typo into a state change.
MULTI="$(yi26 send 'led on' --seconds 3 2>/dev/null)"
echo "$MULTI" | grep -q '6 bytes in one packet' \
    && pass "a multi-byte packet is refused, not partly obeyed" \
    || fail "a multi-byte packet is refused" "no '6 bytes in one packet' line"

# The idle line has to keep coming, because after the first command it is the
# only evidence the firmware is running. IDLE_REPORT is 5s.
IDLE="$(yi26 log --seconds 7 2>/dev/null)"
echo "$IDLE" | grep -q 'idle: led .*host-owned' \
    && pass "the idle line reports host ownership and keeps repeating" \
    || fail "the idle line reports host ownership" "nothing matched 'idle: led ... host-owned' in 7s"

# Said out loud, every run. Everything above proves the pin moved; none of it
# proves the board emitted light, and no script in this repository can.
echo "NOTE  the pad is checked; whether the LED lit is a question for an eye"

exit "$FAILED"
