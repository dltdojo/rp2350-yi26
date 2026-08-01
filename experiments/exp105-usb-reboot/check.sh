#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp105 quick check — non-interactive verdict.
# Builds the firmware (both with and without the auto-reboot feature) and, if
# a board is running it, confirms the serial port is there.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp105-usb-reboot
UF2=target/exp105-usb-reboot.uf2

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

if cargo build --release --quiet 2>/dev/null && [[ -f "$ELF" ]]; then
    pass "firmware compiles ($(stat -c%s "$ELF") byte ELF)"
else
    fail "firmware compiles" "run: cargo build --release"
    exit 1
fi

# The opt-out has to keep working, or the switch this experiment advertises is
# a lie. (Rebuilds into the same directory, so the ELF checked above is
# restored by the plain build at the end.)
if cargo build --release --quiet --no-default-features 2>/dev/null; then
    pass "also builds with auto-reboot disabled (--no-default-features)"
    cargo build --release --quiet 2>/dev/null   # restore the default artifact
else
    fail "also builds with auto-reboot disabled" "cargo build --release --no-default-features"
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

if [[ "$(yi26 state)" == "running" ]]; then
    pass "board enumerated as 1209:0001"
    PORT="$(exp_serial_port)"
    [[ -n "$PORT" ]] \
        && pass "serial port present: $PORT" \
        || fail "serial port present" "on USB but no /dev/ttyACM* — check dmesg"
else
    echo "SKIP  board running exp105 — flash it with ./run.sh (not an error)"
fi

exit "$FAILED"
