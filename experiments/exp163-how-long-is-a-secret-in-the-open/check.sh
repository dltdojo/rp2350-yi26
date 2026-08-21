#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp163 quick check — non-interactive.
#
# Seven candidates, one per boot. Three of them are controls whose failure
# makes every other line unreadable, three measure the remedy, and one prices
# it. This asserts the controls, asserts the shape of the firmware that makes
# the measurement mean anything, and then hands the log to verify.py, which
# reconciles the numbers each candidate logged at the time against the numbers
# bank 9 carried through six watchdog resets to the final report.
#
# What is deliberately NOT asserted here is candidate 6's answer. "Is wiping
# just the frame enough?" is the open question exp160 ended on, and a check
# that demands a particular answer to an open question is not a check.
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
ELF=target/$TARGET/release/exp163-how-long-is-a-secret-in-the-open
UF2=target/exp163.uf2

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

CODE="$(grep -vE '^\s*(///|//!|//)' src/main.rs)"

# ACCESSCTRL.LOCK makes a configuration permanent until a power cycle and
# cannot be undone by software. Every candidate here shuts bank 8 and must
# leave it recoverable. Matched on the accessor, not the word: "block" contains
# "lock", and this firmware talks about blocks.
if grep -qE '\.lock\s*\(' <<< "$CODE"; then
    fail "the firmware never writes ACCESSCTRL.LOCK" "found a call to .lock() in code"
else
    pass "the firmware never writes ACCESSCTRL.LOCK"
fi

if grep -qE '\b(otp|flash)\s*\.\s*(write|program)|write_ecc|erase' <<< "$CODE"; then
    fail "the firmware writes nothing permanent" "found a flash or OTP write"
else
    pass "the firmware writes nothing permanent (no flash, no OTP)"
fi

