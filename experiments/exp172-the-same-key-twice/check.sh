#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp172 quick check — non-interactive.
#
# **The absence exp168 through exp170 asserted is gone**: this firmware has
# cryptography. So the checks invert — what is asserted now is that the only
# primitives are the two named, that **no private key is stored anywhere**, and
# that the attestation is self attestation with everything the specification
# pairs with that.
#
# The credential itself is checked by the host's own elliptic-curve library, in
# verify.py, and a bit is flipped and the check required to fail before the pass
# is reported. exp159's rule.
#
# What is NOT asserted is which version claim is right. Both are built, both
# are driven, and the transcript is the finding.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

# Everything below runs unattended, and that is not the same as the claim being
# checkable unattended: the `EXP171_UP=button` build's press is a person, once,
# and this script can only check that somebody did it. exp127 is the same shape
# — seventeen checks pass and none of them can see whether the LED lit.
PRESENCE=2
presence_check

USB_IFACE="cdc+hid"
USB_CARRIES="log+ctaphid"
USB_HOST="cdc_acm+hidraw"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp172-the-same-key-twice
UF2=target/exp172.uf2

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi
command -v fido2-token > /dev/null \
    && pass "fido2-token present (the host's own FIDO tooling, nothing installed for this)" \
    || fail "fido2-token present" "install libfido2-tools"

# The CBOR writer is a crate with tests, which is where the bytes are checked.
# `crates/fat12`'s shape: the encoding runs on any machine, and the board only
# has to carry the claim.
if ( cd ../../crates/cbor && cargo test --quiet ) > /dev/null 2>&1; then
    pass "crates/cbor's tests pass, including RFC 8949's own examples"
else
    fail "crates/cbor's tests pass" "run: cd crates/cbor && cargo test"
fi
grep -q 'KeyOutOfOrder' ../../crates/cbor/src/lib.rs \
    && pass "the writer refuses a map key out of order rather than emitting it" \
    || fail "the writer refuses a map key out of order" "non-canonical CBOR is valid CBOR a host rejects"

# **The check this experiment is named for.** Every length in a request came
# from whoever sent it, and one function is where they are all checked. A
# reader with a second, unchecked path is a reader with a hole.
if grep -q 'checked_add(n).ok_or(ReadError::Truncated)' ../../crates/cbor/src/lib.rs; then
    pass "the reader bounds-checks every length against its own buffer, with checked_add"
else
    fail "the reader bounds-checks every length" "a length from the wire is an attacker's number"
fi
# Only the Reader's half. The Writer indexes a buffer the caller owns and sized;
# the Reader indexes one against lengths from the wire, and that is the half
# where a second unchecked path would be a hole.
READER_SLICES="$(sed -n '/^impl<.a> Reader<.a> {/,/^}/p' ../../crates/cbor/src/lib.rs | grep -cE 'self\.buf\[')"
[[ "$READER_SLICES" == 1 ]] \
    && pass "the reader indexes its buffer in exactly one place, inside take()" \
    || fail "the reader indexes its buffer in one place" "found $READER_SLICES; each is a bound to get right"
grep -q 'fn skip_at(&mut self, depth: usize)' ../../crates/cbor/src/lib.rs \
    && grep -q 'if depth > MAX_DEPTH' ../../crates/cbor/src/lib.rs \
    && pass "nesting is depth-limited: a deep message is refused, not a stack overflow" \
    || fail "nesting is depth-limited" "recursion without a bound is a message somebody builds"

if cargo build --release --quiet 2>/dev/null && [[ -f "$ELF" ]]; then
    pass "firmware compiles ($(stat -c%s "$ELF") byte ELF)"
else
    fail "firmware compiles" "run: cargo build --release"
    exit 1
fi
UF2=target/exp172.uf2
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

# **The claim this experiment is named for.** A reader who takes this for a
# security key has been misled by it, so the absence is checked rather than
# promised: no curve, no hash, no key material, and no dependency that could
# supply one.
DEPS="$(grep -cE '^(p256|sha2|hmac) = ' Cargo.toml)"
[[ "$DEPS" == 3 ]] \
    && pass "exactly three cryptographic dependencies: p256, sha2, hmac" \
    || fail "exactly three cryptographic dependencies" "found $DEPS; every one is a thing to justify"
