#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp111 quick check — non-interactive verdict.
# Builds and converts, and if the board is running this firmware, confirms
# both sources are being scored by both tests.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # the counts arrive in the log; the tests also run with cargo test
presence_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp111-measuring-randomness
UF2=target/exp111-measuring-randomness.uf2

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

if ! exp_running 111; then
    echo "SKIP  board is not running exp111 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board enumerated as 1209:0001"

# Long enough to get past the first few rounds, where every number is noise.
OUT="$(exp_read_log 12)"

echo "$OUT" | grep -q 'ones  *after' \
    && pass "monobit test is reporting" \
    || fail "monobit test is reporting" "no 'ones after' lines in 12 s"

echo "$OUT" | grep -q 'changes  *after' \
    && pass "transition test is reporting" \
    || fail "transition test is reporting" "no 'changes after' lines"

# Both sources must appear on every scored line. A line missing one column
# would still parse and would silently turn the experiment into a monologue.
echo "$OUT" | grep 'ones  *after' | tail -1 | grep -q 'trng .*adc-lsb' \
    && pass "both sources are being scored" \
    || fail "both sources are being scored" "the last 'ones' line is missing a column"

# The TRNG has to look like a fair coin on both tests. Loose bounds on
# purpose: this is checking that the hardware is producing entropy at all,
# not certifying its quality, and a tight bound over a couple of thousand
# bits would fail honestly-random data often enough to be useless.
for TEST in ones changes; do
    PCT="$(echo "$OUT" | grep "^\[.*$TEST  *after" | grep -o 'trng [0-9]*' | grep -o '[0-9]*$' | tail -1)"
    if [[ -n "$PCT" ]] && (( PCT >= 35 && PCT <= 65 )); then
        pass "TRNG is near a fair coin on '$TEST' ($PCT%)"
    else
        fail "TRNG is near a fair coin on '$TEST'" "got '$PCT%' — outside 35..65"
    fi
done

# Deliberately NOT checked: that the ADC column fails. It sometimes passes,
# and that is documented in the README as the actual finding rather than
# papered over. A check that asserted otherwise would be a check that fails
# for telling the truth.
echo "NOTE  the ADC column is not asserted on — it sometimes passes, which is the point"

exit "$FAILED"
