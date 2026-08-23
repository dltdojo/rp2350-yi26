#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp175 step A, unattended: does a credential outlive the firmware?
#
#   ./survive.sh
#
# Uses the EXP174_UP=none build so no finger is needed — the claim under test is
# not about presence, it is about where the secret lives. Register a credential,
# reflash the board to a DIFFERENT experiment (wiping the key), reflash exp174,
# and log in with the credential from before the wipe. It works because the
# credential was never in the board's state; the image carries the secret and
# the reflash put it back.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

NONE=../exp174-a-deadline-nobody-mentioned/target/exp174-none-fixed.uf2
OTHER=../exp127-host-owns-the-led/target/exp127-host-owns-the-led.uf2
say() { printf '>>> %s\n' "$*"; }

[[ -f "$NONE" ]]  || { say "build exp174 (EXP174_UP=none) first"; exit 1; }
[[ -f "$OTHER" ]] || { say "build exp127 first, or edit OTHER"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
flash() { yi26 bootsel >/dev/null 2>&1; sleep 2; yi26 pflash "$1" >/dev/null 2>&1; sleep "${2:-7}"; }
ours() { fido2-token -L 2>/dev/null | grep -i 'a deadline nobody mentioned' | head -1 | cut -d: -f1; }

say "flash exp174 (UP=none) and register a credential"
flash "$NONE"
DEV="$(ours)"; [[ -n "$DEV" ]] || { say "the board did not come back as exp174"; exit 1; }
printf '%s\n%s\n%s\n%s\n' "$(head -c32 /dev/urandom|base64)" example.test somebody \
    "$(head -c16 /dev/urandom|base64)" > "$TMP/c.in"
if fido2-cred -M "$DEV" < "$TMP/c.in" > "$TMP/c.out" 2>"$TMP/e"; then
    CRED="$(sed -n 5p "$TMP/c.out")"
    say "registered ${CRED:0:32}..."
else
    say "registration failed: $(cat "$TMP/e")"; exit 1
fi

say "reflash to exp127 — a different firmware. The key is gone:"
flash "$OTHER" 5
if [[ -z "$(ours)" ]]; then
    say "  no exp174 FIDO device present (correct — it was overwritten)"
else
    say "  exp174 is somehow still here — the wipe did not take"; exit 1
fi

say "reflash exp174 — the SAME image, and log in with the OLD credential"
flash "$NONE"
DEV="$(ours)"
printf '%s\n%s\n%s\n' "$(head -c32 /dev/urandom|base64)" example.test "$CRED" > "$TMP/a.in"
if fido2-assert -G "$DEV" < "$TMP/a.in" > "$TMP/a.out" 2>"$TMP/e"; then
    say "ACCEPTED — the credential survived a full firmware wipe."
    say "It was never in the board; it is a function of the image, which was restored."
else
    say "refused: $(cat "$TMP/e")"
    say "(no-credentials here would mean the secret differs between builds —"
    say " itself worth recording)"
    exit 1
fi
