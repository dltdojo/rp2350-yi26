#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp114 quick check — non-interactive verdict.
# Runs the health tests' own unit tests on this machine, builds the firmware,
# and — if the board is running it — confirms all three sources are being
# judged and that the deliberately broken one gets rejected.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # the log reports refusals; the health tests run under cargo test
presence_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp114-health-tests
UF2=target/exp114-health-tests.uf2

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

# The cutoffs are the experiment, and they are checkable without a board or a
# cross-compiler. This runs first for that reason: if 21 or 589 has drifted,
# nothing downstream means what the README says it means.
#
# Run from inside the crate, not with --manifest-path: this directory's
# .cargo/config.toml pins the build target to thumbv8m, which would send the
# test harness to the microcontroller. The crate has no such config, so from
# there `cargo test` builds for this machine, which is the entire point.
if ( cd ../../crates/entropy-health && cargo test --quiet ) > /dev/null 2>&1; then
    pass "crates/entropy-health unit tests pass (cutoffs, off-by-one, known failures)"
else
    fail "crates/entropy-health unit tests pass" "cd ../../crates/entropy-health && cargo test"
fi

if cargo build --release --quiet 2>/dev/null && [[ -f "$ELF" ]]; then
    pass "firmware compiles ($(stat -c%s "$ELF") byte ELF)"
else
    fail "firmware compiles" "run: cargo build --release"
    exit 1
fi

# The health tests have to build for the target on their own, with no std and
# no hardware. If that ever stops being true, "runs on your laptop and on the
# chip" has quietly become one or the other.
if cargo build --release --quiet --manifest-path ../../crates/entropy-health/Cargo.toml \
       --target "$TARGET" 2>/dev/null; then
    pass "crates/entropy-health builds standalone for the target"
else
    fail "crates/entropy-health builds standalone" "cd ../../crates/entropy-health && cargo build --target $TARGET"
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

if ! exp_running 114; then
    echo "SKIP  board is not running exp114 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board enumerated as 1209:0001"

# Long enough for the adaptive proportion window to close on the broken
# source, which needs 1024 samples at 256 per round.
OUT="$(exp_read_log 10)"

echo "$OUT" | grep -q 'trng  :' \
    && pass "TRNG is being judged" \
    || fail "TRNG is being judged" "no 'trng' lines in 10 s"

echo "$OUT" | grep -q 'adc   :' \
    && pass "ADC is being judged" \
    || fail "ADC is being judged" "no 'adc' lines"

# The TRNG must stay healthy. This one IS asserted: a TRNG that trips these
# cutoffs is either broken or badly configured, and exp109 covers the latter.
if echo "$OUT" | grep 'trng  :' | tail -1 | grep -q 'HEALTHY'; then
    pass "TRNG passes both continuous tests"
else
    fail "TRNG passes both continuous tests" "$(echo "$OUT" | grep 'trng  :' | tail -1)"
fi

# The known-bad source must be rejected. If it is not, the tests are not
# working — and every other line in this experiment becomes unfalsifiable.
if echo "$OUT" | grep 'broken:' | tail -1 | grep -q 'FAILED adaptive proportion'; then
    COUNT="$(echo "$OUT" | grep -o 'FAILED adaptive proportion at [0-9]*' | grep -o '[0-9]*$' | tail -1)"
    pass "the deliberately broken source is rejected (proportion $COUNT of 1024)"
else
    fail "the deliberately broken source is rejected" \
         "a known-bad input passed — the health tests are not doing anything"
fi

# Deliberately NOT asserted: the ADC's verdict. exp111 established that its
# behaviour wanders, and a check demanding a failure would fail whenever the
# chip's noise happened to be lively.
ADC_LINE="$(echo "$OUT" | grep 'adc   :' | tail -1)"
echo "NOTE  ADC verdict this run: ${ADC_LINE#*adc   : }"

exit "$FAILED"
