#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp167 quick check — non-interactive.
#
# Slot A is asked four things and gets three of them wrong on purpose. What is
# asserted here is the shape that makes the answers mean something:
#
#   · slot A holds a public key and no private one
#   · every address is checked against the QMI aperture that would answer it
#     BEFORE it is dereferenced — the guard this experiment was wedged into
#     existing, and the reason a request naming slot B produces a sentence
#     rather than a board that has to be recovered with the button
#   · nothing but a verified signature starts a trial; there is no timeout
#
# What is NOT asserted is the aperture map itself. That is the thing the
# experiment was written to find out.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # the board drives every half of this itself
presence_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp167-the-image-that-never-runs
UF2=target/exp167-ab.uf2

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi
python3 -c 'import cryptography' 2>/dev/null \
    && pass "python cryptography present (the host half signs with it)" \
    || { fail "python cryptography present" "pip install cryptography"; exit 1; }

build_slot() { # slot major tbyb buy out.uf2
    EXP167_SLOT="$1" EXP167_MAJOR="$2" EXP167_MINOR=0 EXP167_TBYB="$3" EXP167_BUY="$4" \
        cargo build --release --quiet 2>/dev/null \
        && elf2flash convert -b rp2350 "$ELF" "$5" > /dev/null 2>&1
}
if build_slot A 1 0 0 target/imageA.uf2 && build_slot B 2 1 0 target/imageB-nobuy.uf2; then
    pass "both slots compile from one source ($(stat -c%s target/imageA.uf2) and $(stat -c%s target/imageB-nobuy.uf2) byte UF2s)"
else
    fail "both slots compile from one source" "run: cargo build --release"
    exit 1
fi

EXPDIR="$(pwd)"
if ( cd ../../tools/partimg && cargo run --quiet -- ab \
        "$EXPDIR/target/imageA.uf2" "$EXPDIR/target/imageB-nobuy.uf2" "$EXPDIR/$UF2" ) > /dev/null 2>&1; then
    pass "partimg assembles the A/B pair ($(stat -c%s "$UF2") bytes)"
else
    fail "partimg assembles the A/B pair" "see tools/partimg"
    exit 1
fi
FAMILY="$(od -An -tx4 -j28 -N4 "$UF2" | tr -d ' ')"
[[ "$FAMILY" == "e48bff59" ]] \
    && pass "UF2 family ID is e48bff59 (rp2350-arm-s)" \
    || fail "UF2 family ID is e48bff59 (rp2350-arm-s)" "got: $FAMILY"

CODE="$(grep -vE '^\s*(///|//!|//)' src/main.rs)"

if grep -qiE 'a7c08e6335cc688c|a03a8c8cd7659136' <<< "$CODE"; then
    fail "no private key is on the board" "a test private key appears in src/main.rs"
else
    pass "no private key is on the board"
fi
if grep -q 'const TRUSTED_KEY: \[u8; 65\] = \[' <<< "$CODE" && grep -qE '^\s+0x04, ' <<< "$CODE"; then
    pass "the trusted key is a 65-byte SEC1 public point (leading 0x04)"
else
    fail "the trusted key is a 65-byte SEC1 public point" "it is not the shape a verifier needs"
fi

# **The guard, and the reason it exists.** The datasheet says a read past an
# aperture's SIZE is a bus error; a bus error is a HardFault; a halted core
# answers no control requests, so the board stays enumerated, never logs, and
# the 1200-baud reflash touch cannot get in. The first build of this firmware
# read one sector past aperture 0 and cost a hand on the BOOTSEL button.
RAW="$(grep -n 'from_raw_parts' <<< "$CODE" | head -1 | cut -d: -f1)"
GUARD="$(grep -n 'addressable(offset, len)?' <<< "$CODE" | head -1 | cut -d: -f1)"
if [[ -n "$RAW" && -n "$GUARD" && "$GUARD" -lt "$RAW" ]]; then
    pass "every address is checked against its aperture before it is dereferenced"
else
    fail "every address is checked against its aperture first" \
         "a read past an aperture is a bus error, not a wrong answer"
fi
[[ "$(grep -c 'from_raw_parts' <<< "$CODE")" == 1 ]] \
    && pass "there is exactly one raw slice in the firmware" \
    || fail "there is exactly one raw slice in the firmware" "found more than one"
grep -q 'QMI.atrans(first as usize).read().size()' <<< "$CODE" \
    && pass "the guard reads the aperture rather than trusting a constant" \
    || fail "the guard reads the aperture" "a hard-coded limit is a limit that drifts from the chip"

# **The absence that is the experiment.** exp143 handed the board over on a
# fifteen-second clock. Nothing here does: `GO` is set only by a signature that
# verified, and it is the only thing the trial waits on.
if grep -q 'TRY_AFTER' <<< "$CODE"; then
    fail "no timeout starts a trial" "a clock that hands the board over is exp143, not this"
else
    pass "no timeout starts a trial: only a verified signature does"
fi
GOSET="$(grep -c 'GO.store(true' <<< "$CODE")"
[[ "$GOSET" == 1 ]] \
    && pass "there is exactly one place that starts a trial" \
    || fail "there is exactly one place that starts a trial" "found $GOSET"
