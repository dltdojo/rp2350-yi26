#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp129 quick check — non-interactive verdict.
# Builds, runs the draw crate's tests, then if the board is running this
# experiment, draws numbers and checks each one against the range it asked for.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # yi26 send is the whole host half; nobody has to watch a screen
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

USB_IFACE="cdc"
USB_CARRIES="log+commands"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp129-numbered-draws
UF2=target/exp129-numbered-draws.uf2

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

# The part that needs no board and proves the most. The uniformity claim is
# counted over the whole 2^32 space here; no number of draws on hardware could
# establish it, and the first version of the crate was wrong in a way only
# this catches — it rejected values for ranges that needed no rejection.
# `cd`, not `--manifest-path` — exp126 hit this first and wrote down why: that
# flag chooses the crate, not the configuration, and this directory's
# .cargo/config.toml cross-compiles, so the tests would be built for a
# Cortex-M and never run.
if (cd ../../crates/draw && cargo test --quiet) > /dev/null 2>&1; then
    pass "the draw crate's tests pass, including the preimage count over 2^32"
else
    fail "the draw crate's tests pass" "cd ../../crates/draw && cargo test"
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

# The health gate has to still be wired in. Deleting it would leave every
# check below passing and every draw looking identical — which is exp112's
# failure exactly, and the reason this is checked in the source rather than
# inferred from behaviour that cannot show it.
if grep -q 'HEALTH_FAILED' src/main.rs && grep -q 'health.push' src/main.rs; then
    pass "the health tests still gate the draw (HEALTH_FAILED, health.push)"
else
    fail "the health tests still gate the draw" "a draw over an untested source looks exactly like a good one"
fi

if ! exp_running 129; then
    echo "SKIP  board is not running exp129 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board is running exp129"

# ---------------------------------------------------------------------------
# The board half.
yi26 log --seconds 2 > /dev/null 2>&1

LO=2100
HI=2567
OUT="$(yi26 send "$LO-$HI" --seconds 3 2>/dev/null)"

LINE="$(echo "$OUT" | grep -o 'draw #[0-9]*: [0-9]*  in [0-9]*-[0-9]*' | tail -1)"
if [[ -n "$LINE" ]]; then
    pass "a draw came back ($LINE)"
else
    fail "a draw came back" "no 'draw #N: V  in LO-HI' line"
fi

# The assertion that matters: the number is inside the range it was asked for.
# A firmware that returned a constant, or that folded the range wrongly, would
# still print a confident line.
VALUE="$(echo "$LINE" | sed -n 's/.*: \([0-9]*\)  in.*/\1/p')"
if [[ -n "$VALUE" ]] && (( VALUE >= LO && VALUE <= HI )); then
    pass "the drawn number $VALUE is inside $LO-$HI"
else
    fail "the drawn number is inside $LO-$HI" "got: ${VALUE:-nothing}"
fi

# The rejection count the firmware reports has to match what the crate
# computes for the same range — 2^32 mod 468. Two implementations of one piece
# of arithmetic, and if they ever disagree one of them is wrong.
echo "$OUT" | grep -q '256 of 2\^32 rejected' \
    && pass "the firmware reports 256 rejected values for a 468-wide range" \
    || fail "the firmware reports 256 rejected values" "$(echo "$OUT" | grep -o '[0-9]* of 2^32 rejected' | tail -1)"

# A power-of-two range divides 2^32 exactly, so nothing is rejected. The first
# version of the crate got this wrong and reported a whole n; the draws would
# have been fine and the number beside them a lie.
POW="$(yi26 send '1-256' --seconds 3 2>/dev/null)"
echo "$POW" | grep -q '0 of 2\^32 rejected' \
    && pass "a power-of-two range rejects nothing" \
    || fail "a power-of-two range rejects nothing" "$(echo "$POW" | grep -o '[0-9]* of 2^32 rejected' | tail -1)"

# Sequence numbers are the only defence here against a redraw nobody mentions,
# so they have to actually advance.
A="$(echo "$OUT" | grep -o 'draw #[0-9]*' | tail -1 | tr -d 'draw #')"
B="$(echo "$POW" | grep -o 'draw #[0-9]*' | tail -1 | tr -d 'draw #')"
if [[ -n "$A" && -n "$B" ]] && (( B > A )); then
    pass "draw numbers advance ($A then $B) — a discarded draw leaves a gap"
else
    fail "draw numbers advance" "got '$A' then '$B'"
fi

# Refusals are named, not silent. A prize draw that quietly ignores a
# malformed command is worse than one that argues.
BAD="$(yi26 send 'hello' --seconds 3 2>/dev/null)"
echo "$BAD" | grep -q 'not a range: "hello"' \
    && pass "a command that is not a range is refused and quoted back" \
    || fail "a command that is not a range is refused" "no 'not a range' line"

EMPTY="$(yi26 send '2567-2100' --seconds 3 2>/dev/null)"
echo "$EMPTY" | grep -q '2567-2100 is empty' \
    && pass "a reversed range is refused rather than silently swapped" \
    || fail "a reversed range is refused" "no 'is empty' line"

echo "NOTE  none of this shows the draw was fair — see exp111. What is checked"
echo "      is that the mapping cannot be biased, that a failing source cannot"
echo "      emit, and that a discarded draw leaves a visible gap."

exit "$FAILED"
