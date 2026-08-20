#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp157 quick check — non-interactive.
#
# Builds and converts, and if the board is running this firmware, reads the
# history it kept across five boots and asserts every entry. The claim is that a
# firmware killed in a way that takes USB with it comes back able to say WHICH
# step it died in and WHICH kind of death it was — so the check names the steps
# and the kinds, not merely that something was reported.
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
ELF=target/$TARGET/release/exp157-a-note-for-the-next-boot
UF2=target/exp157-a-note-for-the-next-boot.uf2

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

# The product string must fit embassy-usb's control buffer.
#
# This one cost two board recoveries by hand. embassy-usb builds string
# descriptors into the control buffer and asserts `pos + 2 < buf.len()` per
# UTF-16 unit, so a 31-character name panics mid-enumeration with panic_halt —
# no log, no LED, no reboot, and a board that looks bricked because it is. The
# guard is a const assertion in the source: it fails the build, which is the
# only place this can be caught for free. Checked here so it cannot be deleted.
if grep -q 'const _: () = assert!' src/main.rs; then
    pass "the product string is bounded at build time"
else
    fail "the product string is bounded at build time" \
         "no const assertion in src/main.rs — a long product name panics inside embassy-usb"
fi

# The LED comes up before the USB stack.
#
# exp156's hardest-won rule, and this experiment broke it: its first builds
# froze inside enumeration with the LED dark, so "never started" and "died
# during enumeration" were one signal, and two bench trips went on telling them
# apart.
# Both patterns anchor on code, not on prose. The first version of this guard
# grepped for `Driver::new` and matched the doc comment that explains why the
# heartbeat goes first — so it failed on a source file that was correct, which
# is the same shape of mistake as exp156's first `.lock()` guard.
LED_LINE="$(grep -n 'spawner.spawn(heartbeat' src/main.rs | head -1 | cut -d: -f1)"
USB_LINE="$(grep -n 'let driver = Driver::new' src/main.rs | head -1 | cut -d: -f1)"
if [[ -n "$LED_LINE" && -n "$USB_LINE" && "$LED_LINE" -lt "$USB_LINE" ]]; then
    pass "the LED heartbeat starts before the USB stack"
else
    fail "the LED heartbeat starts before the USB stack" \
         "dark and died-in-enumeration are the same signal without it"
fi

# There is a limit, and the board is left reflashable.
if grep -q 'LAST_BOOT' src/main.rs && grep -q 'breadcrumb::disarm()' src/main.rs; then
    pass "the storm has a hard stop that disarms"
else
    fail "the storm has a hard stop that disarms" \
         "without both, a board can end up in a reboot loop nothing can talk it out of"
fi

if ! exp_running 157; then
    echo "SKIP  board is not running exp157 — flash it (not an error)"
    exit "$FAILED"
fi
pass "board enumerated as 1209:0001"

# Wait for the storm to finish before reading anything.
#
# This experiment reboots itself five times, which takes about fifty seconds,
# and during it the serial port keeps disappearing — `yi26 log` comes back with
# fragments or with "Broken pipe", both of which look exactly like a firmware
# that failed. The first version of this check read once and reported four
# failures on a board that was working perfectly.
#
# So it polls for the settled state instead of guessing at a delay, and gives up
# after a bounded time rather than hanging a non-interactive run.
# The sleep is not padding. While the board is rebooting there is no port, so
# `exp_read_log` returns an error immediately instead of taking its window —
# so a bare retry loop spins twelve times in two seconds and concludes the
# firmware is broken. It did, on a board that was working perfectly.
OUT=""
for _ in $(seq 20); do
    OUT="$(exp_read_log 10 2>/dev/null)"
    grep -q 'STOP after' <<< "$OUT" && break
    sleep 3
done

# The two controls. Without a boot that finished, "it says where it died" cannot
# be told from "it always says something died" — and a harness that can only
# report failure cannot report success.
echo "$OUT" | grep -qE 'boot 1: completed all 8 steps' \
    && pass "control: boot 1 completed" \
    || fail "control: boot 1 completed" "no clean boot reported, so a death report proves nothing"

echo "$OUT" | grep -qE 'boot 4: completed all 8 steps' \
    && pass "control: boot 4 completed after two deaths" \
    || fail "control: boot 4 completed after two deaths" "recovery left the firmware unable to finish"

# The measurement. Both the KIND and the STEP are asserted, and they differ
# between the two deaths — a harness that always answered the same thing would
# fail here, which is what makes this a check rather than a formality.
echo "$OUT" | grep -qE 'boot 2: HANG in step 3' \
    && pass "a hang was reported, with its step (2: HANG in step 3)" \
    || fail "a hang was reported, with its step" "expected 'boot 2: HANG in step 3'"

echo "$OUT" | grep -qE 'boot 3: FAULT in step 6' \
    && pass "a fault was reported, with its step (3: FAULT in step 6)" \
    || fail "a fault was reported, with its step" "expected 'boot 3: FAULT in step 6'"

# A fault reported as a hang means CTRL.TRIGGER did nothing from the handler and
# the watchdog timeout brought the board home instead. That still works, and it
# is still wrong, so it is worth saying rather than passing quietly.
if echo "$OUT" | grep -qE 'boot 3: HANG in step 6'; then
    fail "the fault was distinguished from a hang" \
         "boot 3 was recorded as a hang — CTRL.TRIGGER did not fire and the fallback timeout reset the board"
fi

echo "$OUT" | grep -q 'STOP after' \
    && pass "the storm stopped and said so" \
    || fail "the storm stopped and said so" "no STOP line — the board may still be rebooting"

exit "$FAILED"
