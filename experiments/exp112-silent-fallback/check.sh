#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp112 quick check — non-interactive verdict.
# Builds both variants, confirms each stamps the right marker, and — if the
# board is running one of them — reports which. Rebooting to compare byte
# sequences is what run.sh does.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # the marker is in the artifact and the fallback is in the log
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp112-silent-fallback
HW_UF2=target/exp112-hardware.uf2
SW_UF2=target/exp112-software.uf2

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

# Broken variant first, so the working one is what is left on disk and in
# target/release — the same reason run.sh ends by reflashing the good build.
if cargo build --release --quiet --no-default-features --features auto-reboot 2>/dev/null \
   && elf2flash convert -b rp2350 "$ELF" "$SW_UF2" > /dev/null 2>&1; then
    pass "software-fallback variant builds and converts"
else
    fail "software-fallback variant builds" "cargo build --release --no-default-features --features auto-reboot"
    exit 1
fi

if cargo build --release --quiet 2>/dev/null \
   && elf2flash convert -b rp2350 "$ELF" "$HW_UF2" > /dev/null 2>&1; then
    pass "hardware-rng variant builds and converts ($(stat -c%s "$HW_UF2") bytes)"
else
    fail "hardware-rng variant builds" "run: cargo build --release"
    exit 1
fi

FAMILY="$(od -An -tx4 -j28 -N4 "$HW_UF2" | tr -d ' ')"
[[ "$FAMILY" == "e48bff59" ]] \
    && pass "UF2 family ID is e48bff59 (rp2350-arm-s)" \
    || fail "UF2 family ID is e48bff59 (rp2350-arm-s)" "got: $FAMILY"

# The markers are the point of the experiment. If they ever stopped tracking
# the build, audit.sh would report a confident wrong answer — which is worse
# than reporting nothing.
M_HW="$(yi26 markers "$HW_UF2" | grep -m1 '^yi26-cfg:rng=')"
M_SW="$(yi26 markers "$SW_UF2" | grep -m1 '^yi26-cfg:rng=')"
[[ "$M_HW" == "yi26-cfg:rng=hardware" ]] \
    && pass "hardware build stamps 'rng=hardware'" \
    || fail "hardware build stamps 'rng=hardware'" "got: '${M_HW:-nothing}'"
[[ "$M_SW" == "yi26-cfg:rng=software" ]] \
    && pass "software build stamps 'rng=software'" \
    || fail "software build stamps 'rng=software'" "got: '${M_SW:-nothing}'"

# Both variants must also keep the reboot watcher, or the reader ends up
# holding BOOTSEL to escape an experiment about build flags.
yi26 markers "$SW_UF2" | grep -q 'yi26-cfg:auto-reboot=on' \
    && pass "software variant keeps the 1200-baud watcher (still reflashable)" \
    || fail "software variant keeps the 1200-baud watcher" "--features auto-reboot was dropped"

if ! exp_running 112; then
    echo "SKIP  board is not running exp112 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board enumerated as 1209:0001"

# Long enough for a scored line, which appears every five rounds. The boot
# banner is deliberately not what is checked here: it prints once, and a check
# that only works if you attached before boot is a check that mostly does not.
OUT="$(exp_read_log 6)"

echo "$OUT" | grep -q 'tests after [0-9]* bits' \
    && pass "generator is producing scored output" \
    || fail "generator is producing scored output" "no 'tests after' lines in 6 s"

# Report which variant is running rather than asserting one. Either is a
# legitimate state for this experiment, and a check that failed on the broken
# variant would be a check that fails for the demonstration working.
if echo "$OUT" | grep -q '\[software\] tests after'; then
    echo "NOTE  the software-fallback variant is on the board — that is the demonstration"
    echo "      ./audit.sh exp112-silent-fallback says so from the artifact, not the log"
elif echo "$OUT" | grep -q '\[hardware\] tests after'; then
    pass "the intended hardware-rng variant is on the board"
else
    fail "every scored line names its generator" "no '[hardware]' or '[software]' tag found"
fi

exit "$FAILED"
