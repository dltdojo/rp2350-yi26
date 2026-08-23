#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp177 — one registration on somebody else's firmware. Needs a finger.
#
# `getInfo` is what a device says about itself and costs nobody anything.
# This is the other half: a credential, which needs a user present, and the
# attestation that comes back with it is where exp176's one uncloseable
# difference either closes or does not.
#
# The button is **BOOTSEL**. pico-fido reads it the same way exp106 does, so
# holding it down is safe on a running board and does not reboot anything.
#
#   ./register.sh          then hold BOOTSEL when it says to
#
# It writes picofido-cred.out and picofido-attestation.json, and leaves the
# board exactly as it found it — a credential is not a state this experiment
# has to undo, and pico-fido stores nothing for a non-resident one.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

DEV="$(fido2-token -L 2>/dev/null | grep -i "pico key" | head -1 | cut -d: -f1)"
if [[ -z "$DEV" ]]; then
    echo "no pico-fido device found — is it flashed? (./setup.sh, then the boot drive)"
    exit 1
fi
echo "device: $DEV"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The same four lines exp173 hands libfido2: client data hash, relying party,
# user name, user handle.
printf '%s\n%s\n%s\n%s\n' \
    "$(head -c 32 /dev/urandom | base64)" "example.test" "somebody" \
    "$(head -c 16 /dev/urandom | base64)" > "$TMP/cred.in"

echo ""
echo "  >>> HOLD BOOTSEL on the board now, and keep holding it. <<<"
echo ""
echo "      fido2-cred is asking for a credential; the device will not answer"
echo "      until it sees a user present. Nothing here can press it for you,"
echo "      and this script can only report whether somebody did."
echo ""

if fido2-cred -M "$DEV" < "$TMP/cred.in" > picofido-cred.out 2>"$TMP/err"; then
    echo "made a credential: $(wc -l < picofido-cred.out) lines"
else
    echo "REFUSED: $(cat "$TMP/err")"
    echo ""
    echo "If that says FIDO_ERR_USER_ACTION_TIMEOUT, nobody pressed in time —"
    echo "which is the honest failure and not a fault. Run it again."
    exit 1
fi

python3 ../exp176-the-same-question-of-two-devices/attest.py \
    --label pico-fido picofido-cred.out > picofido-attestation.json
python3 -c "
import json
a = json.load(open('picofido-attestation.json'))
print('format              :', a['format'])
print('AAGUID in authData  :', a.get('aaguid'))
print('certificate chain   :', a['has_certificate_chain'])
print('flags set           :', ', '.join(a['flags_set']))
"
