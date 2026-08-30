#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
#
# exp192 quick check — non-interactive.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed
#
# The live half is ./run.sh, which needs a browser, a person, and three presses.
# Everything here either rules on what that run wrote or needs nothing at all.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=2
LIFELINE="no: no firmware of its own; it runs against exp189's board"
presence_check
lifeline_check

# No firmware of its own. It flashes exp189 with EXP189_LOG_SALT=1 and measures
# what a browser sends to it, so the tokens describe that board.
USB_IFACE="cdc+hid"
USB_CARRIES="log+ctaphid"
USB_HOST="cdc_acm+hidraw"
USB_RUNS_ON="exp189"
usb_check

command -v python3 > /dev/null && pass "python3 present" \
    || { fail "python3 present" "needed for the server and the analysis"; exit 1; }

# The arithmetic, before any board or browser is asked to agree with it.
#
# exp191 shipped a lifted module twice with a missing import; it died in 0.3 s
# on a board while a retry loop said "nobody pressed". An extraction is not
# finished until something runs it.
if python3 salt.py --selftest > /dev/null 2>&1; then
    pass "salt.py's candidates are distinguishable (selftest)"
else
    fail "salt.py --selftest" "run python3 salt.py --selftest to see which assertion"
fi

# The dependency that makes the whole experiment possible: exp189's default
# build prints the salt's *length*, and this needs its bytes.
FW=../exp189-the-same-salt-twice
grep -q 'EXP189_LOG_SALT' "$FW/build.rs" 2>/dev/null \
    && pass "exp189 has the EXP189_LOG_SALT build flag this depends on" \
    || fail "exp189 has EXP189_LOG_SALT" "without it the board never says which salt arrived"
grep -q 'cfg(log_salt)' "$FW/src/main.rs" 2>/dev/null \
    && pass "and the firmware prints the salt behind it" \
    || fail "the firmware prints the salt behind the flag" "the flag would do nothing"

# In pieces, because the log ring has a fixed line width and a 32-byte salt in
# hex does not fit one. The first capture here carried 28 of 32 bytes and one
# nibble — enough to name the salt, not enough to be it — and this is that fix
# as a check, so a regression is caught in the source rather than in a run.
grep -q 'salt in \[{}\.\.{}\]' "$FW/src/main.rs" 2>/dev/null \
    && pass "and prints it in pieces, so the ring's line width cannot truncate it" \
    || fail "the firmware prints the salt in pieces" \
            "one line of 64 hex characters does not fit the log ring"

# The three contract corrections this experiment bought, each as a flag that
# still exists. Losing one silently would put the browser back where it started
# — stopped before the LED ever lit.
for f in EXP189_ADVERTISE_UV EXP189_SELECTION EXP189_ADVERTISE_PIN; do
    grep -q "$f" "$FW/build.rs" 2>/dev/null \
        && pass "exp189 still has the $f flag this experiment bought" \
        || fail "exp189 has $f" "without it a browser stops before the board's LED lights"
done

# And the fourth, which is not a flag: CTAP 2.1 requires `alg` on a
# key-agreement COSE_Key and exp189 shipped without it. Chrome parses strictly.
grep -q 'COSE_ECDH_ES_HKDF_256' "$FW/src/main.rs" 2>/dev/null \
    && pass "and its key-agreement COSE_Key names its algorithm, as CTAP 2.1 requires" \
    || fail "the key-agreement key has alg" "Chrome stops at the tunnel without it"
grep -q 'hmac_secret_output' "$FW/src/main.rs" && ! grep -q 'log!.*hmac_secret_output' "$FW/src/main.rs" \
    && pass "and never prints the output, which is the key rather than the salt" \
    || fail "the output is not logged" "a salt is not a secret; the output is"

# The origin. WebAuthn refuses file:// and refuses a non-local host over plain
# http, so this must bind localhost and nothing else.
grep -q '127.0.0.1' serve.py \
    && pass "the server binds 127.0.0.1, the one plain-http origin WebAuthn allows" \
    || fail "the server binds 127.0.0.1" "any other host needs https before a browser will run"

