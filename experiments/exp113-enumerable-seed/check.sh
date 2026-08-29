#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp113 quick check — non-interactive verdict.
# Builds and converts, and if the board is running this firmware, confirms it
# built a seed and then broke it. Comparing boot-timer values across several
# boots is what run.sh does.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # the board prints how long it took to crack the seed
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp113-enumerable-seed
UF2=target/exp113-enumerable-seed.uf2

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

if ! exp_running 113; then
    echo "SKIP  board is not running exp113 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board enumerated as 1209:0001"

# The result arrives just after the three-second delay that lets USB settle,
# so this has to read past it.
# Long enough to catch a repeated `result:` line, which the firmware emits
# every ten seconds. The detailed lines are printed once, three seconds after
# boot; a check that only worked when attached before that moment would mostly
# not work at all.
OUT="$(exp_read_log 12)"

if echo "$OUT" | grep -q 'result: seed = otp'; then
    LINE="$(echo "$OUT" | grep -o 'result: seed = otp.*' | tail -1)"
    pass "seed was recovered by brute force"
    echo "      $LINE"
elif echo "$OUT" | grep -q 'result: not recovered'; then
    fail "seed was recovered by brute force" "the board booted slower than 2^24 us — raise SEARCH_BITS"
else
    fail "experiment reported a result" "no 'result:' line in 12 s"
fi

# The extrapolation is the part most likely to rot silently: it is arithmetic
# on a measurement, and a units mistake there produces a plausible-looking
# number. Measured here at about 19 seconds for a full 2^24 sweep, so anything
# far outside that means the maths broke rather than the board.
#
# Only checked when the boot-time lines are in the capture — they print once,
# and their absence means we attached late, not that anything is wrong.
FULL_MS="$(echo "$OUT" | grep -o 'would take about [0-9]* ms' | grep -o '[0-9]*')"
if [[ -z "$FULL_MS" ]]; then
    echo "SKIP  full-sweep extrapolation — attached after boot, that line prints once"
elif (( FULL_MS > 2000 && FULL_MS < 600000 )); then
    pass "full-sweep extrapolation is sane (${FULL_MS} ms for 2^24)"
else
    fail "full-sweep extrapolation is sane" "got '${FULL_MS} ms' — expected roughly 19000; check the units"
fi

# The heartbeat is the evidence that the search yielded often enough. Its
# absence during the crack is what bricked USB enumeration in development.
BEATS="$(echo "$OUT" | grep -c 'heartbeat #' || true)"
if (( BEATS >= 3 )); then
    pass "heartbeat ran throughout ($BEATS beats) — the search yields"
else
    fail "heartbeat ran throughout" "only $BEATS beats — the search is starving the executor"
fi

exit "$FAILED"
