#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp175 quick check — non-interactive.
#
# **This experiment has no firmware of its own.** Its subject is exp174's image,
# and its claim is that the image *is* the secret: anyone holding the .uf2 can
# be the device. So the check is host-side and needs no board — it lifts the
# secret out of the file, forges an assertion, and confirms the forgery three
# ways, then mutates the forgery and requires each break to be caught.
#
# What it cannot check unattended is the two hardware demonstrations in
# drive.sh: that a credential survives reflashing the board to another firmware
# and back (a person, some presses), and that exp141's PICOBOOT port reads the
# same secret off a live board (a WebUSB tap). Those reinforce the finding; the
# offline forgery already proves it.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

# The offline core needs nobody; the drive.sh demonstrations need presses and a
# tap. exp174's level: a person for one action, then software.
PRESENCE=2
presence_check

# No firmware of its own. The tokens describe the firmware it attacks — exp174's
# — which is what a board runs during the drive.sh demonstrations; usb_check
# skips the source comparison when there is no src/main.rs, as it does for
# exp141.
USB_IFACE="cdc+hid"
USB_CARRIES="log+ctaphid"
USB_HOST="cdc_acm+hidraw"
USB_RUNS_ON="own"
usb_check

command -v python3 > /dev/null \
    && pass "python3 present" \
    || { fail "python3 present" "needed to unpack, forge and verify"; exit 1; }
python3 -c 'import cryptography' 2>/dev/null \
    && pass "python3-cryptography present (the host's own EC library)" \
    || { fail "python3-cryptography present" "apt install python3-cryptography"; exit 1; }

# The image under attack is exp174's. Build it if it is not already there, so
# this check stands alone.
UF2=../exp174-a-deadline-nobody-mentioned/target/exp174-button.uf2
if [[ ! -f "$UF2" ]]; then
    if ( cd ../exp174-a-deadline-nobody-mentioned \
         && EXP174_UP=button cargo build --release --quiet 2>/dev/null \
         && elf2flash convert -b rp2350 \
             target/thumbv8m.main-none-eabihf/release/exp174-a-deadline-nobody-mentioned \
             target/exp174-button.uf2 > /dev/null 2>&1 ); then
        pass "built exp174's firmware to attack"
    else
        fail "exp174's firmware is available to attack" "build exp174 first"
        exit 1
    fi
else
    pass "exp174's firmware is present to attack"
fi

NEEDLE="not a secret. this is a test key"

# ---------------------------------------------------------------------------
# the .uf2 does not hide what a naive grep says it hides
# ---------------------------------------------------------------------------

if grep -qa "$NEEDLE" "$UF2"; then
    RAWGREP="found"
else
    RAWGREP="missed"
fi
if python3 unpack.py "$UF2" "$NEEDLE" | grep -q 'found'; then
    pass "unpack.py reassembles the UF2 payload and finds the secret"
else
    fail "unpack.py finds the secret in the image" "it is at a known address"
fi
# The teaching point: whichever way the raw grep fell, the reassembled search is
# the one to trust. A student who greps the file and stops has learned nothing
# safe. (On this image the boundary happens to spare the string, so the raw grep
# finds it too; the note in unpack.py and README explains why that is luck.)
pass "raw grep of the .uf2 $RAWGREP it — which is luck either way, see unpack.py"

# ---------------------------------------------------------------------------
# the file is enough to be the device
# ---------------------------------------------------------------------------

FORGED="$(mktemp --suffix=.json)"
trap 'rm -f "$FORGED"' EXIT
if python3 forge.py "$UF2" webauthn.io --out "$FORGED" 2>/dev/null; then
    pass "forge.py mints an assertion from the image alone, no board involved"
else
    fail "forge.py produces a forgery" "python3 forge.py $UF2 webauthn.io"
fi
if python3 verify.py "$UF2" "$FORGED" > /dev/null 2>&1; then
    pass "verify.py confirms it three ways: signature, acceptance, derived key"
else
    fail "verify.py confirms the forgery" "python3 verify.py $UF2 $FORGED"
fi

# The checked-in example, so the record does not depend on a fresh run.
if [[ -f forged-example.json ]]; then
    if python3 verify.py "$UF2" forged-example.json > /dev/null 2>&1; then
        pass "the checked-in forged-example.json still verifies"
    else
        fail "forged-example.json verifies" "re-run: python3 forge.py $UF2 webauthn.io --out forged-example.json"
    fi
else
    fail "forged-example.json is checked in" "the record has no worked example"
fi

# ---------------------------------------------------------------------------
# exp159's rule: verify.py must reject a forgery that has been tampered with
# ---------------------------------------------------------------------------

for FIELD in signature tag pubkey flags; do
    MUT="$(mktemp --suffix=.json)"
    if ! python3 mutate.py forged-example.json "$MUT" "$FIELD=x" 2>/dev/null; then
        fail "the $FIELD mutation applies" "mutate.py could not edit it"
    elif python3 verify.py "$UF2" "$MUT" > /dev/null 2>&1; then
        case "$FIELD" in
            signature) W="a broken signature" ;;
            tag)       W="a credential the device would reject" ;;
            pubkey)    W="a public key the secret does not derive" ;;
            flags)     W="an assertion with no presence claimed" ;;
        esac
        fail "verify.py rejects $W" "it still said everything passed"
    else
        case "$FIELD" in
            signature) W="a broken signature" ;;
            tag)       W="a credential the device would reject" ;;
            pubkey)    W="a public key the secret does not derive" ;;
            flags)     W="an assertion with no presence claimed" ;;
        esac
        pass "verify.py rejects $W"
    fi
    rm -f "$MUT"
done

# ---------------------------------------------------------------------------
# and the argument it makes
# ---------------------------------------------------------------------------

grep -q 'identity road' README.md \
    && pass "the README names what would close this: a secret the image does not carry" \
    || fail "the README points at the identity road" "a finding with no way forward is half a finding"
grep -qi 'OTP\|Secure Lock\|secure boot' README.md \
    && pass "and the README records that the fix is a mechanism this project does not use" \
    || fail "the README names the fix it declines" "the honest half of the comparison"

exit "$FAILED"
