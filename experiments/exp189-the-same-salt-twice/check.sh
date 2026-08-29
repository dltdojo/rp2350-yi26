#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
#
# exp189 quick check — non-interactive.
#
# This experiment is a plan and an instrument: a README, the host-side scripts,
# and no firmware. So what this script does today is say precisely what is
# missing, and enforce the rules that apply to unverified work — the index
# agrees about what it costs a person, the Expected output section stays empty,
# and the instrument that will judge the run is itself tested against a record
# it must refuse.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=2
presence_check

USB_IFACE="cdc+hid"
USB_CARRIES="log+ctaphid"
USB_HOST="cdc_acm+hidraw"
USB_RUNS_ON="own"
usb_check

command -v python3 > /dev/null && pass "python3 present" \
    || { fail "python3 present" "needed to run verification tools"; exit 1; }

# The client is somebody else's, which is the point of this rung, so its
# absence is a missing prerequisite rather than a missing feature.
if command -v fido2-assert > /dev/null && command -v fido2-cred > /dev/null; then
    pass "libfido2's own tools are on this host"
    if fido2-assert 2>&1 | head -1 | grep -q 'h'; then
        pass "this fido2-assert takes -h (the hmac-secret extension)"
    else
        fail "this fido2-assert takes -h" "libfido2 is too old to ask for hmac-secret"
    fi
else
    echo "SKIP  libfido2's tools are not installed — install fido2-tools to run roundtrip.sh"
fi

# ---------------------------------------------------------------------------
# The instrument, tested before the subject exists.
#
# exp174 rebuilt its instrument twice, and both failures were only visible in
# hindsight. verify.py's whole job is to refuse a run where the same salt gave
# two different answers, so it is handed exactly that and required to refuse.
# The fixtures are fabricated and live in a temporary directory: nothing that
# looks like a transcript is ever written into this experiment by check.sh.
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

python3 - "$FIX" <<'FIXTURES'
import base64, hashlib, json, sys, pathlib
d = pathlib.Path(sys.argv[1])
def k(s): return base64.b64encode(hashlib.sha256(s.encode()).digest()).decode()
good = {
    "device": "/dev/hidraw9", "rp_id": "example.test",
    "salt_one": k("s1"), "salt_two": k("s2"), "key_source": "key source: constant",
    "cred_a_made": True, "cred_b_made": True,
    "ga_salt1": k("A"), "ga_salt1_again": k("A"), "ga_salt2": k("B"), "ga_credB_salt1": k("C"),
    "ga_plain_ok": True,
}
(d / "consistent.json").write_text(json.dumps(good))
(d / "unstable.json").write_text(json.dumps({**good, "ga_salt1_again": k("A-but-not-quite")}))
(d / "anonymous.json").write_text(json.dumps({**good, "key_source": ""}))

np = {"attempts": 3, "answered": 0, "refusal_code": "FIDO_ERR_OPERATION_DENIED", "bootsel_line": ""}
(d / "np-good.json").write_text(json.dumps(np))
# A key came out and the pad never read low: the device set the bit by itself.
(d / "np-lied.json").write_text(json.dumps({**np, "answered": 1}))
# A key came out and the pad did read low: somebody pressed, so the run is not a
# measurement — a different sentence, and the whole reason the log line exists.
(d / "np-pressed.json").write_text(json.dumps({**np, "answered": 1,
    "bootsel_line": "presence: BOOTSEL read low at 9280 ms"}))
(d / "np-thin.json").write_text(json.dumps({**np, "attempts": 1}))
FIXTURES

python3 verify.py "$FIX/consistent.json" > /dev/null 2>&1 \
    && pass "verify.py accepts a record where the same salt gave the same bytes" \
    || fail "verify.py accepts a consistent record" "it refuses one it should take"

python3 verify.py "$FIX/consistent.json" "$FIX/np-good.json" > /dev/null 2>&1 \
    && pass "verify.py accepts a consistent pair of transcripts" \
    || fail "verify.py accepts a consistent pair" "it refuses a pair it should take"

for case in unstable:"the same salt giving two answers" \
            anonymous:"a transcript that does not say which arm made it"; do
    f="${case%%:*}"; what="${case#*:}"
    if python3 verify.py "$FIX/$f.json" > /dev/null 2>&1; then
        fail "verify.py refuses $what" "it accepted it"
    else
        pass "verify.py refuses $what"
    fi
done

# The unattended half, and the distinction that cost this experiment two runs.
for case in np-lied:"a key with the pad never reading low — the device set the bit itself" \
            np-pressed:"a key with the pad reading low — somebody pressed, so it is not a measurement" \
            np-thin:"one attempt, when the failure it catches is intermittent"; do
    f="${case%%:*}"; what="${case#*:}"
    if python3 verify.py "$FIX/consistent.json" "$FIX/$f.json" > /dev/null 2>&1; then
        fail "verify.py refuses $what" "it accepted it"
    else
        pass "verify.py refuses $what"
    fi
done

