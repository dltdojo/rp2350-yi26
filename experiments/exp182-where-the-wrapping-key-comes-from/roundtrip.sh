#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp182 — one round trip, driven by libfido2, on a key that is in no image.
#
# This is exp173's round trip unchanged in shape: their tools, their CBOR, their
# idea of what an authenticator owes a caller. What is different is where the
# device's secret came from — SRAM, reconstructed at boot — and the point is
# that libfido2 cannot tell, because there is nothing about a credential that
# says where the key behind it was kept.
#
#   ./roundtrip.sh          hold BOOTSEL when it asks
#
# Needs the `button` build: exp173 measured that `fido2-cred -V` refuses a
# credential whose user-presence bit is clear, so a UP=none build cannot
# complete this.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

DEV="$(fido2-token -L 2>/dev/null | grep -i 'wrapping key' | head -1 | cut -d: -f1)"
[[ -n "$DEV" ]] || DEV="$(fido2-token -L 2>/dev/null | head -1 | cut -d: -f1)"
[[ -n "$DEV" ]] || { echo "no FIDO device"; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say() { printf '>>> host: %s\n' "$*"; }

say "the device's own account of where its secret came from"
yi26 log --seconds 6 2>/dev/null | grep -E "device secret|bank 8|enrolled at|forge.py" | sed 's/^/    /'

printf '%s\n%s\n%s\n%s\n' \
    "$(head -c 32 /dev/urandom | base64)" "example.test" "somebody" \
    "$(head -c 16 /dev/urandom | base64)" > "$TMP/cred.in"

say "fido2-cred -M — HOLD BOOTSEL until it returns"
if fido2-cred -M "$DEV" < "$TMP/cred.in" > "$TMP/cred.out" 2>"$TMP/err"; then
    echo "    made a credential, $(wc -l < "$TMP/cred.out") lines out"
else
    echo "    REFUSED: $(cat "$TMP/err")"
    exit 1
fi

say "fido2-cred -V — libfido2 verifies the self attestation it was handed"
if fido2-cred -V < "$TMP/cred.out" > "$TMP/verify.out" 2>"$TMP/verr"; then
    echo "    verified, and wrote the public key out"
else
    echo "    REFUSED: $(cat "$TMP/verr")"
    exit 1
fi

# fido2-assert wants: client data hash, rp id, credential id, then the pubkey
# on the -V output's terms.
head -1 "$TMP/verify.out" > "$TMP/cred.id"
tail -n +2 "$TMP/verify.out" > "$TMP/pubkey.pem"
printf '%s\n%s\n%s\n' \
    "$(head -c 32 /dev/urandom | base64)" "example.test" "$(cat "$TMP/cred.id")" \
    > "$TMP/assert.in"

say "fido2-assert -G — HOLD BOOTSEL again"
if fido2-assert -G "$DEV" < "$TMP/assert.in" > "$TMP/assert.out" 2>"$TMP/aerr"; then
    echo "    got an assertion"
else
    echo "    REFUSED: $(cat "$TMP/aerr")"
    exit 1
fi

say "fido2-assert -V — the assertion against the key the credential handed over"
if fido2-assert -V "$TMP/pubkey.pem" es256 < "$TMP/assert.out" > /dev/null 2>"$TMP/averr"; then
    echo "    VERIFIED — a credential whose private key is in no image and no flash"
else
    echo "    REFUSED: $(cat "$TMP/averr")"
    exit 1
fi