# **The guard for the bug that made the first run meaningless.** `SIGNATURE`
# and `PUBLIC_KEY` are written by sign_once and, without the fingerprint lines,
# read by nobody — so LLVM removed both statics and every reason to compute the
# signature with them. `.bss` came out 517 bytes smaller than the two together
# and five candidates measured a signature that was never made. Sizes, from the
# ELF, on every run.
SIZES="$(nm --print-size "$ELF" 2>/dev/null)"
SIG_HEX="$(awk '/SIGNATURE/ {print $2; exit}' <<< "$SIZES")"
PK_HEX="$(awk '/PUBLIC_KEY/ {print $2; exit}' <<< "$SIZES")"
SIG_SZ=$((16#${SIG_HEX:-0}))
PK_SZ=$((16#${PK_HEX:-0}))
if [[ "$SIG_SZ" == "3309" && "$PK_SZ" == "1952" ]]; then
    pass "the signature and public key survive optimisation ($SIG_SZ + $PK_SZ bytes in .bss)"
else
    fail "the signature and public key survive optimisation" \
         "got $SIG_SZ + $PK_SZ; if either is 0 the signature is not being computed"
fi

# The shape the whole run depends on: core 1 lives in bank 9, which is outside
# the 512 KB it scans and outside the bank the secret is in. A `static` stack
# would be placed in the main SRAM, and candidate 3 would find the watcher.
if grep -q 'const MAILBOX: usize = BANK9 + CORE1_STACK_BYTES;' <<< "$CODE" \
   && grep -q 'BANK9 as \*mut Stack<CORE1_STACK_BYTES>' <<< "$CODE"; then
    pass "core 1's stack and mailbox are in bank 9, outside what it scans"
else
    fail "core 1's stack and mailbox are in bank 9" \
         "a static in the main SRAM makes candidate 3 measure this firmware"
fi

# The harness must not be the leak. The seed exists as bytes in exactly one
# place outside bank 8 — inside sign_once's frame — and that is the frame every
# candidate paints, wipes and sweeps.
if grep -q '#\[inline(always)\]' <<< "$(grep -B2 'fn seed_from_bank8' src/main.rs)"; then
    pass "seed_from_bank8 is inlined into the frame that gets wiped"
else
    fail "seed_from_bank8 is inlined into the frame that gets wiped" \
         "out of line, the seed lives in a frame nothing here accounts for"
fi
if grep -q 'mb_write(MB_NEEDLE + i \* 4, keystore_word(4 + i \* 4).swap_bytes());' <<< "$CODE"; then
    pass "the needle goes bank 8 -> bank 9 through registers, never an array"
else
    fail "the needle goes bank 8 -> bank 9 through registers" \
         "a [u8; 32] here would put the seed in the region the watcher scans"
fi
if grep -q 'core::ptr::write_volatile(b as \*mut u8, 0)' <<< "$CODE"; then
    pass "the buffer the TRNG filled is wiped, volatile, on the boot that fills it"
else
    fail "the buffer the TRNG filled is wiped" \
         "SRAM survives a watchdog reset; boot 1's seed would still be there at boot 5"
fi

# The wipe is the subject. If an optimiser decided a region nobody reads did
# not need writing, every candidate would still pass and none would mean
# anything — which is how hand-written wipes disappear in release builds.
if grep -q 'core::ptr::write_volatile(a as \*mut u32, 0)' <<< "$(sed -n '/^fn wipe/,/^}/p' src/main.rs)"; then
    pass "the wipe writes volatile, so it cannot be optimised out"
else
    fail "the wipe writes volatile" "a wipe the compiler removed reads as a wipe that worked"
fi
grep -q 'const PAINT: u32 = 0xC5C5_C5C5;' <<< "$CODE" \
    && pass "the paint is not zero, so a wipe and an untouched word differ" \
    || fail "the paint is not zero" "low_water cannot tell the wipe from the paint"

# Fixed message, fixed seed: candidates 4-7 must do byte-identical work, or
# their timings cannot be subtracted from one another. exp160 measured 3.9x
# between two signatures of different messages.
if grep -q 'const MESSAGE: \[u8; SEED_LEN\]' <<< "$CODE" \
   && ! grep -q 'blocking_fill_bytes(&mut challenge)' <<< "$CODE"; then
    pass "every candidate signs the same fixed message"
else
    fail "every candidate signs the same fixed message" \
         "rejection sampling makes signing time message-dependent; the timings would not compare"
fi

grep -q 'the mailbox and result records do not fit in bank 9' <<< "$CODE" \
    && pass "the bank 9 layout is checked at build time" \
    || fail "the bank 9 layout is checked at build time" "a record could run off the end of the bank"

grep -q 'assert!(' src/main.rs && grep -q 'PRODUCT.len()' src/main.rs \
    && pass "the product string is bounded at build time" \
    || fail "the product string is bounded at build time" "it can overflow the control buffer"

if [[ "$(grep -n 'spawner.spawn(heartbeat' <<< "$CODE" | cut -d: -f1)" \
      -lt "$(grep -n 'Driver::new' <<< "$CODE" | cut -d: -f1)" ]]; then
    pass "the LED heartbeat starts before the USB stack"
else
    fail "the LED heartbeat starts before the USB stack" "a board that dies in USB init is dark"
fi

grep -q 'breadcrumb::disarm();' <<< "$CODE" \
    && pass "the run has a hard stop that disarms" \
    || fail "the run has a hard stop that disarms" "the watchdog would keep rebooting"

if [[ -f capture.txt ]]; then
    REPLAY="$(python3 ./verify.py < capture.txt 2>&1 | tail -1)"
    [[ "$REPLAY" == "OK" ]] \
        && pass "verify.py replays the recorded capture" \
        || fail "verify.py replays the recorded capture" "got: $REPLAY"

    # A check that cannot fail has not passed. Make candidate 5 report a
    # sighting after its wipe and require verify.py to stop agreeing — and
    # assert first that the edit changed the file, because exp160 shipped a
    # corruption test that corrupted nothing and read as a pass for it.
    CORRUPT="$(sed 's/  5 stale=0 quiet=0 during=\([0-9]*\) after=0 sweep=0/  5 stale=0 quiet=0 during=\1 after=7 sweep=0/' capture.txt)"
    if [[ "$CORRUPT" == "$(cat capture.txt)" ]]; then
        fail "the corrupted-capture test actually corrupts something" \
             "the line it edits is not in capture.txt, so the guard below is empty"
    else
        pass "the corrupted-capture test actually corrupts something"
    fi
    BROKEN="$(printf '%s\n' "$CORRUPT" | python3 ./verify.py 2>&1 | tail -1)"
    [[ "$BROKEN" != "OK" ]] \
        && pass "verify.py rejects a capture where the wipe left something (got $BROKEN)" \
        || fail "verify.py rejects a capture where the wipe left something" "it still said OK"
else
    fail "a recorded capture is checked in" "capture.txt is missing; verify.py is unreplayed"
fi

if ! exp_running 163; then
    echo "SKIP  board is not running exp163 — flash it (not an error)"
    exit "$FAILED"
fi
pass "board enumerated as 1209:0001"

# Wait for the run. Seven boots at roughly fifteen seconds each, and the port
# disappears between every pair of them, so exp_read_log returns early and a
# bare retry loop spins through in seconds on a healthy board.
OUT=""
for _ in $(seq 60); do
    OUT="$(exp_read_log 15 2>/dev/null)"
    grep -q 'VERDICT' <<< "$OUT" && break
    sleep 3
done

# Strip the timestamps: every assertion below is about what the line says,
# not about when it was said.
FINAL="$(sed -n '/exp163 done/,$p' <<< "$OUT" | sed 's/^\[[^]]*\] //')"

grep -q 'not reached' <<< "$FINAL" \
    && fail "every candidate was attempted" "the final report still lists one as not reached" \
    || pass "every candidate was attempted"

grep -q 'KILLED CORE 0' <<< "$FINAL" \
    && fail "no candidate killed the reporting core" "$(grep -o '[0-9] .* - KILLED CORE 0' <<< "$FINAL" | tail -1)" \
    || pass "no candidate killed the reporting core"

if grep -q 'NOT as expected' <<< "$FINAL"; then
    fail "all seven candidates behaved as expected" \
         "$(grep -o '[0-9] [^-]* - NOT as expected' <<< "$FINAL" | tail -1)"
else
    pass "all seven candidates behaved as expected"
fi

# The three controls, named separately, because without them a refusal is one
# failed access and a silence is one core that could not read anything.
grep -qE '^\s*1 Non-secure reads bank 8, DENIED - as expected' <<< "$FINAL" \
    && pass "control: the wall refuses the demoted core" \
    || fail "control: the wall refuses the demoted core" "nothing below means anything without it"
grep -qE '^\s*2 Non-secure reads the clock, DENIED - as expected' <<< "$FINAL" \
    && pass "control: that core cannot read TIMER0 either" \
    || fail "control: that core cannot read TIMER0 either" \
            "if it can, it is not Non-secure and the watcher is not an attacker"
grep -qE '^\s*3 stale=0 quiet=0 during=0 after=0 sweep=0' <<< "$FINAL" \
    && pass "control: a watcher with nothing to find finds nothing" \
    || fail "control: a watcher with nothing to find finds nothing" \
            "$(grep -oE '^\s*3 stale.*' <<< "$FINAL" | tail -1)"

# The finding, and the one line that carries it.
SAW="$(grep -oE '^\s*4 stale=0 quiet=0 during=[1-9][0-9]* after=[1-9][0-9]* sweep=[1-9][0-9]*' <<< "$FINAL" | tail -1)"
[[ -n "$SAW" ]] \
    && pass "a Non-secure core read the key while a Secure core was using it" \
    || fail "a Non-secure core read the key while a Secure core was using it" \
            "$(grep -oE '^\s*4 stale.*' <<< "$FINAL" | tail -1)"

WIPED="$(grep -oE '^\s*5 stale=0 quiet=0 during=[1-9][0-9]* after=0 sweep=0' <<< "$FINAL" | tail -1)"
[[ -n "$WIPED" ]] \
    && pass "and after the wipe it read nothing, in 512 KB, twice over" \
    || fail "and after the wipe it read nothing" \
            "$(grep -oE '^\s*5 stale.*' <<< "$FINAL" | tail -1)"

# And now the half the board should not be trusted to do alone.
#
# What this window holds is the final report, repeating — by the time check.sh
# runs, the seven candidate boots are hours or minutes gone and the port dropped
# between every pair of them. So verify.py gets the *board in front of us* in
# its partial mode, which checks the controls and the finding out of bank 9's
# records without the per-boot cross-check. The full reconciliation is the
# capture.txt replay above, on a run that was watched from boot 1.
VERIFY="$(python3 ./verify.py <<< "$OUT" 2>&1 | tail -1)"
case "$VERIFY" in
    OK)         pass "the board's own records hold up, re-checked off the board" ;;
    BAD)        fail "the board's own records hold up" "a control did not hold" ;;
    DISAGREE)   fail "the board's own records hold up" \
                     "what a candidate logged and what bank 9 carried are different numbers" ;;
    INCOMPLETE) fail "the window holds all seven records" \
                     "the window may be too short; the report block takes about a second" ;;
    *)          fail "off-board verification ran" "unexpected result: $VERIFY" ;;
esac

exit "$FAILED"