# The page must ask for prf, and must ask twice with the two verification
# settings — one call cannot show a divergence.
grep -q 'prf: {eval: {first:' page/index.html \
    && pass "the page evaluates prf rather than only enabling it" \
    || fail "the page evaluates prf" "enabling it returns no bytes on a security key"
for uv in discouraged required; do
    grep -q "evaluate(\"$uv\")" page/index.html \
        && pass "the page can evaluate with userVerification: $uv" \
        || fail "the page evaluates with $uv" "the UV divergence needs both"
done

# The pipeline, on a session that never happened, so a broken analyser is found
# before somebody spends three presses on it.
FIX=$(mktemp -d)
python3 - "$FIX" <<'PY'
import hashlib, json, sys
d = sys.argv[1]
inp = b"exp192 prf input"
salt = hashlib.sha256(b"WebAuthn PRF\x00" + inp).digest().hex()
with open(f"{d}/t.json", "w") as f:
    f.write(json.dumps({"step": "create", "prf": {"enabled": True}, "prfInput": inp.decode(),
                        "rpId": "localhost", "userAgent": "fixture"}) + "\n")
    for uv, out in (("discouraged", "aa"), ("required", "bb")):
        f.write(json.dumps({"step": "get", "userVerification": uv,
                            "prfFirstHex": out * 32, "prfInput": inp.decode()}) + "\n")
with open(f"{d}/b.log", "w") as f:
    for uv in ("false", "true"):
        f.write(f"[ 1 ms]   hmac-secret: 32B salt in, 32B out, UV={uv}\n")
        f.write(f"[ 1 ms]   hmac-secret: salt in = {salt}\n")
PY
if python3 analyse.py "$FIX/t.json" "$FIX/b.log" > "$FIX/a.json" 2>/dev/null \
   && python3 verify.py "$FIX/a.json" > /dev/null 2>&1; then
    pass "analyse.py and verify.py agree on a fabricated session"
else
    fail "the pipeline runs" "python3 analyse.py then verify.py on a fixture"
fi

# And a session where the salt is none of the candidates must FAIL, or the
# central rule is decoration. A verifier that cannot refuse cannot rule.
sed 's/"salt in = [0-9a-f]*"/"salt in = 00"/' /dev/null 2>/dev/null || true
python3 - "$FIX" <<'PY'
import re, sys
d = sys.argv[1]
s = open(f"{d}/b.log").read()
open(f"{d}/b-bad.log", "w").write(re.sub(r"salt in = [0-9a-f]+", "salt in = " + "11" * 32, s))
PY
if python3 analyse.py "$FIX/t.json" "$FIX/b-bad.log" > "$FIX/a-bad.json" 2>/dev/null \
   && ! python3 verify.py "$FIX/a-bad.json" > /dev/null 2>&1; then
    pass "and refuses a session whose salt matches no candidate"
else
    fail "the verifier refuses an unmatched salt" "then naming the derivation proves nothing"
fi
rm -rf "$FIX"

# Then on whatever the real run left, if it has been run.
if [[ -f analysis.json && -f crosscheck.json ]]; then
    echo "      ruling on analysis.json and crosscheck.json"
    python3 verify.py analysis.json crosscheck.json || FAILED=1
elif [[ -f analysis.json ]]; then
    echo "      ruling on analysis.json (no cross-check has been run)"
    python3 verify.py analysis.json || FAILED=1
else
    echo "SKIP  no analysis.json — ./run.sh has not been run on this checkout"
fi

# The cross-check leans on one inference and must keep saying so: the salt it
# feeds libfido2 is reconstructed from the named candidate, not read out of the
# truncated log line. Burying that would turn a stated assumption into a hidden
# one.
if [[ -f crosscheck.json ]]; then
    python3 -c 'import json,sys; sys.exit(0 if json.load(open("crosscheck.json")).get("salt_named") else 1)' \
        && pass "the cross-check records which candidate its salt came from" \
        || fail "crosscheck.json names its salt candidate" \
                "the reconstruction would be an inference nobody can see"
fi

for e in exp173 exp174 exp175 exp189 exp191; do
    grep -q "$e" README.md 2>/dev/null \
        && pass "the README names $e" \
        || fail "the README names $e" "this experiment builds directly on $e"
done

exit "$FAILED"
