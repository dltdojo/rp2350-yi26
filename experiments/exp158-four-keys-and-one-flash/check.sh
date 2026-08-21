#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp158 quick check — non-interactive.
#
# The board tries four candidate ACCESSCTRL write keys, one per boot, killing
# itself on the wrong ones and carrying on. This asserts the whole table, not
# that a table was produced: exp156 already measured which key is right, so a
# harness that mislabels a candidate or quietly retries one is caught here.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # flash it and read the log; nothing here needs a hand on the board
presence_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp158-four-keys-and-one-flash
UF2=target/exp158-four-keys-and-one-flash.uf2

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

# ACCESSCTRL.LOCK survives until reset with no software undo. This experiment is
# meant to be reversible by a power cycle, so the absence of that write is
# checked rather than intended. Writing it, not naming it — reading LOCK is a
# fair question and exp156 narrowed the same guard for that reason.
if grep -qE '\.lock\(\)\.(write|modify)' src/main.rs; then
    fail "the firmware never writes ACCESSCTRL.LOCK" "that survives until reset with no software undo"
else
    pass "the firmware never writes ACCESSCTRL.LOCK"
fi

# The product string must fit embassy-usb's control buffer: it asserts
# pos + 2 < buf.len() per UTF-16 unit, so 64 bytes means 30 characters, not 31.
# At 31 it panics mid-enumeration and panic_halt stops the executor — no log, no
# LED, no reboot. exp157 lost two board recoveries to it.
if grep -q 'const _: () = assert!' src/main.rs; then
    pass "the product string is bounded at build time"
else
    fail "the product string is bounded at build time" \
         "no const assertion — a long product name panics inside embassy-usb"
fi

# The LED comes up before the USB stack. Both patterns anchor on code, not on
# the prose that explains them.
LED_LINE="$(grep -n 'spawner.spawn(heartbeat' src/main.rs | head -1 | cut -d: -f1)"
USB_LINE="$(grep -n 'let driver = Driver::new' src/main.rs | head -1 | cut -d: -f1)"
if [[ -n "$LED_LINE" && -n "$USB_LINE" && "$LED_LINE" -lt "$USB_LINE" ]]; then
    pass "the LED heartbeat starts before the USB stack"
else
    fail "the LED heartbeat starts before the USB stack" \
         "dark and died-in-enumeration are the same signal without it"
fi

if grep -q 'LAST_BOOT' src/main.rs && grep -q 'breadcrumb::disarm()' src/main.rs; then
    pass "the run has a hard stop that disarms"
else
    fail "the run has a hard stop that disarms" \
         "without both, a board can end up in a reboot loop nothing can talk it out of"
fi

if ! exp_running 158; then
    echo "SKIP  board is not running exp158 — flash it (not an error)"
    exit "$FAILED"
fi
pass "board enumerated as 1209:0001"

# Wait for the matrix to be walked. While the board reboots there is no port, so
# exp_read_log returns immediately rather than taking its window — a bare retry
# loop spins through in seconds and concludes the firmware is broken.
OUT=""
for _ in $(seq 20); do
    OUT="$(exp_read_log 10 2>/dev/null)"
    grep -q 'exp158 done' <<< "$OUT" && break
    sleep 3
done

echo "$OUT" | grep -q 'not tried yet' \
    && fail "every candidate was attempted" "a candidate was never reached — the board stalled instead of stepping over a death" \
    || pass "every candidate was attempted"

# At least one death, or nothing was stepped over and this proves nothing about
# carrying on past one.
echo "$OUT" | grep -q 'DIED - the write faulted' \
    && pass "at least one candidate killed the board, and it came back" \
    || fail "at least one candidate killed the board, and it came back" \
            "no death in the table, so nothing demonstrates recovery"

# The answer exp156 measured over three bench trips, re-derived here in one
# flash. Both halves are asserted: the right key accepted, and only it.
echo "$OUT" | grep -qE 'key 0xacce +ACCEPTED' \
    && pass "0xacce was accepted, and the register changed" \
    || fail "0xacce was accepted, and the register changed" \
            "the known-correct key was not accepted — the harness disagrees with exp156"

echo "$OUT" | grep -q '1 of 4 keys accepted' \
    && pass "exactly one of four keys was accepted" \
    || fail "exactly one of four keys was accepted" \
            "$(echo "$OUT" | grep -o '[0-9] of 4 keys accepted' | tail -1)"

for k in 0x0000 0x5afe 0xdead; do
    echo "$OUT" | grep -qE "key $k +ACCEPTED" \
        && fail "the decoy $k was refused" "a wrong key was reported as accepted"
done
pass "all three wrong keys were refused"

echo "$OUT" | grep -q 'exp158 done' \
    && pass "the run stopped and said so" \
    || fail "the run stopped and said so" "no done line — the board may still be rebooting"

exit "$FAILED"