# The strict reader, and the case a real client actually sends.
#
# crates/cbor refused every COSE key inside a skipped subtree, because its
# canonical-order check accepted unsigned and text map keys and nothing else —
# and a COSE key is {1, 3, -1, -2, -3}. exp170 wrote down that whether a real
# client sends something this reader rejects was untested. It does, and this is
# the test that keeps the answer.
crate_test ../../crates/cbor "the strict CBOR reader passes its own tests"

# ---------------------------------------------------------------------------
# The control: age plus age-plugin-fido2-hmac.
#
# None of this gates on the plugin working, or even existing. What is checked is
# that the experiment cannot quietly acquire an unpinned third-party binary, and
# that a half-pinned state — a version written down with no hash under it — is
# caught rather than shipped.
PINS="$(grep -cE '^(AGE|PLUGIN)_SHA256="[0-9a-f]{64}"' setup.sh || true)"
VERS="$(grep -cE '^(AGE|PLUGIN)_VERSION="[^"]+"' setup.sh || true)"

if [[ "$PINS" -eq 0 && "$VERS" -eq 0 ]]; then
    pass "the age control is unpinned, and setup.sh says so rather than fetching on trust"
    if ./setup.sh > /dev/null 2>&1; then
        fail "setup.sh refuses to run unpinned" "it did something with no SHA-256 to check against"
    else
        pass "setup.sh refuses to run unpinned"
    fi
elif [[ "$PINS" -eq 2 && "$VERS" -eq 2 ]]; then
    pass "both third-party artifacts are pinned by version and SHA-256"
    # exp177's rule: what was measured is a version, and a transcript that does
    # not name it is not a dated observation.
    for v in $(grep -oE '^(AGE|PLUGIN)_VERSION="[^"]+"' setup.sh | cut -d'"' -f2); do
        grep -q -- "$v" README.md \
            && pass "the README names the version measured ($v)" \
            || fail "the README names the version measured ($v)" "exp177's rule: say which release this was"
    done
else
    fail "the age control is either fully pinned or not pinned at all" \
         "$VERS versions and $PINS hashes — a version with no hash under it is a decoration"
fi

grep -qx 'work/' .gitignore 2>/dev/null && grep -qx 'bin/' .gitignore 2>/dev/null \
    && pass "somebody else's binaries are git-ignored, never vendored" \
    || fail "bin/ is git-ignored" "exp177's rule: fetched, checked, and not checked in"

# And then on the transcripts that are actually checked in.
#
# This ruled on four fabricated records and never on the real ones, so a
# `nopress.json` that verify.py refused — a key that came out with nobody
# meant to be pressing — left check.sh green. The instrument was being tested
# and the measurement was not.
if [[ -f roundtrip.json && -f nopress.json ]]; then
    echo "      ruling on roundtrip.json and nopress.json"
    if python3 verify.py roundtrip.json nopress.json > /dev/null 2>&1; then
        pass "the checked-in transcripts pass their own verifier"
    else
        fail "the checked-in transcripts pass their own verifier" \
             "run python3 verify.py roundtrip.json nopress.json to see which rule"
    fi
elif [[ -f roundtrip.json || -f nopress.json ]]; then
    fail "both transcripts are present or neither is" \
         "one half of a run is not a run"
fi

SRC=src/main.rs

# The two arms, and the difference that needs no board.
#
# This is the whole of "Two arms, and somebody else's attack" as a check: the
# constant image must contain exp171's test key and the bank8 image must not.
# The first version of the bank8 arm failed exactly here — the const was still
# compiled in, unused, and exp175's forgery minted an assertion from the image
# anyway. A secret in a file is a secret whether or not the firmware reaches
# for it, so the arm is built with `#[cfg(not(bank8))]` and this reads the bytes.
SENTENCE='not a secret. this is a test key'
for arm in constant:target/exp189.uf2:present bank8:target/exp189-bank8.uf2:absent; do
    name="${arm%%:*}"; rest="${arm#*:}"; img="${rest%%:*}"; want="${rest##*:}"
    if [[ ! -f "$img" ]]; then
        echo "SKIP  $name image not built — see Running it"
        continue
    fi
    if grep -qa "$SENTENCE" "$img"; then have=present; else have=absent; fi
    if [[ "$have" == "$want" ]]; then
        pass "the $name image has the test key $want, as its arm requires"
    else
        fail "the $name image has the test key $want" "it is $have, so the comparison says nothing"
    fi
done

# The LED has three states, because a person at the board has nothing else.
#
# This experiment shipped with two — a boolean meaning *press me* — and then
# asked for a cable pull by printing a sentence to a terminal nobody was sitting
# at. exp182 had already paid for that lesson and written it in its own source:
# *this one went back to words and cost a round trip to find out.*
for st in LED_IDLE LED_PRESS_NOW LED_UNPROVISIONED; do
    grep -q "const $st" "$SRC" \
        && pass "the LED can say $st" \
        || fail "the LED can say $st" "a person at the board has no other channel"
done
grep -q 'fn led_rest' "$SRC" \
    && pass "a finished press window returns to the right resting state, not always idle" \
    || fail "led_rest exists" "storing IDLE unconditionally paints over 'unplug me'"

# A panic that cannot be seen is a board that has left the USB bus.
#
# exp183 cost three trips to a bench on a silent `panic-halt`, and this
# experiment cost a fourth: `SecretKey::from_slice` on the thirty-two zero bytes
# an unprovisioned board returns is an `Err`, and the `.unwrap()` on it fired
# before the USB stack was serving.
grep -q 'panic_handler' "$SRC" && ! grep -q 'use panic_halt' "$SRC" \
    && pass "a panic says where it was before it stops" \
    || fail "a panic says where it was" "panic-halt halts in silence, which reads as a bad cable"

grep -q 'SecretKey::from_slice(secret_bytes()).unwrap()' "$SRC" \
    && fail "the key-agreement key tolerates an unprovisioned board" \
            "zero is not a valid P-256 scalar, and this panics before USB is up" \
    || pass "the key-agreement key tolerates an unprovisioned board"

# ---------------------------------------------------------------------------
# The firmware, which is not written.
if [[ -f "$SRC" ]]; then
    if command -v cargo > /dev/null; then
        if cargo build --release --quiet 2> /dev/null; then
            ELF="target/thumbv8m.main-none-eabihf/release/exp189-the-same-salt-twice"
            [[ -f "$ELF" ]] && pass "firmware compiles ($(stat -c%s "$ELF") byte ELF)" \
                            || fail "firmware compiles" "cargo build --release"
        else
            fail "firmware compiles" "cargo build --release"
        fi
    else
        echo "SKIP  no toolchain — see exp102"
    fi
    pass "src/main.rs exists"

    # exp171 wrote down that the presence bit is the device's own word. Here
    # the device is handing over a key, so the wait has to gate the arithmetic
    # and not the send: a build that computes the key and then waits has
    # already made the secret exist, and every bug in the path after that point
    # is a bug that leaks one.
    #
    # These two names are a contract the firmware owes this check, written here
    # before the firmware, so that the ordering cannot be got wrong quietly.
    # exp183 answers CTAPHID_INIT with 0x08 under a comment that says CBOR —
    # 0x08 is CAPABILITY_NMSG, and the CBOR bit is 0x04. Measured on the bench:
    # `fido2-token -I` reads that board back as `nocbor`, so libfido2 sends it
    # no CBOR at all and neither does anything built on libfido2. exp189 is
    # driven entirely by somebody else's tools, so the bit is a prerequisite
    # rather than a detail.
    if grep -qE 'CAPABILITIES[^=]*=[^;]*0x04' "$SRC"; then
        pass "CTAPHID_INIT claims CAPABILITY_CBOR (0x04), so libfido2 will talk to it"
    else
        fail "CTAPHID_INIT claims CAPABILITY_CBOR (0x04)" \
             "exp183 sent 0x08 alone and every libfido2 client reads that as nocbor"
    fi

    # The **call sites**, not the definitions: where a function is written says
    # nothing about when it runs, and the first version of this check compared
    # the two `fn` lines and failed a firmware that was correct.
    WAIT_AT="$(grep -n 'wait_for_user_presence(&mut reader' "$SRC" | tail -1 | cut -d: -f1)"
    HMAC_AT="$(grep -n 'hmac_secret_output(&cr' "$SRC" | head -1 | cut -d: -f1)"
    if [[ -z "$WAIT_AT" || -z "$HMAC_AT" ]]; then
        fail "the source names wait_for_user_presence and hmac_secret_output" \
             "check.sh cannot read the ordering it is supposed to enforce"
    elif (( WAIT_AT < HMAC_AT )); then
        pass "the press gates the arithmetic — the wait is at line $WAIT_AT, the HMAC at $HMAC_AT"
    else
        fail "the press gates the arithmetic" \
             "the HMAC is at line $HMAC_AT and the wait at $WAIT_AT — the key exists before anybody pressed"
    fi
else
    fail "src/main.rs exists" "exp189 is a plan and an instrument; the firmware is not written"
fi

# ---------------------------------------------------------------------------
# The rules that apply while it is unverified.
#
# Two-way, on purpose: "Not captured yet" must be there while there is no
# transcript, and must be gone once there is one. A section filled in from what
# the code should do is the exact failure the rule exists to stop.
SECTION="$(sed -n '/^## Expected output/,/^## /p' README.md)"
if [[ -f roundtrip.json && -f nopress.json ]]; then
    grep -q "Not captured yet" <<< "$SECTION" \
        && fail "Expected output has been filled in" "a transcript exists and the section still says it does not" \
        || pass "a transcript exists and Expected output no longer says otherwise"
else
    grep -q "Not captured yet" <<< "$SECTION" \
        && pass "no board has run this, and Expected output says so and nothing else" \
        || fail "Expected output stays empty until a board has run this" \
                "no transcript is checked in, so the section may not describe one"
fi

for e in exp169 exp171 exp172 exp173 exp174 exp175 exp176 exp178 exp181 exp182 exp183 exp185; do
    grep -q "$e" README.md 2>/dev/null \
        && pass "the README names $e" \
        || fail "the README names $e" "this experiment stands on $e"
done

exit "$FAILED"