grep -q 'rom_data::reboot(' <<< "$CODE" && grep -q 'REBOOT_FLASH_UPDATE' <<< "$CODE" \
    && pass "the trial is the ROM's own flash update boot (§5.5.8.5)" \
    || fail "the trial is the ROM's flash update boot" "the call is gone"
grep -q 'rom_data::explicit_buy' <<< "$CODE" \
    && pass "the buy is the ROM's own explicit_buy (§5.5.12.3)" \
    || fail "the buy is the ROM's explicit_buy" "the call is gone"

grep -q 'cobs::Deframer::joined()' <<< "$CODE" && ! grep -q 'Deframer::fresh()' <<< "$CODE" \
    && pass "the COBS decoder is joined, not fresh: the board is always a late joiner" \
    || fail "the COBS decoder is joined, not fresh" "a fragment could become a 73-byte frame"
grep -q 'if len == 0 {' <<< "$CODE" \
    && pass "zero-length frames are skipped, not counted (exp118's rule, one layer up)" \
    || fail "zero-length frames are skipped" "every request would be counted twice"

if grep -qE '\b(flash|otp)\s*\.\s*(write|program|erase)|write_ecc|flash_range' <<< "$CODE"; then
    fail "slot A writes no flash" "$(grep -oE '\w+\.(write|program|erase)\w*' <<< "$CODE" | head -1)"
else
    pass "slot A writes no flash: the only flash write here is the ROM's explicit_buy"
fi

grep -q 'assert!(' src/main.rs && grep -q 'PRODUCT' src/main.rs \
    || pass "the product string is short enough for the control buffer (both slots)"

if [[ -f capture.txt ]]; then
    REPLAY="$(python3 ./verify.py < capture.txt 2>&1 | tail -1)"
    [[ "$REPLAY" == "OK" ]] \
        && pass "verify.py replays the recorded transcript" \
        || fail "verify.py replays the recorded transcript" "got: $REPLAY"

    declare -A CORRUPTIONS=(
        ["a board digest that is not the host's"]='0,/sha256 = /s//sha256 = ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\n[0 ms] x /'
        ["a probe that read what its aperture forbids"]='s/  slot B, where it lives     0x0011000 REFUSED: .*/  slot B, where it lives     0x0011000 READ  deadbeefdeadbeefdeadbeef/'
        ["a second request that started a trial"]='0,/  REFUSED (cryptography): the signature is not this key/s//  starting the trial./'
        ["a board that never came back to slot A"]='/board is back on/d'
    )
    for WHAT in "${!CORRUPTIONS[@]}"; do
        MUTANT="$(sed "${CORRUPTIONS[$WHAT]}" capture.txt)"
        if [[ "$MUTANT" == "$(cat capture.txt)" ]]; then
            fail "the corruption test for $WHAT changes something" "the line it edits is not in capture.txt"
            continue
        fi
        BROKEN="$(printf '%s\n' "$MUTANT" | python3 ./verify.py 2>&1 | tail -1)"
        [[ "$BROKEN" != "OK" ]] \
            && pass "verify.py rejects $WHAT (got $BROKEN)" \
            || fail "verify.py rejects $WHAT" "it still said OK"
    done
else
    fail "a recorded transcript is checked in" "capture.txt is missing; verify.py is unreplayed"
fi

if ! yi26 state 2>/dev/null | grep -qE 'running|bootsel'; then
    echo "SKIP  no board attached (not an error)"
    exit "$FAILED"
fi
pass "a board is attached"

# The live half drives a whole round: flash the pair, refuse three requests,
# accept the fourth, watch slot B run on trial and be taken back.
LIVE="$(./drive.sh "$(date +%s)" 2>&1)"
LIVEV="$(python3 ./verify.py <<< "$LIVE" 2>&1 | tail -1)"
case "$LIVEV" in
    OK)         pass "a live round re-derives off the board, digests and apertures included" ;;
    DISAGREE)   fail "a live round re-derives off the board" \
                     "$(python3 ./verify.py <<< "$LIVE" 2>&1 | grep '^  - ' | head -1)" ;;
    INCOMPLETE) fail "a live round completes" "slot A never reached the point of waiting" ;;
    *)          fail "off-board verification ran" "unexpected result: $LIVEV" ;;
esac

grep -q 'REFUSED (plumbing): the region leaves the window' <<< "$LIVE" \
    && pass "slot B's real address is refused in words, by a board still talking" \
    || fail "slot B's real address is refused in words" "the guard did not fire"
grep -q 'ACCEPTED: slot B is signed by the key this image trusts' <<< "$LIVE" \
    && pass "a correctly signed request starts the trial" \
    || fail "a correctly signed request starts the trial" "nothing was accepted"
grep -q 'exp167 up. slot B' <<< "$LIVE" \
    && pass "slot B ran, and only after a signature" \
    || fail "slot B ran" "the accepted request proved nothing"
grep -q 'board is back on: exp167 slot A' <<< "$LIVE" \
    && pass "slot B never bought, and the ROM took the board back" \
    || fail "the ROM took the board back" "the board did not return to slot A"

exit "$FAILED"
