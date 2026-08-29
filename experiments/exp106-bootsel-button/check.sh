#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp106 quick check — non-interactive verdict.
# Builds and converts; reports the board if it happens to be running this
# firmware. Pressing the button is a human job, so that lives in run.sh.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=3   # a finger on BOOTSEL and an eye on the LED, at the same time
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp106-bootsel-button
UF2=target/exp106-bootsel-button.uf2

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

# The BOOTSEL reader has to keep working without a HAL behind it — it pokes
# registers directly, so a broken build here is a broken hack, not a broken
# dependency.
if cargo build --release --quiet --manifest-path ../../crates/bootsel/Cargo.toml \
       --target "$TARGET" 2>/dev/null; then
    pass "crates/bootsel builds standalone (cortex-m only, no HAL)"
else
    fail "crates/bootsel builds standalone" "cd ../../crates/bootsel && cargo build --target $TARGET"
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
    echo "SKIP  board running exp106 — flash it with ./run.sh (not an error)"
fi

exit "$FAILED"
