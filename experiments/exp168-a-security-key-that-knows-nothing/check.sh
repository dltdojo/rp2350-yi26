#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp168 quick check — non-interactive.
#
# The central assertion is an absence: **this firmware contains no
# cryptography.** Everything else here is the transport, and the transport is
# checked by arithmetic rather than by agreement — a device that fragmented
# wrongly but consistently would satisfy every "the host and the board agree"
# check and fail the one in verify.py.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # the host's own FIDO tooling drives it; nothing needs a person
presence_check

USB_IFACE="cdc+hid"
USB_CARRIES="log+ctaphid"
USB_HOST="cdc_acm+hidraw"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp168-a-security-key-that-knows-nothing
UF2=target/exp168.uf2

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi
command -v fido2-token > /dev/null \
    && pass "fido2-token present (the host's own FIDO tooling, nothing installed for this)" \
    || fail "fido2-token present" "install libfido2-tools"

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

# **The claim this experiment is named for.** A reader who takes this for a
# security key has been misled by it, so the absence is checked rather than
# promised: no curve, no hash, no key material, and no dependency that could
# supply one.
if grep -qiE '^(p256|sha2|ed25519|rand|hmac|aes|ml-dsa|signature|ecdsa)\b' Cargo.toml; then
    fail "no cryptography is in this firmware" "$(grep -iE '^(p256|sha2|ed25519|rand|hmac|aes|ml-dsa|signature|ecdsa)\b' Cargo.toml | head -1)"
else
    pass "no cryptography is in this firmware: not one crypto dependency"
fi
# Log lines are excluded as well as comments. The first version of this check
# failed on the word "secret" inside the firmware's own line saying it has none,
# which is a grep that cannot tell a claim from its denial.
BARE="$(grep -v 'log!' <<< "$CODE")"
if grep -qiE '\b(sign|verify|private_key|secret|seed|sha256|p256|ecdsa)\b' <<< "$BARE"; then
    fail "no key material or signing in the source" "$(grep -oiE '\b(sign|verify|private_key|secret|seed|sha256|p256|ecdsa)\b' <<< "$BARE" | head -1)"
else
    pass "no key material or signing in the source, log lines and comments aside"
fi
grep -q 'NOT a security key' <<< "$CODE" \
    && pass "the firmware says what it is not, in its own first lines" \
    || fail "the firmware says what it is not" "a reader will assume otherwise"

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

if [[ -f capture.txt ]]; then
    REPLAY="$(python3 ./verify.py < capture.txt 2>&1 | tail -1)"
    [[ "$REPLAY" == "OK" ]] \
        && pass "verify.py replays the recorded transcript" \
        || fail "verify.py replays the recorded transcript" "got: $REPLAY"

    declare -A CORRUPTIONS=(
        ["a packet count the arithmetic contradicts"]='s/"len": 200, "packets": 4/"len": 200, "packets": 3/'
        ["an error code swapped for another"]='s/ERR_INVALID_SEQ/ERR_INVALID_LEN/'
        ["a stray continuation packet that was answered"]='s/"reply": null, "silence_expected"/"reply": {"cid":"0","cmd":63,"len":1,"packets":1,"error_code":1,"error_name":"ERR_INVALID_CMD"}, "silence_expected"/'
        ["a report descriptor with the wrong usage page"]='s/06d0f10901a1010920150026ff00750895/07d0f10901a1010920150026ff00750895/'
        ["a device claiming a capability it lacks"]='s/(nowink, nocbor, nomsg)/(nowink, nomsg)/'
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
grep -q 'nocbor' <<< "$LIVE" \
    && pass "fido2-token -I reports a device that knows nothing, in the protocol's words" \
    || fail "fido2-token -I reports what it can do" "the capability byte is how a device says so"

exit "$FAILED"
