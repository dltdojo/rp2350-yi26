#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp173 quick check — non-interactive.
#
# **Everything here is driven by somebody else's client.** exp168 through exp172
# used a CTAPHID client written for this repository, so every message the board
# saw was one this repository also wrote. libfido2's tools are not, and what
# they refuse is the finding.
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
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

USB_IFACE="cdc+hid"
USB_CARRIES="log+ctaphid"
USB_HOST="cdc_acm+hidraw"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp173-a-client-that-is-not-ours
UF2=target/exp173.uf2

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
UF2=target/exp173.uf2
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
# `FIDO_2_0` is a claim about having makeCredential and getAssertion, which
# exp169 did not and this does. The check is that the claim and the commands
# move together.
if grep -q 'const VERSIONS: \[&str; 1\] = \["FIDO_2_0"\]' <<< "$CODE" \
   && grep -q 'AUTHENTICATOR_MAKE_CREDENTIAL =>' <<< "$CODE" \
   && grep -q 'AUTHENTICATOR_GET_ASSERTION =>' <<< "$CODE"; then
    pass "FIDO_2_0 is claimed and both commands it names are implemented"
else
    fail "FIDO_2_0 is claimed only alongside its commands" "exp169 measured what the bare claim costs"
fi
# `up` in the options map is a capability, and a build that asks nobody does not
# have it. A device whose declaration and behaviour disagree is worse than one
# that declares nothing.
grep -q 'w.bool(WAIT_FOR_USER);' <<< "$CODE" \
    && pass "the options map's up follows the build rather than being hard-coded" \
    || fail "the options map's up follows the build" "a capability a build lacks is one it must not announce"

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

# `FIDO_2_0` is a claim about having makeCredential and getAssertion, which
# exp169 did not and this does. The check is that the claim and the commands
# move together.
if grep -q 'const VERSIONS: \[&str; 1\] = \["FIDO_2_0"\]' <<< "$CODE" \
   && grep -q 'AUTHENTICATOR_MAKE_CREDENTIAL =>' <<< "$CODE" \
   && grep -q 'AUTHENTICATOR_GET_ASSERTION =>' <<< "$CODE"; then
    pass "FIDO_2_0 is claimed and both commands it names are implemented"
else
    fail "FIDO_2_0 is claimed only alongside its commands" "exp169 measured what the bare claim costs"
fi
# `up` in the options map is a capability, and a build that asks nobody does not
# have it. A device whose declaration and behaviour disagree is worse than one
# that declares nothing.
grep -q 'w.bool(WAIT_FOR_USER);' <<< "$CODE" \
    && pass "the options map's up follows the build rather than being hard-coded" \
    || fail "the options map's up follows the build" "a capability a build lacks is one it must not announce"

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

# Two transcripts, and the pair is the finding: the same firmware, the same
# client, one bit of difference, and libfido2 changes its mind.
for CAP in capture.txt capture-button.txt; do
    if [[ ! -f "$CAP" ]]; then
        fail "$CAP is checked in" "one half of the comparison is missing"
        continue
    fi
    R="$(python3 ./verify.py < "$CAP" 2>&1 | tail -1)"
    [[ "$R" == "OK" ]] \
        && pass "verify.py replays $CAP" \
        || fail "verify.py replays $CAP" "got: $R"
done
if grep -q 'UP=False and fido2-cred -V refused' <(python3 ./verify.py < capture.txt 2>&1) \
   && grep -q 'UP=True and fido2-cred -V verified' <(python3 ./verify.py < capture-button.txt 2>&1); then
    pass "the implication holds in both directions: UP=0 refused, UP=1 verified"
else
    fail "the implication holds in both directions" "one half does not show what it should"
fi

