#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp118 quick check — non-interactive verdict.
# Builds, then if the board is running this experiment, sends bytes and
# confirms the firmware reports exactly the bytes that were sent.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp118-one-receiver-two-jobs
UF2=target/exp118-one-receiver-two-jobs.uf2

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
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

# The reboot watcher has to still be in there. This experiment moved that job
# out of usb_reboot::watch and into its own select loop, which is exactly the
# kind of change that can silently drop it — and dropping it means the next
# person to flash this board needs a BOOTSEL button and a hand.
if strings "$UF2" | grep -q 'yi26-cfg:auto-reboot=on'; then
    pass "auto-reboot is compiled in (the board can still be reflashed)"
else
    fail "auto-reboot is compiled in" "built with --no-default-features? this board will need BOOTSEL by hand"
fi

if ! exp_running 118; then
    echo "SKIP  board is not running exp118 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board is running exp118"

# ---------------------------------------------------------------------------
# The board half. Everything below sends real bytes and reads the firmware's
# account of them, because the only thing that settles whether a device
# received what you sent is the device saying so.

# Drain first, and not out of superstition. crates/usb-log holds sixteen lines
# and will not write any of them until the host asserts DTR, so a board nobody
# has listened to for a few minutes has a queue full of stale idle lines. The
# first open flushes those, and lines produced *during* that flush are dropped
# for want of room — which is the logger working as documented, and which made
# this check fail once against a firmware that was receiving perfectly.
#
# The subject here is whether the bytes arrived, not whether the log queue
# survives a long silence. Emptying it first keeps the two questions apart.
yi26 log --seconds 2 > /dev/null 2>&1

OUT="$(yi26 send 'A\x00\xff\ttab\r\nZ' --seconds 4 2>/dev/null)"

echo "$OUT" | grep -q 'in #[0-9]*: 10 bytes' \
    && pass "the firmware received all 10 bytes" \
    || fail "the firmware received all 10 bytes" "no 'in #N: 10 bytes' line"

# The exact hex, not a substring of it. A dump that loses a byte in the middle
# still contains most of the right characters.
echo "$OUT" | grep -q '41 00 ff 09 74 61 62 0d 0a 5a' \
    && pass "every byte arrived unaltered, NUL and 0xff included" \
    || fail "every byte arrived unaltered" "the hex column does not match what was sent"

echo "$OUT" | grep -q 'A\.\.\.tab\.\.Z' \
    && pass "unprintable bytes render as dots, one per byte" \
    || fail "unprintable bytes render as dots" "the text column is not 'A...tab..Z'"

# 100 bytes has to come back as two packets. If this ever reports one, either
# the endpoint size changed or something started reassembling behind our back —
# and the experiment's main claim would be wrong.
BIG="$(yi26 send "$(printf 'A%.0s' $(seq 1 100))" --seconds 4 2>/dev/null)"
if echo "$BIG" | grep -q ': 64 bytes' && echo "$BIG" | grep -q ': 36 bytes'; then
    pass "100 bytes arrived as two packets, 64 + 36"
else
    fail "100 bytes arrived as two packets, 64 + 36" "$(echo "$BIG" | grep -o 'in #[0-9]*: [0-9]* bytes' | tr '\n' ' ')"
fi

# A zero-length read is a USB event, not a message, and counting it would put
# every sequence number out by one. exp119's question depends on these numbers
# meaning something.
if echo "$OUT$BIG" | grep -q 'in #0:'; then
    fail "sequence numbers start at 1" "found 'in #0' — the counter is off"
else
    pass "sequence numbers are not thrown off by zero-length packets"
fi

exit "$FAILED"
