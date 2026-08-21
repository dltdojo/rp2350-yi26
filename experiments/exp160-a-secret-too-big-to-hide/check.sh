#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp160 quick check — non-interactive.
#
# The board walks five candidates, one per boot, and ends holding a public key,
# a challenge and a 3,309-byte signature. This asserts the matrix, and then
# hands the log to verify.py, which checks the signature with an implementation
# that is not the one that produced it and flips a bit to prove it can fail.
#
# The candidate this experiment exists for is the fifth, and its expected
# outcome is a LEAK. `5 ... - as expected` here means Non-secure code read the
# private key out of open SRAM while the wall around bank 8 was still standing.
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
ELF=target/$TARGET/release/exp160-a-secret-too-big-to-hide
UF2=target/exp160-a-secret-too-big-to-hide.uf2

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

# THE guard for this road, inherited from exp159 and still the reason it exists.
#
# A private key compiled into the source would live in flash, and XIP_MAIN
# defaults to fully open access — so Non-secure code could read it straight out
# of flash and the wall around bank 8 would be guarding a copy. The seed must
# come from the TRNG at runtime.
#
# KAT_SEED is exempt by name and only by name. It is all zeros, it is published,
# and the two checks below assert that it is never treated as a key.
if grep -vE '^\s*(///|//!)' src/main.rs | grep -v 'KAT_SEED' \
   | grep -qE '\[[0-9]+u8; ?32\] *= *\[0x|from_seed\(&Array\(\[0x'; then
    fail "no private key is compiled into the firmware" \
         "a key literal in the source lives in flash, which Non-secure code can read"
else
    pass "no private key is compiled into the firmware"
fi

if grep -qE 'const KAT_SEED: \[u8; SEED_LEN\] = \[0u8; SEED_LEN\];' src/main.rs; then
    pass "the known-answer seed is all zeros, and published"
else
    fail "the known-answer seed is all zeros, and published" \
         "a KAT seed that is not obviously public is a key literal wearing a label"
fi

if grep -n 'KAT_SEED' src/main.rs | grep -vE '^\s*[0-9]+:\s*(///|//!)' \
   | grep -qE 'keystore_write|sign_deterministic'; then
    fail "the known-answer seed never signs and never reaches bank 8" \
         "KAT_SEED appears on a line that stores or signs"
else
    pass "the known-answer seed never signs and never reaches bank 8"
fi

if grep -q 'blocking_fill_bytes' src/main.rs; then
    pass "the signing seed comes from the hardware TRNG at runtime"
else
    fail "the signing seed comes from the hardware TRNG at runtime" "no TRNG call in src/main.rs"
fi

# Never lock ACCESSCTRL: it survives until reset with no software undo.
if grep -qE '\.lock\(\)\.(write|modify)' src/main.rs; then
    fail "the firmware never writes ACCESSCTRL.LOCK" "that survives until reset with no software undo"
else
    pass "the firmware never writes ACCESSCTRL.LOCK"
fi

# The sweep is only an observation if the region was known-clean first. Without
# the paint, a hit could be anything any earlier boot left lying there.
if grep -q 'fn paint(' src/main.rs && grep -q 'paint(lo, hi);' src/main.rs; then
    pass "the sweep region is painted before the signature is made"
else
    fail "the sweep region is painted before the signature is made" \
         "an unpainted hit proves nothing about this signature"
fi

# The experiment whose finding is that a private key leaked must not be the thing
# that publishes it. Its log is pasted into READMEs and rendered by web pages, so
# the bytes core 1 grabbed are printed eight at a time and the 32-byte comparison
# happens on the board.
if grep -qE 'log_hex32\("GRAB"|log_hex32\("SEED"|log_hex32\("KEY' src/main.rs; then
    fail "the firmware never logs a whole private key" \
         "a full seed in the log ends up in a README and on a page"
else
    pass "the firmware never logs a whole private key"
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

# Lever 4: the parser is replayed against a recorded capture, so a board trip is
# never spent discovering that verify.py has never seen real output. This one is
# a real board capture; before there was one it was a synthetic block in the
# same format, which is what caught the chunk-index handling.
if [[ -f capture.txt ]]; then
    REPLAY="$(python3 ./verify.py < capture.txt 2>&1 | tail -1)"
    case "$REPLAY" in
        OK)      pass "verify.py replays the recorded capture" ;;
        OLDPYCA) echo "SKIP  python 'cryptography' too old to replay the capture (needs >= 46);"
                 echo "      pip install --user 'cryptography>=46'" ;;
        *)       fail "verify.py replays the recorded capture" "got: $REPLAY" ;;
    esac
    # And the replay has to be able to fail, on a file, with no board involved.
    #
    # The corruption ROTATES the digit rather than setting it to a constant.
    # The first version of this wrote 'f' over the first hex digit of SG050 —
    # which in the capture that got checked in was already 'f', so it corrupted
    # nothing, verify.py said OK, and the check that exists to prove verify.py
    # can fail had itself become a check that cannot fail. exp140, from the
    # inside. The diff is asserted below so it cannot happen again.
    CORRUPT="$(awk '{ if (match($0, /SG050 /)) {
                          p = RSTART + RLENGTH
                          n = index("0123456789abcdef", substr($0, p, 1))
                          $0 = substr($0, 1, p - 1) substr("123456789abcdef0", n, 1) substr($0, p + 1)
                      }
                      print }' capture.txt)"
    if [[ "$CORRUPT" == "$(cat capture.txt)" ]]; then
        fail "the corrupted-capture test actually corrupts something" \
             "SG050 was not altered, so the check below cannot fail"
    else
        pass "the corrupted-capture test actually corrupts something"
    fi
    BROKEN="$(printf '%s\n' "$CORRUPT" | python3 ./verify.py 2>&1 | tail -1)"
    case "$BROKEN" in
        BAD)     pass "verify.py rejects a capture with one corrupted byte" ;;
        OLDPYCA) : ;;
        *)       fail "verify.py rejects a capture with one corrupted byte" "got: $BROKEN" ;;
    esac
