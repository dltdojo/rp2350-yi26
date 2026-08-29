#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp166 quick check — non-interactive.
#
# The board is asked six questions, and the answers are compared against what
# the host that built them expected. Nothing about the board's cryptography is
# taken on the board's word: for every request the host computes SHA-256 over
# the same bytes and verify.py requires the two to be equal, because a verifier
# that only reports pass/fail can be trusted and cannot be checked.
#
# It also demonstrates the ceiling rather than describing it: the trusted public
# key is located inside the built .uf2 by byte search, and the offset is
# printed. See exp140 for why a check somebody can rewrite is worth stating in
# those terms.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # flash it and drive it from a shell; nothing needs a hand
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp166-whose-firmware-will-it-accept
UF2=target/exp166.uf2

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

if python3 -c 'import cryptography' 2>/dev/null; then
    pass "python cryptography present (the host half signs with it)"
else
    fail "python cryptography present" "pip install cryptography"
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

# **A verifier has no business holding a private key.** The two test keys in
# sign.py are published on purpose; neither may appear in anything that runs on
# the board, and the constant the firmware does carry has to be a public point.
if grep -qiE 'a7c08e6335cc688c|a03a8c8cd7659136' <<< "$CODE"; then
    fail "no private key is on the board" "a test private key appears in src/main.rs"
else
    pass "no private key is on the board"
fi

KEYLEN="$(grep -oE 'TRUSTED_KEY: \[u8; [0-9]+\]' <<< "$CODE" | grep -oE '[0-9]+' | tail -1)"
if [[ "$KEYLEN" == 65 ]] && grep -q 'const TRUSTED_KEY: \[u8; 65\] = \[' <<< "$CODE" \
   && grep -qE '^\s+0x04, ' <<< "$CODE"; then
    pass "the trusted key is a 65-byte SEC1 public point (leading 0x04)"
else
    fail "the trusted key is a 65-byte SEC1 public point" "got length '$KEYLEN'"
fi

# This experiment reads flash and never writes it. ACCEPT is a verdict, not an
# installation — joining the verdict to the ROM's explicit_buy is the next
# experiment, and a firmware that could write flash while proving it refuses
# one is a worse witness.
if grep -qE '\b(flash|otp)\s*\.\s*(write|program|erase)|write_ecc|rom_data|flash_range' <<< "$CODE"; then
    fail "the firmware never writes flash or OTP" "$(grep -oE '\w+\.(write|program|erase)\w*' <<< "$CODE" | head -1)"
else
    pass "the firmware never writes flash or OTP (ACCEPT is a verdict, not an install)"
fi

# The only raw pointer read in the file is the region, and its bounds are
# checked before the slice exists. A silently clamped region would be a
# signature checked over bytes nobody named.
RAW="$(grep -n 'from_raw_parts' <<< "$CODE" | head -1 | cut -d: -f1)"
BOUND="$(grep -n 'if end > MAX_END' <<< "$CODE" | head -1 | cut -d: -f1)"
if [[ -n "$RAW" && -n "$BOUND" && "$BOUND" -lt "$RAW" ]]; then
    pass "the region is bounds-checked before the slice exists"
else
    fail "the region is bounds-checked before the slice exists" "no MAX_END test above from_raw_parts"
fi
[[ "$(grep -c 'from_raw_parts' <<< "$CODE")" == 1 ]] \
    && pass "there is exactly one raw slice in the firmware" \
    || fail "there is exactly one raw slice in the firmware" "found more than one"

# exp136's finding, applied: this board can never know it is reading a host's
# stream from the first byte, so the decoder must refuse to emit what it
# assembled before the first delimiter.
if grep -q 'cobs::Deframer::joined()' <<< "$CODE" && ! grep -q 'Deframer::fresh()' <<< "$CODE"; then
    pass "the COBS decoder is joined, not fresh: the board is always a late joiner"
else
    fail "the COBS decoder is joined, not fresh" "a fragment could become a 73-byte frame"
fi

grep -q 'if len == 0 {' <<< "$CODE" \
    && pass "zero-length frames are skipped, not counted (exp118's rule, one layer up)" \
    || fail "zero-length frames are skipped" "every request would be counted twice"

# The digest is what makes the verdict checkable, so it has to be printed even
# when the answer is no.
SHA_AT="$(grep -n 'sha256 = ' <<< "$CODE" | head -1 | cut -d: -f1)"
OUT_AT="$(grep -n 'match v.outcome' <<< "$CODE" | head -1 | cut -d: -f1)"
if [[ -n "$SHA_AT" && -n "$OUT_AT" && "$SHA_AT" -lt "$OUT_AT" ]]; then
    pass "the digest is printed before the verdict, so a refusal still carries it"
else
    fail "the digest is printed before the verdict" "a refusal a host cannot cross-check is a refusal on trust"
fi

# **The ceiling, demonstrated.** exp140's shape: show it, do not say it.
FOUND="$(python3 - "$UF2" <<'PY'
import sys
sys.path.insert(0, ".")
from sign import uf2_image
KEY = bytes.fromhex(
    "0461788817a141903fb9ac46ab03fbde47181262ad410b690988a0b9d167cecd"
    "eeed2d1f96defb9c8443fe1d569ef559a6c4bacb8c359a10579b120a63f09aad"
    "b0"
)
_, image = uf2_image(sys.argv[1])
i = image.find(KEY)
print(f"at flash offset {i:#x} of {len(image)}" if i >= 0 else "NOT-FOUND")
PY
)"
if [[ "$FOUND" == NOT-FOUND ]]; then
    fail "the trusted key is findable in the .uf2" \
         "if it cannot be found the ceiling cannot be demonstrated, only asserted"
