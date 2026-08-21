#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp159 quick check — non-interactive.
#
# The board walks four candidates, one per boot, and ends holding a public key,
# a challenge and a signature. This asserts the matrix AND verifies the
# signature **off the board**, with an implementation that is not the one that
# produced it — which is the only version of "the signature is real" worth
# having. It also flips a bit and requires the verification to fail, because a
# check that cannot fail has not passed (exp140).
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
ELF=target/$TARGET/release/exp159-a-key-that-was-never-in-flash
UF2=target/exp159-a-key-that-was-never-in-flash.uf2

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

# THE guard for this experiment, and the reason it exists at all.
#
# A private key compiled into the source would live in flash, and XIP_MAIN
# defaults to fully open access — so Non-secure code could read it straight out
# of flash and the wall around bank 8 would be guarding a copy. The key must
# come from the TRNG at runtime. This greps for a 32-byte literal that looks
# like a key, and for the TRNG call that has to be there instead.
if grep -qE '\[[0-9]+u8; ?32\] *= *\[0x|SigningKey::from_bytes\(&\[' src/main.rs; then
    fail "no private key is compiled into the firmware" \
         "a key literal in the source lives in flash, which Non-secure code can read"
else
    pass "no private key is compiled into the firmware"
fi

if grep -q 'blocking_fill_bytes' src/main.rs; then
    pass "the key comes from the hardware TRNG at runtime"
else
    fail "the key comes from the hardware TRNG at runtime" "no TRNG call in src/main.rs"
fi

# Never lock ACCESSCTRL: it survives until reset with no software undo.
if grep -qE '\.lock\(\)\.(write|modify)' src/main.rs; then
    fail "the firmware never writes ACCESSCTRL.LOCK" "that survives until reset with no software undo"
else
    pass "the firmware never writes ACCESSCTRL.LOCK"
fi

# embassy-usb asserts pos + 2 < buf.len() per UTF-16 unit while building string
# descriptors, so 64 bytes means 30 characters. exp157 lost two board recoveries
# to a 31-character name that panicked mid-enumeration.
grep -q 'const _: () = assert!' src/main.rs \
    && pass "the product string is bounded at build time" \
    || fail "the product string is bounded at build time" "no const assertion in src/main.rs"

LED_LINE="$(grep -n 'spawner.spawn(heartbeat' src/main.rs | head -1 | cut -d: -f1)"
USB_LINE="$(grep -n 'let driver = Driver::new' src/main.rs | head -1 | cut -d: -f1)"
if [[ -n "$LED_LINE" && -n "$USB_LINE" && "$LED_LINE" -lt "$USB_LINE" ]]; then
    pass "the LED heartbeat starts before the USB stack"
else
    fail "the LED heartbeat starts before the USB stack" \
         "dark and died-in-enumeration are the same signal without it"
fi

grep -q 'LAST_BOOT' src/main.rs && grep -q 'breadcrumb::disarm()' src/main.rs \
    && pass "the run has a hard stop that disarms" \
    || fail "the run has a hard stop that disarms" "a board can end up in a reboot loop"

if ! exp_running 159; then
    echo "SKIP  board is not running exp159 — flash it (not an error)"
    exit "$FAILED"
fi
pass "board enumerated as 1209:0001"

# Wait for the matrix. The port disappears between boots, so exp_read_log
# returns immediately rather than taking its window — a bare retry loop spins
# through in seconds and reports failures on a healthy board.
OUT=""
for _ in $(seq 24); do
    OUT="$(exp_read_log 10 2>/dev/null)"
    grep -q 'exp159 done' <<< "$OUT" && break
    sleep 3
done

# Assert on the FINAL report block, not on the whole window.
#
# Every boot opens by printing the matrix as it stood when that boot started, so
# "not reached" appears legitimately in the early ones — it is the harness being
# honest about what had not happened yet. A check that greps the whole capture
# reads those as failures, which it did, on a run where all four candidates had
# in fact been walked.
FINAL="$(sed -n '/exp159 done/,$p' <<< "$OUT")"

grep -q 'not reached' <<< "$FINAL" \
    && fail "every candidate was attempted" "the final report still lists one as not reached" \
    || pass "every candidate was attempted"

if grep -q 'NOT as expected' <<< "$FINAL"; then
    fail "every candidate behaved as expected" "$(grep -o '[0-9] [^-]* - NOT as expected' <<< "$FINAL" | tail -1)"
else
    pass "every candidate behaved as expected"
fi

# The controls, named separately. Without them a refusal is one failed access.
grep -q '1 Secure reads the key - as expected' <<< "$FINAL" \
    && pass "control: Secure read the key out of bank 8" \
    || fail "control: Secure read the key out of bank 8" "nothing below means anything without it"

grep -q '2 Non-secure reads it, allowed - as expected' <<< "$FINAL" \
    && pass "control: Non-secure read it while the bank was OPEN" \
    || fail "control: Non-secure read it while the bank was OPEN" \
            "a demoted core could not read what it was allowed to, so a refusal proves nothing"

grep -q '3 Non-secure reads it, DENIED - as expected' <<< "$FINAL" \
    && pass "the wall: Non-secure was refused once the bank was SHUT" \
    || fail "the wall: Non-secure was refused once the bank was SHUT" "the key was not protected"

grep -q '4 Non-secure asks for a signature - as expected' <<< "$FINAL" \
    && pass "Non-secure got 64 bytes back with the bank still SHUT" \
    || fail "Non-secure got 64 bytes back with the bank still SHUT" "the gateway did not answer"

# And now the half the board cannot check about itself.
#
# verify.py is a separate file so it can be run by hand on a pasted log, which
# is what somebody debugging from a phone will actually have. It also proves the
# check can fail before reporting that it passed.
VERIFY="$(echo "$OUT" | python3 ./verify.py 2>&1 | tail -1)"

case "$VERIFY" in
    OK)         pass "the signature verifies off the board, and the check can fail" ;;
    BAD)        fail "the signature verifies off the board" "python-cryptography rejected it" ;;
    CANNOTFAIL) fail "the verification can fail" "a one-bit-corrupted message also verified" ;;
    MISSING)    fail "the board reported a key, a challenge and a signature" "one of PUBX/PUBY/MSG/SIGR/SIGS is absent" ;;
    NOPYCA)     echo "SKIP  python 'cryptography' not installed — cannot verify off the board" ;;
    *)          fail "off-board verification ran" "unexpected result: $VERIFY" ;;
esac

exit "$FAILED"
