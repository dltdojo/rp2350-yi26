#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp176 quick check — non-interactive.
#
# No firmware of its own. It compares two self-descriptions and two
# attestations. The comparison and the board's attestation are checkable from
# checked-in data with no board attached; if a board and a commercial key are
# present, it re-probes them live and confirms the record still holds.
#
# What it cannot check unattended is registering on the commercial key — that
# needs a PIN a person types. So the key's attestation is checked from the
# checked-in yubikey-cred.out when it is there, and its absence is reported, not
# failed: the getInfo comparison already establishes the identity difference
# (an all-zero AAGUID against a real one), and the attestation only makes it
# concrete.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

# getInfo needs nobody; the attestation half needs a PIN and a touch on the key.
PRESENCE=2
presence_check

# No firmware of its own; the tokens describe exp174, the board it questions.
USB_IFACE="cdc+hid"
USB_CARRIES="log+ctaphid"
USB_HOST="cdc_acm+hidraw"
USB_RUNS_ON="own"
usb_check

command -v python3 > /dev/null && pass "python3 present" \
    || { fail "python3 present" "needed to probe and compare"; exit 1; }
command -v fido2-token > /dev/null && pass "fido2-token present (the host's own tool)" \
    || fail "fido2-token present" "install libfido2-tools"

# --- the checked-in record parses and says what the README says ----------
for f in board.json yubikey.json comparison.json board-attestation.json; do
    [[ -f "$f" ]] && pass "$f is checked in" || fail "$f is checked in" "the record is incomplete"
done

# The categorisation is the claim, so the counts are asserted, not just printed.
python3 - <<'PY'
import json, sys
d = json.load(open("comparison.json"))
c = d["counts_by_kind"]
ok = True
def check(cond, msg):
    global ok
    print(("PASS  " if cond else "FAIL  ") + msg)
    ok = ok and cond
check(c.get("code", 0) >= 2 * (c.get("certification", 0) + c.get("silicon", 0)),
      "most of the gap is code the board could write (%d code vs %d certification/silicon)"
      % (c.get("code", 0), c.get("certification", 0) + c.get("silicon", 0)))
check(c.get("certification", 0) >= 1,
      "at least one difference is certification the chip cannot anchor (the AAGUID)")
check(any(g["capability"].startswith("aaguid") and g["kind"] == "certification"
          for g in d["gap"]),
      "the AAGUID difference is classified as certification, not code")
check("FIDO_2_0" in d.get("board_versions", []),
      "the board still claims FIDO_2_0 — a real, if minimal, CTAP2 device")
sys.exit(0 if ok else 1)
PY
[[ $? -eq 0 ]] || FAILED=1

# --- the board's attestation is self attestation, all-zero AAGUID --------
python3 - <<'PY'
import json, sys
a = json.load(open("board-attestation.json"))
ok = True
def check(cond, msg):
    global ok
    print(("PASS  " if cond else "FAIL  ") + msg); ok = ok and cond
check(a["format"] == "packed", "the board attests in the packed format")
check(a["aaguid_is_zero"], "its AAGUID is all zero, which self attestation requires")
check(not a["has_certificate_chain"], "it carries no certificate chain — it vouches only for itself")
check("UP" not in a["flags_set"], "the UP=none build set no user-presence bit (flags %s)" % a["flags"])
sys.exit(0 if ok else 1)
PY
[[ $? -eq 0 ]] || FAILED=1

# --- the commercial key's attestation, if a person ran drive.sh ----------
if [[ -f yubikey-attestation.json ]]; then
    if python3 -c "import json,sys; a=json.load(open('yubikey-attestation.json')); sys.exit(0 if a['has_certificate_chain'] else 1)"; then
        pass "the commercial key's attestation carries an x5c certificate chain — the board's does not"
    else
        fail "the key's attestation has a certificate chain" "re-capture it via the browser page"
    fi
    # The identity is in the certificate, not the authData AAGUID: fido-u2f
    # zeroes that field by spec, so both devices show zero there. The cert is
    # the real discriminator, and getInfo separately shows the key's non-zero
    # AAGUID claim.
    [[ -f yubikey-cert-identity.txt ]] && grep -qi 'yubico' yubikey-cert-identity.txt         && pass "the certificate names its issuer — a CA the board has no counterpart to"         || fail "the certificate identity is recorded" "yubikey-cert-identity.txt missing or empty"
else
    echo "SKIP  the commercial key's attestation is not captured yet — open serve.py's page and register the key (a touch), or run ./drive.sh"
fi

# --- live re-probe, if the devices are here ------------------------------
BOARD="$(fido2-token -L 2>/dev/null | grep -i 'deadline nobody mentioned' | head -1 | cut -d: -f1)"
if [[ -n "$BOARD" ]]; then
    if python3 probe.py "$BOARD" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d['aaguid_is_zero'] and 'FIDO_2_0' in d['versions'] else 1)"; then
        pass "a live board re-probes to the same all-zero AAGUID, FIDO_2_0 device"
    else
        fail "the live board matches the record" "getInfo drifted from board.json"
    fi
else
    echo "SKIP  no exp174 board attached; the checked-in board.json stands"
fi

KEY="$(fido2-token -L 2>/dev/null | grep hidraw | grep -vi 'rp2350-yi26' | head -1 | cut -d: -f1)"
if [[ -n "$KEY" ]]; then
    if python3 probe.py "$KEY" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if not d['aaguid_is_zero'] else 1)"; then
        pass "a live commercial key re-probes to a real, non-zero AAGUID"
    else
        fail "the live key matches the record" "getInfo drifted from yubikey.json"
    fi
else
    echo "SKIP  no commercial key attached; the checked-in yubikey.json stands"
fi

# --- the argument it makes -----------------------------------------------
grep -q 'exp175' README.md \
    && pass "the README ties the one uncloseable gap to exp175's finding" \
    || fail "the README names exp175" "the certification gap is exp175's gap"

exit "$FAILED"
