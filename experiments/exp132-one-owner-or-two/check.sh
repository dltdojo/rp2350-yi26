#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp132 quick check — non-interactive verdict.
# Builds both variants, then if the board is running the two-channel one,
# proves the thing this experiment exists for: a command on the vendor
# interface and the log on CDC, held by different owners at the same time.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # yi26 holds both channels; no browser and nobody in the room
presence_check

USB_IFACE="cdc+vendor"
USB_CARRIES="log+commands"
USB_HOST="cdc_acm+libusb"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp132-one-owner-or-two
ONE=target/exp132-one-channel.uf2
TWO=target/exp132-two-channels.uf2

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

if (cd ../../crates/draw && cargo test --quiet) > /dev/null 2>&1; then
    pass "the draw crate's tests pass"
else
    fail "the draw crate's tests pass" "cd crates/draw && cargo test"
fi

# Both builds, every time. An experiment whose whole subject is the difference
# between two configurations has to keep both of them compiling — and the one
# nobody flashes is the one that rots.
if cargo build --release --quiet 2>/dev/null && [[ -f "$ELF" ]]; then
    elf2flash convert -b rp2350 "$ELF" "$ONE" > /dev/null 2>&1
    pass "the one-channel build compiles and converts ($(stat -c%s "$ONE") bytes)"
else
    fail "the one-channel build compiles" "cargo build --release"
    exit 1
fi

if cargo build --release --quiet --features two-channels 2>/dev/null && [[ -f "$ELF" ]]; then
    elf2flash convert -b rp2350 "$ELF" "$TWO" > /dev/null 2>&1
    pass "the two-channel build compiles and converts ($(stat -c%s "$TWO") bytes)"
else
    fail "the two-channel build compiles" "cargo build --release --features two-channels"
    exit 1
fi

for f in "$ONE" "$TWO"; do
    FAMILY="$(od -An -tx4 -j28 -N4 "$f" | tr -d ' ')"
    [[ "$FAMILY" == "e48bff59" ]] \
        && pass "$(basename "$f") has family ID e48bff59" \
        || fail "$(basename "$f") has family ID e48bff59" "got: $FAMILY"
done

# The vendor interface must exist in one build and not the other. Checking the
# source rather than the artifact because both artifacts have the same name on
# disk; the feature is what separates them.
grep -q 'CLASS_VENDOR, SUBCLASS_NONE, PROTOCOL_NONE' src/main.rs \
    && pass "the vendor interface is built by hand, behind the feature" \
    || fail "the vendor interface is built by hand" "no builder.function(CLASS_VENDOR, ...) call"

grep -q 'cfg(feature = "two-channels")' src/main.rs \
    && pass "both shapes live in one source, chosen by a feature" \
    || fail "both shapes live in one source" "the comparison needs both to exist"

if ! exp_running 132; then
    echo "SKIP  board is not running exp132 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board is running exp132"

# ---------------------------------------------------------------------------
# The board half, and the whole point of the experiment.
#
# `yi26 echo` claims the vendor interface with libusb. The kernel's cdc_acm
# holds the CDC pair. Neither can take the other's, and this runs both at once
# on purpose: the log is read *while* the command is sent, not before or after.
yi26 log --seconds 2 > /dev/null 2>&1

LOGFILE="$(mktemp)"
trap 'rm -f "$LOGFILE"' EXIT
( yi26 log --seconds 6 > "$LOGFILE" 2>&1 & )
sleep 1

REPLY="$(yi26 echo '2100-2567' 2>&1)"
if echo "$REPLY" | grep -q 'received .* draw #[0-9]*: [0-9]*'; then
    pass "the vendor interface answered the command it was sent"
else
    fail "the vendor interface answered" "$(echo "$REPLY" | tail -1)"
fi

# The number in the reply has to be inside the range, same as exp129.
VALUE="$(echo "$REPLY" | sed -n 's/.*draw #[0-9]*: \([0-9]*\) .*/\1/p' | tail -1)"
if [[ -n "$VALUE" ]] && (( VALUE >= 2100 && VALUE <= 2567 )); then
    pass "the drawn number $VALUE is inside 2100-2567"
else
    fail "the drawn number is inside 2100-2567" "got: ${VALUE:-nothing}"
fi

sleep 5
# And the same sentence arrived on the other interface, whose owner never let
# go. This is the line exp131 could not produce: two views of one event, at
# the same time, held by different programs.
if grep -q "draw #.*in 2100-2567" "$LOGFILE"; then
    pass "the log carried the same draw, on the other interface, at the same time"
else
    fail "the log carried the same draw at the same time" "$(tail -2 "$LOGFILE" | tr '\n' ' ')"
fi

# Both owners were live simultaneously — if cdc_acm had been displaced by the
# libusb claim, the log capture above would be empty rather than merely
# missing the draw.
[[ -s "$LOGFILE" ]] \
    && pass "cdc_acm kept the log interface while libusb held the vendor one" \
    || fail "cdc_acm kept the log interface" "the log capture is empty — something took the port"

echo "NOTE  the one-channel build is compiled and converted here but not run."
echo "      Flashing it is ./run.sh's job, and the difference it demonstrates"
echo "      is what a second page cannot do — see the README."

exit "$FAILED"
