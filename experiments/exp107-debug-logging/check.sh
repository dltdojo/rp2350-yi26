#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp107 quick check — non-interactive verdict.
# Builds and converts, and if the board is running this firmware, reads the
# port briefly to confirm several tasks are logging into one stream. Pressing
# the button is a human job, so that lives in run.sh.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp107-debug-logging
UF2=target/exp107-debug-logging.uf2

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

# The log has to build on its own. It depends on the USB stack but on nothing
# from this experiment — if that ever stops being true, the "callable from any
# task, in any project" claim has quietly broken.
#
# The chip-package feature has to be supplied here because the crate itself
# deliberately does not pick one: a shared crate that hard-codes rp235xa would
# stop an RP2350B board from using it. The experiment chooses; the library does
# not.
if cargo build --release --quiet --manifest-path ../../crates/usb-log/Cargo.toml \
       --target "$TARGET" --features embassy-rp/rp235xa 2>/dev/null; then
    pass "crates/usb-log builds standalone"
else
    fail "crates/usb-log builds standalone" "cd ../../crates/usb-log && cargo build --target $TARGET"
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

if ! lsusb -d 1209:0001 > /dev/null 2>&1; then
    echo "SKIP  board running exp107 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board enumerated as 1209:0001"

PORT="$(exp_serial_port)"
if [[ -z "$PORT" ]]; then
    fail "serial port present" "on USB but no /dev/ttyACM* — check dmesg"
    exit "$FAILED"
fi
pass "serial port present: $PORT"

# Read long enough to catch at least two heartbeats and one probe report.
OUT="$(exp_read_log "$PORT" 12)"

echo "$OUT" | grep -q 'heartbeat #' \
    && pass "heartbeat task is logging" \
    || fail "heartbeat task is logging" "no 'heartbeat #' seen in 12 s"

echo "$OUT" | grep -q 'scheduler:' \
    && pass "scheduler probe is logging" \
    || fail "scheduler probe is logging" "no 'scheduler:' seen in 12 s"

# Two different tasks appearing in one stream is the structural claim: they
# share a queue and a writer, and neither has to know about the other.
SOURCES="$(echo "$OUT" | grep -oE 'heartbeat #|scheduler:|BOOTSEL ' | sort -u | wc -l)"
[[ "$SOURCES" -ge 2 ]] \
    && pass "$SOURCES independent tasks interleaved in one stream" \
    || fail "independent tasks interleaved in one stream" "only $SOURCES source(s) seen"

# Heartbeats are numbered, so a gap is detectable rather than a matter of
# opinion. Consecutive numbering is the machine-checkable form of "the log
# stalling did not stall anything else".
#
# Only the live section counts. If the board had been running unread, the
# first thing out of the port is the queued backlog from before, and the jump
# from backlog to live is a real, expected gap — the loss marker is where it
# happened, so analysis starts there.
LIVE="$(echo "$OUT" | sed -n '/lines lost/,$p')"
[[ -n "$LIVE" ]] || LIVE="$OUT"
SEQS="$(echo "$LIVE" | grep -o 'heartbeat #[0-9]*' | grep -o '[0-9]*')"
GAPS=0
PREV=""
while read -r n; do
    [[ -z "$n" ]] && continue
    if [[ -n "$PREV" && $((n - PREV)) -ne 1 ]]; then GAPS=$((GAPS + 1)); fi
    PREV="$n"
done <<< "$SEQS"
if [[ -z "$PREV" ]]; then
    fail "heartbeat sequence unbroken" "no heartbeats captured"
elif [[ "$GAPS" -eq 0 ]]; then
    pass "heartbeat sequence unbroken while reading"
else
    fail "heartbeat sequence unbroken" "$GAPS gap(s) — lines were dropped during a read"
fi

exit "$FAILED"