# Log lines are excluded as well as comments. The first version of this check
# failed on the word "secret" inside the firmware's own line saying it has none,
# which is a grep that cannot tell a claim from its denial.
# **No private key is stored.** Every credential's key is derived when it is
# needed and gone afterwards, so there is nothing in `.data`, `.bss` or flash to
# find. A `static` holding key material would defeat the whole design.
if grep -qE '^\s*static\s+[A-Z_]*(KEY|SECRET|PRIV)' <<< "$CODE"; then
    fail "no private key is stored in a static" "$(grep -oE '^\s*static\s+\w+' <<< "$CODE" | head -1)"
else
    pass "no private key is stored in a static: every key is derived and dropped"
fi
grep -q 'fn derive_key' <<< "$CODE" \
    && pass "the credential key is derived from the device secret and the relying party" \
    || fail "the credential key is derived" "a stored key is a key exp163 measured the exposure of"

# **The tag comparison must not return early.** How long a byte-by-byte compare
# takes is a measurement of how many bytes were right, and that turns forging
# sixteen bytes from 2^128 guesses into 16 x 256.
# **The tag comparison must not return early.** How long a byte-by-byte compare
# takes is a measurement of how many bytes were right, and that turns forging
# sixteen bytes from 2^128 guesses into 16 x 256.
#
# Read with sed rather than a regex over the whole file: the length check before
# the loop *is* an early return and a legitimate one, so what matters is the
# loop, and "the lines from `for i in` to the end of the function" says that
# without an escape sequence to get wrong.
LOOP="$(sed -n '/^fn tags_equal/,/^}/p' src/main.rs | sed -n '/for i in/,$p')"
if grep -q 'return' <<< "$LOOP"; then
    fail "the tag comparison has no early return" "how long it takes is how many bytes were right"
elif grep -q '|=' <<< "$LOOP"; then
    pass "the tag comparison has no early return: it accumulates and compares once"
else
    fail "the tag comparison accumulates" "no |= in the loop, so it is not doing what it claims"
fi

grep -q 'fn credential_is_ours(cred_id: &\[u8\], rp_id_hash: &\[u8; 32\])' <<< "$CODE" \
    && pass "a credential is checked against the relying party it was made for" \
    || fail "a credential is checked against its relying party" "otherwise one site's credential signs for another"

# An assertion carries no attested credential data, so the AT flag must not be
# set and the structure is 37 bytes rather than 180. A device that copied its
# own registration path would attach a public key nobody asked for.
if grep -q 'auth\[32\] = if user_present { FLAG_UP } else { 0 };' <<< "$CODE"; then
    pass "the assertion sets only UP: no attested credential data in it"
else
    fail "the assertion sets only UP" "AT belongs to registration"
fi
grep -q 'let mut auth = \[0u8; 37\];' <<< "$CODE" \
    && pass "the assertion's authenticator data is 37 bytes by construction" \
    || fail "the assertion's authenticator data is 37 bytes" "a longer one is a different message"

# The refusal has to come before any key is derived. A device that derived first
# and checked afterwards sends the same status and has done the work anyway.
CHECK_AT="$(grep -n 'let Some(cred_id) = chosen else' <<< "$CODE" | head -1 | cut -d: -f1)"
DERIVE_AT="$(grep -n 'build_assertion(' <<< "$CODE" | tail -1 | cut -d: -f1)"
if [[ -n "$CHECK_AT" && -n "$DERIVE_AT" && "$CHECK_AT" -lt "$DERIVE_AT" ]]; then
    pass "a credential that is not ours is refused before anything is derived"
else
    fail "a forged credential is refused before derivation" "deriving first does the attacker's work"
fi
# The device secret is a test key and the firmware says so where a byte search
# will find it: the constant spells its own warning.
if python3 -c "
import re,sys
src=open('src/main.rs').read()
m=re.search(r'const DEVICE_SECRET: \[u8; 32\] = \[(.*?)\n\];', src, re.S)
b=bytes(int(x,16) for x in re.findall(r'0x([0-9a-fA-F]{2})', m.group(1)))
sys.exit(0 if b == b'not a secret. this is a test key' else 1)
" 2>/dev/null; then
    pass "the device secret spells 'not a secret. this is a test key' in its own bytes"
else
    fail "the device secret says what it is" "a byte search should find a warning, not a random-looking key"
fi

