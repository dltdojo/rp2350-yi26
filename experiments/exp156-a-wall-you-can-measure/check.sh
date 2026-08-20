#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp156 quick check — non-interactive verdict.
# Builds and converts, and if the board is running this firmware, reads its
# verdict. The verdict itself is the experiment's finding; this asserts that
# one was reached and that the control held, not which way it went.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # the board prints both halves; nothing here needs a hand on it
presence_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp156-a-wall-you-can-measure
UF2=target/exp156-a-wall-you-can-measure.uf2

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

# ACCESSCTRL.LOCK makes a configuration survive until reset and cannot be
# undone by software. This experiment is meant to be re-runnable and reversible
# by a power cycle, so the absence of that call is checked rather than intended.
# Writing it, not naming it. The first version of this guard grepped for
# `.lock()` at all, and then failed the moment the experiment started *reading*
# LOCK to find out what the bootrom had left there — which is exactly the kind
# of question this experiment exists to ask. A guard that forbids looking at a
# register is not protecting anything; what must never happen is the write.
if grep -qE '\.lock\(\)\.(write|modify)' src/main.rs; then
    fail "the firmware never writes ACCESSCTRL.LOCK" "src/main.rs writes it — that survives until reset with no software undo"
else
    pass "the firmware never writes ACCESSCTRL.LOCK"
fi

# The target address is taken from the PAC. A hardcoded one is how the first
# draft came to deny I2C1 and read I2C0 — which would have reported no wall,
# convincingly. Guarded because the mistake is invisible in a passing build.
if grep -qE 'const TARGET.*0x[0-9a-fA-F_]+ as \*const' src/main.rs; then
    fail "the target address comes from the PAC" "src/main.rs hardcodes an address"
else
    pass "the target address comes from the PAC"
fi

# The target peripheral is taken out of reset before it is read.
#
# Two builds died on this. Peripherals come up held in reset on this chip, and
# reading one that still is faults — so the ladder's first read faulted on
# core 0, the core holding USB, and the board went dark three seconds in with
# nothing said. A peripheral this experiment does not otherwise use is exactly
# the kind that nobody remembers to un-reset.
if grep -q 'reset_done()' src/main.rs; then
    pass "the target peripheral is taken out of reset before it is read"
else
    fail "the target peripheral is taken out of reset before it is read" \
         "no reset_done() wait in src/main.rs — a peripheral in reset faults when read"
fi

# Every ACCESSCTRL write carries the key.
#
# Measured on hardware: reads of this block work and an identity write faults,
# so writes are refused whatever the value — the shape of a register with a
# write key in its top half. rp-pac models no key, so `modify()` reads a
# register whose top half is zero and writes zero back, which is precisely the
# write that gets refused. A helper that cannot forget the key is the only safe
# shape, and this fails if a raw write_value or modify appears beside it.
if grep -nE 'ACCESSCTRL\.[a-z_0-9]+\(\)\.(modify|write)\b' src/main.rs | grep -qv 'force_core_ns'; then
    fail "every ACCESSCTRL write goes through the keyed helper" \
         "a bare modify()/write() on ACCESSCTRL — it will drop the key and fault"
else
    pass "every ACCESSCTRL write goes through the keyed helper"
fi

# Nothing that can hang may run before USB is initialised.
#
# The first build of this experiment configured ACCESSCTRL and called
# spawn_core1 in main(), three lines before Driver::new — and spawn_core1
# blocks on fifo_read() waiting for a core 1 that could not answer. The board
# went silent with no way to say why, which is the one outcome this repository
# spends effort making impossible. The risky steps live in verdict_task now,
# which cannot start until the USB stack is up, so this asserts main() is clean.
MAIN_BODY="$(sed -n '/^async fn main(/,$p' src/main.rs)"
if grep -qE 'spawn_core1\(|deny_non_secure\(\)|demote_core1\(\)' <<< "$MAIN_BODY"; then
    fail "nothing that can hang runs before USB" \
         "main() calls spawn_core1 or the ACCESSCTRL writes — they belong in verdict_task, after enumeration"
else
    pass "nothing that can hang runs before USB"
fi

if ! exp_running 156; then
    echo "SKIP  board is not running exp156 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board enumerated as 1209:0001"

# The verdict lands about six seconds in and repeats every ten.
OUT="$(exp_read_log 20)"

SECURE="$(echo "$OUT" | grep -o 'core 0 (Secure) read [0-9a-fx]*' | tail -1)"
if [[ -n "$SECURE" ]]; then
    pass "the control ran — $SECURE"
else
    fail "the control ran" "no Secure read reported in 20 s"
fi

if echo "$OUT" | grep -q 'VERDICT:'; then
    pass "a verdict was reached"
    echo "      $(echo "$OUT" | grep -o 'VERDICT:.*' | tail -1)"
else
    fail "a verdict was reached" "no VERDICT line in 20 s — see the core 1 step it reports"
fi

exit "$FAILED"
