#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
#
# exp192 — the same key through two stacks that have never heard of each other.
#
#   ./crosscheck.sh        one press
#
# ./run.sh established what a browser sends: not the bytes a page hands
# `prf.eval.first`, but `SHA-256("WebAuthn PRF" ‖ 0x00 ‖ input)`. That is a
# statement about a client, and on its own it is only half of what anyone wants
# to know. The other half is whether a *different* client, told that salt,
# derives the same key from the same credential.
#
# So this takes the browser's credential id and the salt the board actually
# received, hands both to `libfido2` — which has never heard of WebAuthn's prf
# extension and cannot derive that salt itself — and compares the thirty-two
# bytes with what the page got.
#
# If they match, exp191's vault can be opened from either side, provided the CLI
# side derives its salt the way a browser does. If they do not, they cannot, and
# the reason is somewhere neither tool reports.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

say() { printf '>>> %s\n' "$*" >&2; }

[[ -f analysis.json ]] || { echo "run ./run.sh first — analysis.json is missing" >&2; exit 1; }

read -r RP INPUT CRED BROWSER_KEY WHICH <<< "$(python3 - <<'PY'
import json
d = json.load(open("analysis.json"))
g = next((x for x in d["gets"] if x.get("prf_first_hex")), None)
cred = ""
for line in open("transcript.json"):
    e = json.loads(line)
    if e.get("step") == "create" and e.get("credentialId"):
        cred = e["credentialId"]
print(d["rp_id"], d["prf_input"].replace(" ", "\x01"), cred,
      g["prf_first_hex"] if g else "", (g or {}).get("which_candidate", ""))
PY
)"
INPUT="${INPUT//$'\x01'/ }"
[[ -n "$CRED" && -n "$BROWSER_KEY" ]] || { echo "analysis.json has no credential or no key" >&2; exit 1; }

# The salt, reconstructed from the candidate the board's log identified rather
# than read out of that log.
#
# This is deliberate and is the one place this script leans on an inference.
# The board's ring truncated the line at 28 of 32 bytes, which names the
# candidate past any argument — a coincidence is 2**-224 — but is not the salt.
# Using the truncated bytes would ask libfido2 a question nobody asked; using
# the named candidate asks exactly the question the browser asked. The
# transcript records which candidate, so the inference is visible rather than
# buried.
SALT_HEX="$(python3 -c '
import sys, salt
name = sys.argv[2].split(" (")[0]
print(salt.candidates(sys.argv[1].encode())[name].hex())
' "$INPUT" "$WHICH")"
SALT_B64="$(python3 -c 'import base64,sys;print(base64.b64encode(bytes.fromhex(sys.argv[1])).decode())' "$SALT_HEX")"

say "rp id        $RP"
say "prf input    '$INPUT'"
say "salt         $SALT_HEX"
say "             ($WHICH)"
say "browser key  $BROWSER_KEY"

DEV="$(fido2-token -L 2>/dev/null | grep -i 'same salt' | head -1 | cut -d: -f1)"
[[ -n "$DEV" ]] || { echo "no board running exp189" >&2; exit 1; }

mkdir -p work
{
    head -c 32 /dev/urandom | base64
    echo "$RP"
    echo "$CRED"
    echo "$SALT_B64"
} > work/crosscheck.in

say "fido2-assert -G -h — PRESS BOOTSEL"
if ! timeout 90 fido2-assert -G -h "$DEV" < work/crosscheck.in > work/crosscheck.out 2> work/crosscheck.err; then
    echo "REFUSED: $(tail -1 work/crosscheck.err)" >&2
    exit 1
fi

# fido2-assert prints credential id, client data hash, authdata, signature, and
# — with -h — the hmac-secret output last.
CLI_KEY="$(python3 -c '
import base64, sys
lines = [l.strip() for l in open("work/crosscheck.out") if l.strip()]
print(base64.b64decode(lines[-1]).hex())
')"
say "cli key      $CLI_KEY"

j() { python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "${1-}"; }
cat > crosscheck.json <<JSON
{
  "rp_id": $(j "$RP"),
  "prf_input": $(j "$INPUT"),
  "salt_hex": $(j "$SALT_HEX"),
  "salt_named": $(j "$WHICH"),
  "credential_id_b64": $(j "$CRED"),
  "browser_key_hex": $(j "$BROWSER_KEY"),
  "cli_key_hex": $(j "$CLI_KEY"),
  "same": $([[ "$BROWSER_KEY" == "$CLI_KEY" ]] && echo true || echo false)
}
JSON

if [[ "$BROWSER_KEY" == "$CLI_KEY" ]]; then
    say "the same thirty-two bytes, from two stacks that have never heard of each other"
else
    say "DIFFERENT. That is a finding, not a failure — see the README."
fi
say "wrote crosscheck.json"
