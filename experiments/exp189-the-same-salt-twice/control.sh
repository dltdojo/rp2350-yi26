#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
#
# exp189 — the ready-made version, as the control. Needs a board and 3 presses.
#
# `age` plus `age-plugin-fido2-hmac` already does what exp191 builds by hand.
# This runs it against this board and writes down what happened, because
# exp178's rule is that hand-rolling *after* measuring the alternative is a
# decision and hand-rolling *instead of* measuring it is a reflex.
#
#   ./control.sh        two solid LEDs; press at both
#   ./control.sh 1      the same, keeping a separate identity file
#
# What it has to show is a stronger sentence than the rest of this experiment
# can produce. `fido2-assert` printing thirty-two bytes says something came
# back. `age` opening a file, byte-identical, says **a tool that does not know
# this board exists opened a file with its key**.
#
# And a refusal is the finding, not the failure. This build has no PIN and no
# resident credentials by choice. If the plugin demands either, what it demands
# and in what words is what gets recorded — check.sh never gates on the plugin
# succeeding, and the experiment does not grow a PIN to make somebody else's
# tool happy.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

say()  { printf '>>> %s\n' "$*" >&2; }
note() { printf '    %s\n' "$*" >&2; }

W=work/control
rm -rf "$W"; mkdir -p "$W"

PLUGIN=./bin/age-plugin-fido2-hmac
AGE=./bin/age
for t in "$PLUGIN" "$AGE"; do
    [[ -x "$t" ]] || { echo "$t is missing — run ./setup.sh" >&2; exit 1; }
done
# The plugin has to be on PATH under its own name or age will not find it.
export PATH="$PWD/bin:$PATH"

# Three presses are three presses. A board with no secret refuses every one of
# them in a tenth of a second, so find that out before asking for the first —
# the same guard roundtrip.sh grew after seven were spent that way.
if [[ "$(yi26 log --seconds 4 2>/dev/null | grep -c 'UNPROVISIONED')" -gt 0 ]]; then
    echo "this board has no secret — it is blinking two-flashes-then-a-pause." >&2
    echo "pull the cable and put it back, then run this again." >&2
    exit 1
fi

# The plugin's one question, in its own words:
#
#     Are you fine with having a separate identity (better privacy)?
#      (press [1] for "yes" or [2] for "no")
#
# **2 by default**, and the reason is exp191's shape rather than privacy. With
# no separate identity the credential travels in the ciphertext header and
# `age -d -j fido2-hmac` opens the file carrying no key material at all — which
# is the sentence exp191's wrapper wants to be able to make: *no key, so no
# vault; the board is the whole lock*. Choosing 1 is the better-privacy answer
# and leaves an identity file that `age -d -i` needs, so both are run.
IDENTITY_CHOICE="${1:-2}"
case "$IDENTITY_CHOICE" in 1|2) ;; *) echo "usage: ./control.sh [1|2]" >&2; exit 64 ;; esac

# Three, and the count came from the transcript rather than from the help.
# `-g` asks for a touch, then asks its one question, then **asks for a touch
# again** — once to make the credential and once to derive the key from it. The
# help calls the whole thing "interactive" and says nothing about two.
say "three solid-LED windows follow. Press BOOTSEL at every one of them."
say "the first two are both inside -g; the third opens the file."
say "plugin $("$PLUGIN" --version), age $("$AGE" --version)"

# ---------------------------------------------------------------- 1. register
#
# The board's own log is captured across the whole run, so a refusal can say
# which of two things it was. Without it, "nobody pressed" and "the device said
# no" are the same line on the host.
# A plain `&`, not `( ... & )`: the subshell form detaches the job, so `$!` is
# never set — which under `set -u` killed this script before it asked for the
# first press. The detached form also outlives nothing: an earlier probe lost
# its whole capture that way when the parent finished first.
yi26 log --seconds 240 > "$W/board.log" 2>/dev/null &
LOGGER=$!
sleep 1

say "1/3 and 2/3  age-plugin-fido2-hmac -g — PRESS BOOTSEL TWICE"
GEN_OK=1
CONTROL_TIMEOUT=120 python3 control_drive.py "$W/generate.transcript" \
    "$IDENTITY_CHOICE" -- "$PLUGIN" -g > "$W/generate.raw" 2> "$W/generate.err" || GEN_OK=0

