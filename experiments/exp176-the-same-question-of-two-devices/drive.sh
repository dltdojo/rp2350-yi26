#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp176 — the same question, asked of two devices.
#
#   ./drive.sh
#
# getInfo for both is unattended. The attestation half registers a credential on
# each, and the commercial key needs what a commercial key needs: your PIN,
# entered at this terminal (this script never sees it — fido2-cred prompts you),
# and a touch. The board's half is unattended, on the EXP174_UP=none build.
#
# Nothing here changes the commercial key's state: the credential is
# non-resident (server-side), so it consumes no slot and stores nothing on the
# key. It is the ordinary thing a website does.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

BOARD_NONE=../exp174-a-deadline-nobody-mentioned/target/exp174-none-fixed.uf2
say() { printf '>>> %s\n' "$*"; }

board_dev() { fido2-token -L 2>/dev/null | grep -i 'deadline nobody mentioned' | head -1 | cut -d: -f1; }
key_dev()   { fido2-token -L 2>/dev/null | grep -vi 'rp2350-yi26' | grep -i 'hidraw' | head -1 | cut -d: -f1; }

KEY="$(key_dev)"
[[ -n "$KEY" ]] || { say "no commercial FIDO2 key found — plug one in"; exit 1; }
say "commercial key at $KEY:"
fido2-token -L 2>/dev/null | grep "$KEY" | sed 's/^/    /'

# --- getInfo, both, unattended -------------------------------------------
say "flashing exp174 (UP=none) so the board half needs no finger"
yi26 bootsel >/dev/null 2>&1; sleep 2
yi26 pflash "$BOARD_NONE" >/dev/null 2>&1; sleep 7
BOARD="$(board_dev)"
[[ -n "$BOARD" ]] || { say "the board did not come back as exp174"; exit 1; }

say "probing getInfo from both"
python3 probe.py "$BOARD" > board.json
python3 probe.py "$KEY"   > yubikey.json
python3 compare.py board.json yubikey.json > comparison.json
say "the gap, sorted by kind:"
python3 -c "import json;d=json.load(open('comparison.json'));[print('    %-13s %s'%(g['kind'],g['capability'])) for g in d['gap']];print('    ----');print('    counts:',d['counts_by_kind'])"

# --- attestation, board unattended, key with your PIN --------------------
say "registering a credential on the board (no finger; UP=none build)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '%s\n%s\n%s\n%s\n' "$(head -c32 /dev/urandom|base64)" example.test somebody \
    "$(head -c16 /dev/urandom|base64)" > "$TMP/in"
fido2-cred -M "$BOARD" < "$TMP/in" > board-cred.out 2>"$TMP/e" \
    && python3 attest.py --label board board-cred.out > board-attestation.json \
    || { say "board registration failed: $(cat "$TMP/e")"; exit 1; }

echo
say "now the commercial key. It will ask for YOUR PIN (typed here, not stored)"
say "and a touch. This makes a non-resident credential — nothing is kept on the key."
printf '%s\n%s\n%s\n%s\n' "$(head -c32 /dev/urandom|base64)" example.test somebody \
    "$(head -c16 /dev/urandom|base64)" > "$TMP/kin"
if fido2-cred -M "$KEY" < "$TMP/kin" > yubikey-cred.out 2>"$TMP/ke"; then
    python3 attest.py --label "commercial key" yubikey-cred.out > yubikey-attestation.json
    say "registered on the key"
else
    say "key registration failed: $(cat "$TMP/ke")"
    say "(if it says PIN, run again and enter your key's PIN when prompted)"
    exit 1
fi

echo
say "the two attestations, side by side:"
python3 - <<'PY'
import json
b = json.load(open("board-attestation.json"))
k = json.load(open("yubikey-attestation.json"))
w = "%-22s %-26s %-26s"
print("    " + w % ("", "board", "commercial key"))
for label, key in (("format","format"), ("aaguid zero","aaguid_is_zero"),
                   ("certificate chain","has_certificate_chain"), ("identity","identity")):
    print("    " + w % (label, str(b[key])[:25], str(k[key])[:25]))
PY
say "the board self-attests with an all-zero AAGUID; the key roots its identity"
say "in a certificate. That certificate is the one thing exp175 showed this chip"
say "cannot honestly keep — see the README."