else
    fail "a recorded capture is checked in" "capture.txt is missing; verify.py is unreplayed"
fi

if ! exp_running 160; then
    echo "SKIP  board is not running exp160 — flash it (not an error)"
    exit "$FAILED"
fi
pass "board enumerated as 1209:0001"

# Wait for the matrix. The port disappears between boots, so exp_read_log
# returns immediately rather than taking its window — a bare retry loop spins
# through in seconds and reports failures on a healthy board. The window is
# longer than exp159's because one full report block is 173 lines.
OUT=""
for _ in $(seq 24); do
    OUT="$(exp_read_log 15 2>/dev/null)"
    grep -q 'exp160 done' <<< "$OUT" && break
    sleep 3
done

# Assert on the FINAL report block, not on the whole window: every boot opens by
# printing the matrix as it stood when that boot started, so "not reached"
# appears legitimately in the early ones.
FINAL="$(sed -n '/exp160 done/,$p' <<< "$OUT")"

grep -q 'not reached' <<< "$FINAL" \
    && fail "every candidate was attempted" "the final report still lists one as not reached" \
    || pass "every candidate was attempted"

if grep -q 'NOT as expected' <<< "$FINAL"; then
    fail "every candidate behaved as expected" "$(grep -o '[0-9] [^-]* - NOT as expected' <<< "$FINAL" | tail -1)"
else
    pass "every candidate behaved as expected"
fi

# The controls, named separately. Without them a refusal is one failed access.
grep -q '1 Secure signs with the seed in bank 8 - as expected' <<< "$FINAL" \
    && pass "control: one ML-DSA-65 signature fits on this chip at all" \
    || fail "control: one ML-DSA-65 signature fits on this chip at all" \
            "nothing below means anything without it"

grep -q '2 Non-secure reads bank 8, allowed - as expected' <<< "$FINAL" \
    && pass "control: Non-secure read bank 8 while it was OPEN" \
    || fail "control: Non-secure read bank 8 while it was OPEN" \
            "a demoted core could not read what it was allowed to, so a refusal proves nothing"

grep -q '3 Non-secure reads bank 8, DENIED - as expected' <<< "$FINAL" \
    && pass "the wall: Non-secure was refused once bank 8 was SHUT" \
    || fail "the wall: Non-secure was refused once bank 8 was SHUT" "the seed was not protected"

grep -q '4 Non-secure asks for a signature - as expected' <<< "$FINAL" \
    && pass "Non-secure got 3,309 bytes back with bank 8 still SHUT" \
    || fail "Non-secure got 3,309 bytes back with bank 8 still SHUT" "the gateway did not answer"

# The finding. This one passing is the bad news, and saying so here is the point:
# a check that reports it as a plain success has learned nothing from exp159.
if grep -q '5 Non-secure reads the copy on the stack - as expected' <<< "$FINAL"; then
    pass "THE FINDING: Non-secure read the private key out of open SRAM, wall intact"
else
    fail "candidate 5 reached a verdict" \
         "the sweep found nothing, or core 1 could not read what Secure found"
fi

# The known-answer test, done here with grep and nothing else.
#
# FIPS-204 key generation is deterministic, so the public key for the all-zero
# seed has exactly one correct value. OpenSSL and RustCrypto's ml-dsa were made
# to agree on it off the board on 2026-08-21. This check needs no python, no
# cryptography and no network — which is the point of having it as well as the
# signature check below, because the two fail in different ways.
KAT_HEAD="424b2f267e58d5b3b44d71acfc6a656bb26950d57c61db1c880bcfa1feab443f"
grep -q "KATP $KAT_HEAD" <<< "$FINAL" \
    && pass "the board's ML-DSA-65 key generation matches OpenSSL (no library needed)" \
    || fail "the board's ML-DSA-65 key generation matches OpenSSL" \
            "its public key for the all-zero seed is not the published value"

# And now the half the board cannot check about itself.
VERIFY="$(echo "$OUT" | python3 ./verify.py 2>&1 | tail -1)"

case "$VERIFY" in
    OK)         pass "the signature verifies off the board, and the check can fail" ;;
    BAD)        fail "the signature verifies off the board" "python-cryptography rejected it" ;;
    CANNOTFAIL) fail "the verification can fail" "a one-bit-corrupted challenge also verified" ;;
    KATBAD)     fail "the board's ML-DSA-65 key generation is correct" \
                     "its public key for the all-zero seed disagrees with OpenSSL" ;;
    MISSING)    fail "the board reported a complete key, challenge and signature" \
                     "173 lines have to arrive intact; the capture window may be too short" ;;
    OLDPYCA)    echo "SKIP  python 'cryptography' too old for ML-DSA (needs >= 46) — the"
                echo "      known-answer test above still ran. To check the signature too:"
                echo "      pip install --user 'cryptography>=46'" ;;
    *)          fail "off-board verification ran" "unexpected result: $VERIFY" ;;
esac

exit "$FAILED"
