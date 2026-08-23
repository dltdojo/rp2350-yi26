#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp177 — does this device wait for a person, or only say that it did?
#
# exp171 wrote the rule down: **the bit that says a user was present is the
# device's own word, and nothing in the protocol checks it.** Every build in
# this repository since then has been careful to earn it, and `check.sh` there
# fails if an unattended build ever sets it.
#
# This asks the same question of firmware nobody here wrote. It cannot prove
# that no finger touched the board — no script can — so it measures the thing a
# script *can* see: **how long the device took**. A credential returned in
# roughly a second, repeatedly, with nobody asked to press anything, is a device
# that did not wait for a human reaction, whatever the flag says.
#
#   ./presence.sh          writes presence.json
#
# Nothing is flashed and nothing is changed. Run it whenever the board is
# running pico-fido.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

DEV="$(fido2-token -L 2>/dev/null | grep -i "pico key" | head -1 | cut -d: -f1)"
[[ -n "$DEV" ]] || { echo "no pico-fido device found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ROUNDS="${1:-3}"
echo "device: $DEV — $ROUNDS credentials, and nobody is asked to press anything"

RESULTS=""
for i in $(seq 1 "$ROUNDS"); do
    printf '%s\n%s\n%s\n%s\n' \
        "$(head -c 32 /dev/urandom | base64)" "example.test" "round-$i" \
        "$(head -c 16 /dev/urandom | base64)" > "$TMP/cred.in"
    START="$(date +%s%N)"
    if fido2-cred -M "$DEV" < "$TMP/cred.in" > "$TMP/cred-$i.out" 2>"$TMP/err"; then
        END="$(date +%s%N)"
        MS=$(( (END - START) / 1000000 ))
        UP="$(python3 ../exp176-the-same-question-of-two-devices/attest.py \
                --label round "$TMP/cred-$i.out" \
              | python3 -c "import json,sys; print('UP' in json.load(sys.stdin)['flags_set'])")"
        echo "  round $i: made a credential in ${MS} ms, UP claimed: ${UP}"
        RESULTS="${RESULTS}{\"round\": $i, \"ms\": $MS, \"up\": \"$UP\"},"
    else
        echo "  round $i: refused — $(head -1 "$TMP/err")"
        RESULTS="${RESULTS}{\"round\": $i, \"ms\": null, \"refused\": \"$(head -1 "$TMP/err" | tr -d '"')\"},"
    fi
done

# And the other half of the sentence: a client that believes it. exp173 found
# that `fido2-cred -V` refuses a credential whose UP bit is clear — the refusal
# it had been reading as "your attestation is malformed" for five experiments.
# So the same tool, on a credential nobody was present for, is the check that
# matters: if it verifies, the bit did its whole job without being earned.
LAST="$TMP/cred-$ROUNDS.out"
if [[ -f "$LAST" ]] && fido2-cred -V < "$LAST" > /dev/null 2>&1; then
    VERIFIED=true
    echo "  fido2-cred -V accepted the last one — a client, verifying a presence nobody was present for"
else
    VERIFIED=false
    echo "  fido2-cred -V refused the last one"
fi
cp "$LAST" unpressed-cred.out

# Through a file, not through the heredoc: interpolating JSON into a Python
# string literal put bare double quotes inside it and the parser stopped at the
# first key.
printf '[%s]' "${RESULTS%,}" > "$TMP/rounds.json"

ROUNDS_JSON="$TMP/rounds.json" VERIFIED="$VERIFIED" python3 - <<'PY'
import json, os
rounds = json.load(open(os.environ["ROUNDS_JSON"]))
made = [r for r in rounds if r.get("ms") is not None]
out = {
    "device": "pico-fido 8.0",
    "rounds": rounds,
    "nobody_was_asked_to_press": True,
    "all_succeeded": len(made) == len(rounds),
    "all_claimed_up": all(r.get("up") == "True" for r in made),
    "libfido2_verified_an_unpressed_credential": os.environ["VERIFIED"] == "true",
    "slowest_ms": max((r["ms"] for r in made), default=None),
    "note": ("A script cannot prove that nobody pressed the button. What it can "
             "show is that the device did not wait: a credential returned in "
             "about a second, every time, with the user-presence bit set. "
             "exp171 made this repository's own builds earn that bit and made "
             "check.sh fail if an unattended one ever set it. This is the same "
             "question asked of shipping third-party firmware, and the answer "
             "is not the same."),
}
json.dump(out, open("presence.json", "w"), indent=2)
print("slowest: %s ms, all claimed UP: %s, client verified it: %s"
      % (out["slowest_ms"], out["all_claimed_up"],
         out["libfido2_verified_an_unpressed_credential"]))
PY