declare -A CORRUPTIONS=(
    ["a credential with no user present that was accepted"]='capture.txt|s/REFUSED: fido2-cred: fido_cred_verify_self: FIDO_ERR_INVALID_PARAM/verified, and wrote the public key out/'
    ["a credential with a user present that was refused"]='capture-button.txt|s/verified, and wrote the public key out/REFUSED: fido2-cred: fido_cred_verify_self: FIDO_ERR_INVALID_PARAM/'
    ["options that contradict the flags produced"]='capture.txt|s/options: nork, noup/options: nork, up/'
    ["an assertion carrying attested credential data"]='capture-button.txt|s/flags=0x01 UP=True UV=False AT=False/flags=0x41 UP=True UV=False AT=True/'
    ["a flipped bit that still verified"]='capture.txt|s/a flipped bit is rejected: True/a flipped bit is rejected: False/'
)
for WHAT in "${!CORRUPTIONS[@]}"; do
    SPEC="${CORRUPTIONS[$WHAT]}"
    FILE="${SPEC%%|*}"; EDIT="${SPEC#*|}"
    MUTANT="$(sed "$EDIT" "$FILE")"
    if [[ "$MUTANT" == "$(cat "$FILE")" ]]; then
        fail "the corruption test for $WHAT changes something" "the line it edits is not in $FILE"
        continue
    fi
    BROKEN="$(printf '%s\n' "$MUTANT" | python3 ./verify.py 2>&1 | tail -1)"
    [[ "$BROKEN" != "OK" ]] \
        && pass "verify.py rejects $WHAT (got $BROKEN)" \
        || fail "verify.py rejects $WHAT" "it still said OK"
done

# The one thing this script cannot do is press a button, so it checks that
# somebody did — and here the press is not a detail, it is the variable. The
# same firmware and the same client differ by one bit, and libfido2 changes its
# mind about the credential.
if [[ -f capture-button.txt ]]; then
    if grep -q 'UP=True' capture-button.txt \
       && grep -q 'verified, and wrote the public key out' capture-button.txt; then
        pass "a press is on record: UP=1, and libfido2 verified the self attestation"
    else
        fail "a press is on record" "capture-button.txt does not show UP=1 and a verification"
    fi
    if grep -q 'FIDO_ERR_INVALID_PARAM' capture-button.txt; then
        fail "the pressed transcript is the passing one" "it still contains the refusal"
    else
        pass "the pressed transcript contains no refusal at all"
    fi
else
    fail "a press is on record" "capture-button.txt is missing; the comparison has one half"
fi

if ! yi26 state 2>/dev/null | grep -qE 'running|bootsel'; then
    echo "SKIP  no board attached (not an error)"
    exit "$FAILED"
fi
pass "a board is attached"

LIVE="$(./roundtrip.sh 2>&1)"
LIVEV="$(python3 ./verify.py <<< "$LIVE" 2>&1 | tail -1)"
case "$LIVEV" in
    OK)         pass "a live libfido2 round trip satisfies its own implication" ;;
    DISAGREE)   fail "a live libfido2 round trip holds together" \
                     "$(python3 ./verify.py <<< "$LIVE" 2>&1 | grep '^  - ' | head -1)" ;;
    INCOMPLETE) fail "a live round trip completes" "libfido2 did not get through it" ;;
    *)          fail "off-board verification ran" "unexpected result: $LIVEV" ;;
esac
grep -q 'version strings: FIDO_2_0' <<< "$LIVE" \
    && pass "libfido2 reads FIDO_2_0 off the device" \
    || fail "libfido2 reads FIDO_2_0" "the claim is what makes a client try"
grep -q 'made a credential' <<< "$LIVE" \
    && pass "libfido2 made a credential with its own CBOR, not ours" \
    || fail "libfido2 made a credential" "this is the experiment"
grep -q 'got an assertion' <<< "$LIVE" \
    && pass "libfido2 used that credential to get an assertion" \
    || fail "libfido2 got an assertion" "a credential nothing can use is not one"
grep -q 'signature verifies against the registered key: True' <<< "$LIVE" \
    && pass "the assertion verifies against the key the credential handed over" \
    || fail "the assertion verifies against the registered key" "the round trip did not close"

exit "$FAILED"
