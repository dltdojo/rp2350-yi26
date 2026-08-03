#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp104 quick check — non-interactive verdict.
# Builds the firmware and, if a board is already running it, confirms the
# serial port is there. Flashing needs the BOOTSEL button, so that is run.sh.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # yi26 log reads the whole result
presence_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp104-usb-serial
UF2=target/exp104-usb-serial.uf2

# 1. Toolchain (exp102's job)
if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

# 2. Builds
if cargo build --release --quiet 2>/dev/null && [[ -f "$ELF" ]]; then
    pass "firmware compiles ($(stat -c%s "$ELF") byte ELF)"
else
    fail "firmware compiles" "run: cargo build --release"
    exit 1
fi

# 3. Converts to a valid RP2350 Arm UF2
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

# 4. If the board is already running this firmware, it should be on USB with
#    a serial port. Not a failure when it isn't — you may not have flashed yet.
if [[ "$(yi26 state)" == "running" ]]; then
    pass "board enumerated as 1209:0001 (exp104 USB serial)"
    PORT="$(exp_serial_port)"
    [[ -n "$PORT" ]] \
        && pass "serial port present: $PORT" \
        || fail "serial port present" "device is on USB but no /dev/ttyACM* — check dmesg"
else
    echo "SKIP  board running exp104 — flash it with ./run.sh (not an error)"
fi

exit "$FAILED"