# A pty has one stream, so the tool's prompts and its output arrive interleaved
# and `> identity.txt` catches both — the first run of this wrote the questions
# into the identity file. Everything is pulled back out by shape instead.
# `-` is inside a plugin recipient, not after it. The first version stopped at
# it and pulled out `age1fido2` from `age1fido2-hmac1qqp8vf3...`, which age then
# refused as malformed — a whole run's presses spent on a broken nine-character
# string. Plugin recipients are `age1<plugin-name>1<data>` and the name has a
# hyphen in it.
RECIPIENT="$(grep -oE 'age1[0-9a-z-]+' "$W/generate.raw" | head -1)"
grep -oE 'AGE-PLUGIN-FIDO2-HMAC-[0-9A-Za-z]+' "$W/generate.raw" > "$W/identity.txt" || true
[[ -s "$W/identity.txt" ]] || rm -f "$W/identity.txt"

if [[ "$GEN_OK" -eq 1 && -n "$RECIPIENT" ]]; then
    note "generated; recipient $RECIPIENT"
    [[ -f "$W/identity.txt" ]] && note "and a separate identity file"
else
    GEN_OK=0
    note "REFUSED or incomplete — the transcript is the finding:"
    sed 's/^/      /' "$W/generate.transcript" >&2 2>/dev/null
fi

# ------------------------------------------------------------------ 2. encrypt
#
# This half needs no board at all, which is the shape exp191 wants: without -s
# the plugin derives an X25519 keypair, so encryption is offline and only
# decryption asks for a finger.
PLAIN="$W/plain.txt"
printf 'exp189 control: the ready-made version, %s\n' "$(date -u +%FT%TZ)" > "$PLAIN"
ENC_OK=0
if [[ -n "$RECIPIENT" ]]; then
    if "$AGE" -r "$RECIPIENT" -o "$W/secret.enc" "$PLAIN" 2> "$W/encrypt.err"; then
        ENC_OK=1
        note "encrypted to $RECIPIENT with no board attached ($(stat -c%s "$W/secret.enc") bytes)"
    else
        note "encryption REFUSED: $(cat "$W/encrypt.err")"
    fi
fi

# ------------------------------------------------------------- 3. decrypt, twice
#
# Once with the identity file and once with the magic identity, because the
# second is the form a wrapper wants: `age -d -j fido2-hmac` carries no file.
dec() {
    local label="$1"; shift
    say "$label — PRESS BOOTSEL"
    if timeout 90 "$AGE" "$@" "$W/secret.enc" > "$W/$label.out" 2> "$W/$label.err"; then
        if cmp -s "$PLAIN" "$W/$label.out"; then
            note "opened, and byte-identical to what went in"
            return 0
        fi
        note "opened, but the bytes are NOT the ones that went in"
        return 1
    fi
    note "REFUSED: $(tail -1 "$W/$label.err")"
    return 1
}

DEC_I=0; DEC_J=0
if [[ "$ENC_OK" -eq 1 ]]; then
    if [[ -f "$W/identity.txt" ]]; then
        dec "3of3-with-identity-file" -d -i "$W/identity.txt" && DEC_I=1
    else
        dec "3of3-magic-identity" -d -j fido2-hmac && DEC_J=1
    fi
fi

# The presses are done, so the log has everything this run can produce. Waiting
# out the remaining window would just make somebody watch a timer.
sleep 2
kill "$LOGGER" 2>/dev/null
wait "$LOGGER" 2>/dev/null || true

# Every press the board actually saw. "Nobody pressed" and "the device said no"
# are different findings and the host cannot tell them apart on its own.
PRESSES="$(grep -c 'presence: BOOTSEL read low' "$W/board.log" 2>/dev/null || echo 0)"
RP="$(grep -oE 'rp="[^"]*"' "$W/board.log" 2>/dev/null | head -1)"
MC="$(grep -oE 'makeCredential: .*' "$W/board.log" 2>/dev/null | head -1)"

j() { python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "${1-}"; }
cat > control.json <<JSON
{
  "age_version": $(j "$("$AGE" --version)"),
  "plugin_version": $(j "$("$PLUGIN" --version 2>&1 | head -1)"),
  "generated": $([[ "$GEN_OK" -eq 1 ]] && echo true || echo false),
  "recipient": $(j "$RECIPIENT"),
  "encrypted_without_board": $([[ "$ENC_OK" -eq 1 ]] && echo true || echo false),
  "separate_identity_answer": $(j "$IDENTITY_CHOICE"),
  "decrypted_with_identity_file": $([[ "$DEC_I" -eq 1 ]] && echo true || echo false),
  "decrypted_with_magic_identity": $([[ "$DEC_J" -eq 1 ]] && echo true || echo false),
  "presses_the_board_saw": ${PRESSES:-0},
  "make_credential_line": $(j "$MC"),
  "rp_id_the_plugin_chose": $(j "$RP")
}
JSON
say "wrote control.json; the prompt sequence is in $W/generate.transcript"
python3 -c '
import json
d = json.load(open("control.json"))
for k, v in d.items():
    print(f"      {k}: {v}")
'