# Self attestation and its obligations, which come as a set.
grep -q 'const AAGUID: \[u8; 16\] = \[0; 16\]' <<< "$CODE" \
    && pass "the AAGUID is zero, which self attestation requires" \
    || fail "the AAGUID is zero" "a non-zero AAGUID with self attestation claims an unprovable model"
if grep -q 'x5c' <<< "$CODE"; then
    fail "the attestation carries no certificate" "self attestation has none to carry"
else
    pass "the attestation carries no certificate: it is self attestation throughout"
fi
if grep -qE 'FLAG_UV\s*\|' <<< "$CODE" || grep -q 'FLAG_UV;' <<< "$CODE"; then
    fail "the UV flag is never set" "this device cannot verify anybody"
else
    pass "the UV flag is defined and never set: a flag it cannot earn"
fi
grep -q 'if let Ok(sk) = SigningKey::from_bytes' <<< "$CODE" \
    && pass "the scalar is found by rejection, not by reducing a hash modulo n" \
    || fail "the scalar is found by rejection" "reduction is biased, and bias is how ECDSA keys are lost"

# The 34 bytes are the only reason a host's FIDO tooling looks at this device.
# Comments are stripped first. The first version counted 36 because two of the
# explanations beside the bytes mention 0xFF and 0xF1D0, and a check that counts
# its own documentation drifts the moment somebody edits a comment.
DESC_LEN="$(python3 - <<'PY'
import re
src = open("src/main.rs").read()
m = re.search(r"const FIDO_REPORT_DESCRIPTOR: &\[u8\] = &\[(.*?)\n\];", src, re.S)
print(len(re.findall(r"0x[0-9A-Fa-f]{2}\s*,", re.sub(r"//.*$", "", m.group(1), flags=re.M))) if m else 0)
PY
)"
[[ "$DESC_LEN" == 34 ]] \
    && pass "the report descriptor is 34 bytes, written out by hand" \
    || fail "the report descriptor is 34 bytes" "counted $DESC_LEN"
grep -q '0x06, 0xD0, 0xF1' <<< "$CODE" \
    && pass "it begins with usage page 0xF1D0, which is what makes it a FIDO device" \
    || fail "it begins with usage page 0xF1D0" "no host tool will look at it"
if grep -qE 'usbd_hid|SerializedDescriptor|::desc\(\)' <<< "$CODE"; then
    fail "the descriptor is hand-written, not generated" "exp121 generated one; this is the exercise it promised"
else
    pass "the descriptor is hand-written, not generated (exp121's promised exercise)"
fi

# The 57 and 59 are the protocol's, and they are derived from the packet size
# rather than typed — a constant that drifts from its header is the bug this
# whole experiment is about.
grep -q 'const INIT_PAYLOAD: usize = PACKET - INIT_HEADER' <<< "$CODE" \
    && grep -q 'const CONT_PAYLOAD: usize = PACKET - CONT_HEADER' <<< "$CODE" \
    && pass "57 and 59 are derived from the header sizes, not typed" \
    || fail "57 and 59 are derived from the header sizes" "a typed constant drifts from its header"

grep -q 'Action::Ignore' <<< "$CODE" \
    && pass "a spurious continuation packet is ignored, which the specification asks for" \
    || fail "a spurious continuation packet is ignored" "answering one invents a conversation"
grep -q 'ERR_MSG_TIMEOUT' <<< "$CODE" && grep -q 'TRANSACTION_TIMEOUT' <<< "$CODE" \
    && pass "an unfinished transaction expires instead of holding the channel" \
    || fail "an unfinished transaction expires" "one truncated message takes the device out of service"

# getInfo's keys have to ascend, and they are written out in that order rather
# than sorted at run time — so the source itself is readable as canonical.
KEYS="$(grep -oE 'w\.key\(0x[0-9a-f]+\)' <<< "$CODE" | grep -oE '0x[0-9a-f]+' | tr '\n' ' ')"
SORTED="$(tr ' ' '\n' <<< "$KEYS" | grep . | sort -u | tr '\n' ' ')"
[[ "$KEYS" == "$SORTED" ]] \
    && pass "getInfo's map keys are written in ascending order ($KEYS)" \
    || fail "getInfo's map keys ascend" "got '$KEYS', canonical order is '$SORTED'"

