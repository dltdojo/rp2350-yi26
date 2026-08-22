#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# One round trip driven entirely by libfido2's own tools.
#
#   ./roundtrip.sh
#
# Everything up to here used a CTAPHID client written for this repository, which
# means every message the board saw was one this repository also wrote. These
# are somebody else's: their CBOR, their field order, their idea of what an
# authenticator owes a caller. What they refuse is the finding.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
DEV="$(fido2-token -L 2>/dev/null | head -1 | cut -d: -f1)"
[[ -n "$DEV" ]] || { echo "no FIDO device"; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say() { printf '>>> host: %s\n' "$*"; }
show() { sed 's/^/    /'; }

say "fido2-token -I, which is libfido2 reading what the device says it can do"
fido2-token -I "$DEV" 2>&1 | show

say "fido2-cred -M: libfido2 makes a credential"
printf '%s\n%s\n%s\n%s\n' \
    "$(head -c 32 /dev/urandom | base64)" "example.test" "somebody" \
    "$(head -c 16 /dev/urandom | base64)" > "$TMP/cred.in"
if fido2-cred -M "$DEV" < "$TMP/cred.in" > "$TMP/cred.out" 2>"$TMP/cred.err"; then
    echo "    made a credential, $(wc -l < "$TMP/cred.out") lines out"
    python3 decode.py credential < "$TMP/cred.out" | show
else
    echo "    REFUSED: $(cat "$TMP/cred.err")"
fi

say "fido2-cred -V: libfido2 verifies the self attestation it was just handed"
if fido2-cred -V < "$TMP/cred.out" > "$TMP/verify.out" 2>"$TMP/verify.err"; then
    echo "    verified, and wrote the public key out"
else
    echo "    REFUSED: $(cat "$TMP/verify.err")"
fi

say "fido2-assert -G: libfido2 asks for an assertion with that credential"
CRED="$(sed -n '5p' "$TMP/cred.out")"
CDH="$(head -c 32 /dev/urandom | base64)"
printf '%s\n%s\n%s\n' "$CDH" "example.test" "$CRED" > "$TMP/assert.in"
if fido2-assert -G "$DEV" < "$TMP/assert.in" > "$TMP/assert.out" 2>"$TMP/assert.err"; then
    echo "    got an assertion"
    python3 decode.py assertion < "$TMP/assert.out" | show
else
    echo "    REFUSED: $(cat "$TMP/assert.err")"
fi

say "and the same assertion checked against the key this repository extracted"
python3 decode.py check "$TMP/cred.out" "$TMP/assert.out" | show
