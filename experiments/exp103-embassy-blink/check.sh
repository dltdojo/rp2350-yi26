#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp103 quick check — non-interactive verdict, no prompts, no board needed.
# Answers one question: does this firmware build into a valid RP2350 UF2?
# (Flashing needs the BOOTSEL button — a human job — so that lives in run.sh.)
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=3   # an eye on the LED — this firmware has no USB, so nothing else can see it
presence_check

USB_IFACE="none"
USB_CARRIES="none"
USB_HOST="none"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp103-embassy-blink
UF2=target/exp103-embassy-blink.uf2

# 1. Toolchain in place (exp102's job)
if command -v elf2flash > /dev/null && command -v cargo > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

# 2. The firmware compiles
if cargo build --release --quiet 2>/dev/null && [[ -f "$ELF" ]]; then
    pass "firmware compiles ($(stat -c%s "$ELF") byte ELF)"
else
    fail "firmware compiles" "run: cargo build --release"
    exit 1
fi

# 3. It converts to UF2
if elf2flash convert -b rp2350 "$ELF" "$UF2" > /dev/null 2>&1 && [[ -f "$UF2" ]]; then
    pass "converts to UF2 ($(stat -c%s "$UF2") bytes)"
else
    fail "converts to UF2" "run: elf2flash convert -b rp2350 $ELF $UF2"
    exit 1
fi

# 4. The UF2 really is an RP2350 Arm image: every UF2 block carries a family
#    ID at byte offset 28; the RP2350 Arm (secure) family is 0xE48BFF59.
FAMILY="$(od -An -tx4 -j28 -N4 "$UF2" | tr -d ' ')"
if [[ "$FAMILY" == "e48bff59" ]]; then
    pass "UF2 family ID is e48bff59 (rp2350-arm-s)"
else
    fail "UF2 family ID is e48bff59 (rp2350-arm-s)" "got: $FAMILY"
fi

exit "$FAILED"