grep -q 'const AAGUID: \[u8; 16\] = \[0; 16\]' <<< "$CODE" \
    && pass "the AAGUID is sixteen zero bytes: no attestation identity is claimed" \
    || fail "the AAGUID is sixteen zero bytes" "inventing one claims to be a product that exists"

# Three statuses, three different things. exp169 had one.
for PAIR in "CTAP2_ERR_INVALID_CBOR:the bytes were wrong" \
            "CTAP2_ERR_MISSING_PARAMETER:a required field was absent" \
            "CTAP2_ERR_OPERATION_DENIED:it was understood and refused anyway"; do
    NAME="${PAIR%%:*}"
    grep -q "$NAME" <<< "$CODE" \
        && pass "$NAME is sent when ${PAIR#*:}" \
        || fail "$NAME is defined and sent" "one status for three answers tells a host nothing"
done

# The parser borrows out of the message buffer. A parser that copies every
# field an attacker sends is a parser an attacker sizes.
if grep -qE "struct MakeCredential<'a>" <<< "$CODE" && grep -q "client_data_hash: &'a \[u8\]" <<< "$CODE"; then
    pass "the parser borrows from the message rather than copying out of it"
else
    fail "the parser borrows from the message" "copying attacker-sized fields is an attacker-sized buffer"
fi
grep -q 'algs_truncated' <<< "$CODE" \
    && pass "an algorithm list longer than the device records is recorded as truncated" \
    || fail "a truncated algorithm list is recorded" "silently dropping a caller's choice makes the refusal about the wrong thing"
grep -q 'if !r.is_empty()' <<< "$CODE" \
    && pass "trailing bytes after a complete request are refused, not ignored" \
    || fail "trailing bytes are refused" "two implementations disagree about that message"

grep -q 'const CAPABILITIES: u8 = 0x04 | 0x08' <<< "$CODE" \
    && pass "the capability byte announces CBOR and still denies MSG" \
    || fail "the capability byte announces CBOR and denies MSG" "a host acts on this byte"

if [[ -f capture.txt ]]; then
    REPLAY="$(python3 ./verify.py < capture.txt 2>&1 | tail -1)"
    [[ "$REPLAY" == "OK" ]] \
        && pass "verify.py replays the recorded transcript" \
        || fail "verify.py replays the recorded transcript" "got: $REPLAY"

    declare -A CORRUPTIONS=(
        ["a packet count the arithmetic contradicts"]='s/"len": 58, "packets": 2/"len": 58, "packets": 3/'
        ["an error code swapped for another"]='s/ERR_INVALID_SEQ/ERR_INVALID_LEN/'
        ["a stray continuation packet that was answered"]='s/"reply": null, "silence_expected"/"reply": {"cid":"0","cmd":63,"len":1,"packets":1,"error_code":1,"error_name":"ERR_INVALID_CMD"}, "silence_expected"/'
        ["a report descriptor with the wrong usage page"]='s/06d0f10901a1010920150026ff00750895/07d0f10901a1010920150026ff00750895/'
        ["a device claiming a capability it lacks"]='s/(nowink, cbor, nomsg)/(nowink, cbor, msg)/'
        ["a getInfo response with a non-canonical integer"]='s/"cbor": "a3018003500000000000000000000000000000000005190400"/"cbor": "a30180035000000000000000000000000000000000051a00000400"/'
        ["a refusal that carried a response body"]='s/"status_name": "CTAP1_ERR_INVALID_COMMAND", "cbor": ""/"status_name": "CTAP1_ERR_INVALID_COMMAND", "cbor": "a0"/'
        ["a hostile length that was not refused"]='/case mc-lying-length/,+1 s/CTAP2_ERR_INVALID_CBOR/CTAP2_OK/'
        ["a run in which nothing was ever parsed"]='/rp.id/d'
        ["a tampered signature that still verified"]='s/"tamper_rejected": true/"tamper_rejected": false/'
        ["an attestation signature that does not verify"]='s/"signature_valid": true/"signature_valid": false/'
        ["a device claiming it verified a user"]='s/"user_verified": false/"user_verified": true/'
        ["self attestation with a non-zero AAGUID"]='s/"aaguid_all_zero": true/"aaguid_all_zero": false/'
        ["an assertion that does not verify against the registered key"]='/case ga-roundtrip/,+1 s/"signature_valid": true/"signature_valid": false/'
        ["an assertion carrying attested credential data"]='/case ga-roundtrip/,+1 s/"attested_data": false/"attested_data": true/'
        ["a forged credential that was accepted"]='/case ga-forged/,+1 s/CTAP2_ERR_NO_CREDENTIALS/CTAP2_OK/'
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

# The one thing this script cannot do is press a button, so it checks that
# somebody did. `capture-button.txt` is the `EXP171_UP=button` build with a
# finger on BOOTSEL, and it is the only evidence that the branch where a press
# is *seen* has ever run.
if [[ -f capture-button.txt ]]; then
    if grep -q '"user_present": true' capture-button.txt \
       && grep -q '"signature_valid": true' capture-button.txt \
       && grep -qE 'pressed after [0-9]+ ms' capture-button.txt; then
        pass "a press is on record: UP=1 with a signature that verifies"
    else
        fail "a press is on record" "capture-button.txt does not show UP=1 and a valid signature"
    fi
    grep -q '"user_present": false' capture-button.txt \
        && fail "the recorded press really was a press" "UP is 0 in the button transcript" \
        || pass "the recorded press really was a press"
else
    fail "a press is on record" "capture-button.txt is missing; the button branch is unexercised"
fi

if ! yi26 state 2>/dev/null | grep -qE 'running|bootsel'; then
    echo "SKIP  no board attached (not an error)"
    exit "$FAILED"
fi
pass "a board is attached"

LIVE="$(./drive.sh 2>&1)"
LIVEV="$(python3 ./verify.py <<< "$LIVE" 2>&1 | tail -1)"
case "$LIVEV" in
    OK)         pass "a live round satisfies the protocol's own arithmetic" ;;
    DISAGREE)   fail "a live round satisfies the protocol" \
                     "$(python3 ./verify.py <<< "$LIVE" 2>&1 | grep '^  - ' | head -1)" ;;
    INCOMPLETE) fail "a live round runs every case" "some case produced nothing" ;;
    *)          fail "off-board verification ran" "unexpected result: $LIVEV" ;;
