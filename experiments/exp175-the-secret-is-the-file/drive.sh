#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp175 — the two demonstrations the check cannot do alone.
#
#   ./drive.sh
#
# The offline forgery is proven by check.sh with no board. This shows the two
# hardware facts behind it, and both need a person:
#
#   A  a credential outlives the firmware — register it, reflash the board to a
#      DIFFERENT experiment, reflash exp174 back, and log in with the same
#      credential. The secret was never in "this running board"; it is in the
#      image, and the image put it back.
#
#   B  the same secret reads off a live board — exp141's PICOBOOT port, which a
#      browser drives, dumps flash and the secret is at the address forge.py
#      used. This half is a pointer to exp141's page, not a script: reading
#      flash from a browser is exp141's subject.
#
# Everything unattended is in check.sh. This is the part with a finger in it.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

EXP174=../exp174-a-deadline-nobody-mentioned
KEY_UF2="$EXP174/target/exp174-button.uf2"
OTHER_UF2="../exp127-host-owns-the-led/target/exp127-host-owns-the-led.uf2"

say() { printf '>>> %s\n' "$*"; }

[[ -f "$KEY_UF2" ]] || { say "build exp174 first"; exit 1; }

say "A — does a credential outlive the firmware?"
say "    flashing exp174 (the key)"
yi26 bootsel >/dev/null 2>&1; sleep 2
yi26 pflash "$KEY_UF2" >/dev/null 2>&1; sleep 7

DEV="$(fido2-token -L 2>/dev/null | head -1 | cut -d: -f1)"
[[ -n "$DEV" ]] || { say "no FIDO device came back"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '%s\n%s\n%s\n%s\n' \
    "$(head -c 32 /dev/urandom | base64)" "example.test" "somebody" \
    "$(head -c 16 /dev/urandom | base64)" > "$TMP/cred.in"
say "    register a credential (press BOOTSEL when the tool waits)"
if fido2-cred -M "$DEV" < "$TMP/cred.in" > "$TMP/cred.out" 2>"$TMP/err"; then
    CRED="$(sed -n '5p' "$TMP/cred.out")"
    say "    made credential ${CRED:0:24}..."
else
    say "    registration failed: $(cat "$TMP/err")"; exit 1
fi

if [[ -f "$OTHER_UF2" ]]; then
    say "    reflashing the board to exp127 — a DIFFERENT firmware, wiping the key"
    yi26 bootsel >/dev/null 2>&1; sleep 2
    yi26 pflash "$OTHER_UF2" >/dev/null 2>&1; sleep 5
    say "    the board is now exp127; there is no FIDO device:"
    fido2-token -L 2>&1 | sed 's/^/        /'
else
    say "    (exp127's UF2 not built; using yi26 nuke to erase instead)"
    yi26 bootsel >/dev/null 2>&1; sleep 2
    yi26 nuke >/dev/null 2>&1; sleep 3
fi

say "    reflashing exp174 — the SAME image, which carries the same secret"
yi26 bootsel >/dev/null 2>&1; sleep 2
yi26 pflash "$KEY_UF2" >/dev/null 2>&1; sleep 7
DEV="$(fido2-token -L 2>/dev/null | head -1 | cut -d: -f1)"

CDH="$(head -c 32 /dev/urandom | base64)"
printf '%s\n%s\n%s\n' "$CDH" "example.test" "$CRED" > "$TMP/assert.in"
say "    log in with the credential from BEFORE the wipe (press BOOTSEL)"
if fido2-assert -G "$DEV" < "$TMP/assert.in" > "$TMP/assert.out" 2>"$TMP/err"; then
    say "    ACCEPTED — the credential survived a firmware wipe."
    say "    It was never in the board's state; it is a function of the image."
else
    say "    refused: $(cat "$TMP/err")"
    say "    (if this says no-credentials, the secret differs between builds —"
    say "     which would itself be worth recording)"
fi

echo
say "B — the same secret reads off a live board"
say "    forge.py used the secret at this address in the image:"
python3 unpack.py "$KEY_UF2" "not a secret. this is a test key" | sed 's/^/        /'
say "    to read it off the board itself, put it in BOOTSEL and open exp141:"
say "        ../exp141-two-doors-into-the-bootrom/picoboot.html"
say "    dump flash and look at that address. Reading flash from a browser is"
say "    exp141's subject, which is why this half points there instead of repeating it."