else
    pass "the trusted key is 65 plain bytes in the .uf2, $FOUND — anybody with the file can change it"
fi

if [[ -f capture.txt ]]; then
    REPLAY="$(python3 ./verify.py < capture.txt 2>&1 | tail -1)"
    [[ "$REPLAY" == "OK" ]] \
        && pass "verify.py replays the recorded transcript" \
        || fail "verify.py replays the recorded transcript" "got: $REPLAY"

    declare -A CORRUPTIONS=(
        ["a board digest that is not the host's"]='0,/sha256 = 0db2/s//sha256 = 1db2/'
        ["a verdict the host did not expect"]='0,/ACCEPTED: signed/s//REFUSED (cryptography): forged/'
        ["a truncated frame refused by the wrong layer"]='s/REFUSED (plumbing): the frame is/REFUSED (cryptography): the frame is/'
        ["a request counter that skips"]='0,/totals: 2 asked/s//totals: 4 asked/'
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

if ! exp_running 166; then
    echo "SKIP  board is not running exp166 — flash it (not an error)"
    exit "$FAILED"
fi
pass "board enumerated as 1209:0001"

# The live half. The seed is the clock, so the region signed below is one
# neither this firmware nor this script has ever used, which is exp159's bar
# for a signer pointed the other way at a verifier.
SEED="$(date +%s)"
LIVE=""
for MODE in good flip-sig wrong-key wrong-region truncated good; do
    J="$(python3 sign.py "$UF2" "$MODE" "$SEED" 2>/dev/null)"
    if [[ -z "$J" ]]; then
        fail "sign.py builds a '$MODE' request" "it produced nothing"
        continue
    fi
    ESC="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["escaped"])' <<< "$J")"
    HOSTLINE="$(python3 -c '
import json, sys
d = json.load(sys.stdin)
print(">>> host: mode=%s expect=%s named=%#x+%d sha256=%s"
      % (d["mode"], d["expect"], d["named_offset"], d["named_len"], d["named_sha256"]))' <<< "$J")"

    # **One retry, and it is announced.** Opening and closing the CDC port six
    # times in a row occasionally loses a frame in transport — measured at
    # roughly one request in twenty-four, and the board's own counter says which
    # it was, because a frame it never received is one it never counted. A lost
    # frame is not a verification result and must not be graded as one; a silent
    # retry would be worse still, because a check that hides a flake reports a
    # link as steadier than it is. So it retries once and says so out loud.
    REPLY="$(yi26 send "$ESC" 2>&1 | grep -vE 'listening:')"
    if ! grep -q -- '--- request #' <<< "$REPLY"; then
        echo "NOTE  '$MODE' drew no reply — the frame was lost in transport, retrying once"
        REPLY="$(yi26 send "$ESC" 2>&1 | grep -vE 'listening:')"
    fi
    LIVE+="$HOSTLINE"$'\n'
    LIVE+="$REPLY"$'\n'
done

EXCHANGES="$(grep -c -- '--- request #' <<< "$LIVE")"
[[ "$EXCHANGES" == 6 ]] \
    && pass "the board answered all six requests" \
    || fail "the board answered all six requests" "counted $EXCHANGES"

grep -q 'ACCEPTED: signed by the key this board trusts' <<< "$LIVE" \
    && pass "a correctly signed request is accepted" \
    || fail "a correctly signed request is accepted" "nothing was accepted at all"

grep -q "REFUSED (cryptography): the signature is not this key's" <<< "$LIVE" \
    && pass "a bad signature is refused by the cryptography" \
    || fail "a bad signature is refused by the cryptography" "no cryptographic refusal in the run"

grep -qE 'REFUSED \(plumbing\): the frame is [0-9]+ bytes, not 73' <<< "$LIVE" \
    && pass "a truncated frame is refused by the plumbing, and the board keeps going" \
    || fail "a truncated frame is refused by the plumbing" "no plumbing refusal in the run"

# The one an implementation that checks "is this a signature by the key" rather
# than "is this a signature over these bytes" gets wrong, and nothing else here
# would catch it.
WR="$(sed -n '/mode=wrong-region/,/totals:/p' <<< "$LIVE")"
grep -q 'REFUSED' <<< "$WR" \
    && pass "a valid signature over a different region is refused" \
    || fail "a valid signature over a different region is refused" \
            "the signature is not bound to the bytes the frame names"

LIVEV="$(python3 ./verify.py <<< "$LIVE" 2>&1 | tail -1)"
case "$LIVEV" in
    OK)         pass "every live verdict re-derives off the board, digests included" ;;
    DISAGREE)   fail "every live verdict re-derives off the board" \
                     "$(python3 ./verify.py <<< "$LIVE" 2>&1 | grep '^  - ' | head -1)" ;;
    INCOMPLETE) fail "the live run is complete" "not enough exchanges reached the log" ;;
    *)          fail "off-board verification ran" "unexpected result: $LIVEV" ;;
esac

exit "$FAILED"