esac

grep -q 'vendor=0x1209' <<< "$LIVE" \
    && pass "the host's FIDO tooling lists it without root and without a rule of ours" \
    || fail "the host's FIDO tooling lists it" "the descriptor is what earns that access"
grep -q 'caps: 0x0c' <<< "$LIVE" \
    && pass "fido2-token -I reads the capability byte and sees CBOR" \
    || fail "fido2-token -I sees CBOR" "one bit is the whole difference from exp168"
grep -q 'maxmsgsiz: 1024' <<< "$LIVE" \
    && pass "the declared maximum message size is the one the transport enforces" \
    || fail "the declared maximum is the enforced one" "a device whose limits differ has arbitrary refusals"
grep -q 'rp.id      = "example.test"' <<< "$LIVE" \
    && pass "a request was read and its fields reported, not merely refused" \
    || fail "a request was read and reported" "the statuses alone could be reflexes"
grep -q 'nothing was read past the buffer' <<< "$LIVE" \
    && pass "a length that runs past the message is refused by a board still talking" \
    || fail "a hostile length is refused in words" "this is the case the reader exists for"
grep -q 'credential made:' <<< "$LIVE" \
    && pass "a credential was made, and its cost is in the transcript" \
    || fail "a credential was made" "this is the experiment"
grep -q 'the private key is not stored' <<< "$LIVE" \
    && pass "the board says the key was derived rather than kept" \
    || fail "the board says the key was derived" "a stored key is a different experiment"
grep -q '"user_present": false' <<< "$LIVE" \
    && pass "the UP bit is 0 in the build that asks nobody: no client will take this" \
    || fail "the UP bit is 0 when nobody was asked" "setting it without asking is the one lie this road must not tell"
grep -q 'the same key as at registration' <<< "$LIVE" \
    && pass "an assertion was made with a key the board had already thrown away" \
    || fail "an assertion was made" "this is the experiment"
grep -q 'no key is derived at all' <<< "$LIVE" \
    && pass "a forged credential drew a refusal and no derivation at all" \
    || fail "a forged credential drew no derivation" "deriving before checking does the attacker's work"
grep -q 'not ours' <<< "$LIVE" \
    && pass "the board says which offered credentials were not its own" \
    || fail "the board names what it rejected" "a silent walk past a decoy is unreadable"

exit "$FAILED"
