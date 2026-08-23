#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp177 quick check — non-interactive.
#
# No firmware of its own, and the firmware it measures is not this
# repository's. What can be checked with nothing attached is the record: the
# pinned image, what reading it says, and what the board said when it ran.
# What needs the board is a live re-probe, and it is reported as SKIP rather
# than failed when the board has been put back to exp174 — which is where it
# should end up.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

# Flashing it needs nobody — a board running exp174 reboots itself. Getting
# back needs a hand on BOOTSEL, because pico-fido answers no 1200-baud touch of
# ours. That one action is the level.
PRESENCE=2
presence_check

# Four interfaces, none of them chosen here: two HID (CTAPHID and a keyboard),
# a CCID smart-card interface, and a vendor one. On this host only the HID pair
# is claimed by a driver — nothing binds the other two without pcscd, which
# this experiment deliberately does not install.
USB_IFACE="hid+hid+ccid+vendor"
USB_CARRIES="ctaphid+keystrokes+commands"
USB_HOST="hid"
USB_RUNS_ON="third-party"
usb_check

command -v python3 > /dev/null && pass "python3 present" \
    || { fail "python3 present" "needed to read and compare"; exit 1; }
command -v fido2-token > /dev/null && pass "fido2-token present (the host's own tool)" \
    || fail "fido2-token present" "install libfido2-tools"

# --- somebody else's binary, and the shape of that fact -------------------
grep -q 'GPL-3.0' README.md && grep -q 'AGPL' README.md \
    && pass "the README says what licence the measured firmware is under" \
    || fail "the licences are stated" "pico-fido is GPL-3.0 over an AGPL-3.0 SDK"

TRACKED="$(cd ../.. && git ls-files experiments/exp177-the-same-chip-somebody-elses-decisions/firmware | wc -l)"
[[ "$TRACKED" -eq 0 ]] \
    && pass "no third-party binary is committed to this repository" \
    || fail "no third-party binary is committed" "$TRACKED files under firmware/ are tracked"

if [[ -f firmware/pico_fido_pico2-8.0.uf2 ]]; then
    ./setup.sh > /dev/null \
        && pass "the image on disk is the one setup.sh pins, by SHA-256" \
        || fail "the pinned image verifies" "the download does not match the recorded hash"
else
    echo "SKIP  the image is not downloaded — run ./setup.sh (needs the network once)"
fi

# --- reading the image before any board was asked to take it -------------
[[ -f preflight.json ]] && pass "preflight.json is checked in" \
    || fail "preflight.json is checked in" "run ./preflight.py firmware/*.uf2"

python3 - <<'PY'
import json, sys
p = json.load(open("preflight.json"))
ok = True
def check(cond, msg):
    global ok
    print(("PASS  " if cond else "FAIL  ") + msg); ok = ok and cond
fams = {f["name"]: f for f in p["families"]}
check("RP2350 Arm Secure" in fams,
      "the image is for this chip: %d blocks of the RP2350 Arm Secure family"
      % fams.get("RP2350 Arm Secure", {}).get("blocks", 0))
check(len(p["beyond_flash"]) == 1 and p["beyond_flash"][0]["addr"] == "0x10ffff00",
      "and it carries one block asking for 0x10ffff00 — 15 MiB into a 4 MiB part")
check(p["has_boot_block_at_offset_0"],
      "there is a boot block at flash offset 0, so it is bootable at all")
check(p["image"]["slots_of_exp142"] > 4,
      "it is %.1f× exp142's 64 KiB A/B slot — it would not fit in one"
      % p["image"]["slots_of_exp142"])
sys.exit(0 if ok else 1)
PY
[[ $? -eq 0 ]] || FAILED=1

# --- what the board said when it was running it --------------------------
for f in picofido.json algorithms.json comparison.json picofido-attestation.json presence.json; do
    [[ -f "$f" ]] && pass "$f is checked in" || fail "$f is checked in" "the record is incomplete"
done

python3 compare.py > /dev/null && pass "the comparison re-runs from the checked-in record" \
    || fail "compare.py runs" "the record and exp176's list disagree"

python3 - <<'PY'
import json, sys
c = json.load(open("comparison.json"))
a = json.load(open("picofido-attestation.json"))
g = json.load(open("algorithms.json"))
pr = json.load(open("presence.json"))
ok = True
def check(cond, msg):
    global ok
    print(("PASS  " if cond else "FAIL  ") + msg); ok = ok and cond

n = c["counts"]
check(n["closed"] == 9 and n["open"] == 1,
      "%d of exp176's %d code differences were written by another team on this "
      "chip; %d was not" % (n["closed"], n["code_in_exp176"], n["open"]))
check(c["open"][0]["capability"] == "eddsa",
      "the one it did not write is eddsa — it offers three ECDSA curves instead")
check([x["name"] for x in g["algorithms"]] == ["ES256", "ES384", "ES512"],
      "and that ruling came from the device's own COSE identifiers, not from "
      "libfido2 printing `unknown`")

# The identity axis, which is what the road sent this experiment to look at.
check(a["aaguid"] == g["aaguid"] and a["aaguid"] != "0" * 32,
      "it claims a real AAGUID (%s), in getInfo and in the attestation alike"
      % a["aaguid"])
check(not a["has_certificate_chain"],
      "and carries no certificate chain — the claim without the authority, "
      "which is exactly the half exp176 called certification")
check(a["format"] == "packed", "the attestation format is packed, as the board's is")

# exp171's rule, asked of firmware nobody here wrote.
check(pr["all_succeeded"] and pr["all_claimed_up"],
      "every credential it made claimed the user-presence bit")
check(pr["slowest_ms"] is not None and pr["slowest_ms"] < 2000,
      "and the slowest took %s ms, with nobody asked to press anything"
      % pr["slowest_ms"])
sys.exit(0 if ok else 1)
PY
[[ $? -eq 0 ]] || FAILED=1

# --- a live re-probe, if the board is still running it --------------------
DEV="$(fido2-token -L 2>/dev/null | grep -i 'pico key' | head -1 | cut -d: -f1)"
if [[ -n "$DEV" ]]; then
    if python3 ../exp176-the-same-question-of-two-devices/probe.py "$DEV" \
        | python3 -c "
import json,sys
live = json.load(sys.stdin); rec = json.load(open('picofido.json'))
sys.exit(0 if live['aaguid'] == rec['aaguid'] and live['versions'] == rec['versions'] else 1)"; then
        pass "a live pico-fido re-probes to the same record"
    else
        fail "the live device matches the record" "getInfo drifted from picofido.json"
    fi
else
    echo "SKIP  no pico-fido attached — the board is presumably back on exp174, which is where it belongs"
fi

# --- the argument it makes ------------------------------------------------
grep -q 'exp176' README.md && pass "the README rules on exp176's list, not one of its own" \
    || fail "the README names exp176" "the list has to be somebody else's"
grep -q 'exp175' README.md && pass "the README ties the identity half to exp175" \
    || fail "the README names exp175" "Secure Lock is exp175's gap"
grep -q 'exp171' README.md && pass "the README ties the presence finding to exp171" \
    || fail "the README names exp171" "the user-presence rule is exp171's"

exit "$FAILED"
