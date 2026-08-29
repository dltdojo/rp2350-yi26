#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Make a credential on the board, log the CLI in, and seal what it wrote.
#
#   ./seal.sh          needs a board and one press
#
# The salt is written beside the vault in the clear. A salt is not a secret: the
# client chooses it and sends it, and what shuts the vault is that
# HMAC(CredRandom, salt) exists only inside a board somebody pressed.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

# Fixed, and derived from a sentence rather than /dev/urandom, so two runs on
# two days are comparable — exp189's salts are chosen the same way.
SALT="$(python3 -c 'import base64,hashlib;print(base64.b64encode(hashlib.sha256(b"exp191 vault salt").digest()).decode())')"

echo ">>> making a credential. PRESS BOOTSEL when the LED goes solid." >&2
DEV="$(fido2-token -L 2>/dev/null | grep -i 'same salt' | head -1 | cut -d: -f1)"
[[ -n "$DEV" ]] || DEV="$(fido2-token -L 2>/dev/null | head -1 | cut -d: -f1)"
[[ -n "$DEV" ]] || { echo "no FIDO device — is a board running exp189?" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '%s\nexample.test\nalice\n%s\n' \
    "$(head -c 32 /dev/urandom | base64)" "$(head -c 16 /dev/urandom | base64)" > "$TMP/in"
# libfido2 makes the credential, because making one is exp189's ground and its
# tools are the ones that road proved the board against. Everything after this
# — the key, the vault, the wrapper — is this repository's own.
# Retried, and only on the refusal that means nobody pressed. exp189 learned
# this the expensive way: a missed press used to cost a seven-press run, and the
# device is what is under test rather than the reflexes of whoever is standing
# there. Any other refusal is the subject failing and is not retried.
made=0
for try in 1 2 3; do
    if fido2-cred -M -h "$DEV" < "$TMP/in" > "$TMP/cred" 2> "$TMP/err"; then made=1; break; fi
    grep -q FIDO_ERR_OPERATION_DENIED "$TMP/err" || { echo "REFUSED: $(cat "$TMP/err")" >&2; exit 1; }
    echo ">>> window $try closed — press BOOTSEL when the LED goes solid" >&2
done
[[ "$made" -eq 1 ]] || { echo "nobody pressed in three windows" >&2; exit 1; }
fido2-cred -V -h < "$TMP/cred" > "$TMP/ver" || { echo "attestation refused" >&2; exit 1; }
head -1 "$TMP/ver" > cred.id
echo ">>> credential made"

echo ">>> asking the board for the key. PRESS BOOTSEL again." >&2
KEY=""
for try in 1 2 3; do
    KEY="$(python3 getkey.py "$(cat cred.id)" "$SALT" 2>/dev/null)" && [[ -n "$KEY" ]] && break
    echo ">>> window $try closed — press BOOTSEL when the LED goes solid" >&2
done
[[ -n "$KEY" ]] || { echo "no key in three windows" >&2; exit 1; }

PLAIN="$TMP/config"
mkdir -p "$PLAIN"
MOCKCLI_CONFIG_DIR="$PLAIN" ./mock-cli.sh login "sealed-$(date -u +%Y%m%dT%H%M%SZ)" >&2
VAULT_KEY="$KEY" python3 vault.py seal "$PLAIN" vault.bin "$SALT"
echo ">>> sealed. The key is not on this machine."
