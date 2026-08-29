#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp189 — seven presses and one deliberate refusal to press.
#
# The client is libfido2's own, on purpose: the point of this rung is that
# somebody else's tool asks for a key and accepts what comes back. exp190 uses
# this repository's own CTAP client instead, and says there why.
#
#   ./roundtrip.sh          press BOOTSEL when it asks; do NOT press for the last case
#
# Writes roundtrip.json, which verify.py rules on. Nothing here decides whether
# the run passed — this script records, verify.py judges, and the two are
# separate files so that a transcript can be argued with after the board has
# been unplugged.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

# Both to **stderr**: assert_once's answer is captured with $(...), and a
# progress line printed to stdout would end up inside the key. Which is exp174's
# lesson about instruments, met before the seven presses rather than after them.
say()  { printf '>>> %s\n' "$*" >&2; }
note() { printf '    %s\n' "$*" >&2; }

# ---------------------------------------------------------------- the salts
#
# Fixed, and derived from a sentence rather than from /dev/urandom, so that two
# transcripts taken on different days are comparable. A salt is not a secret:
# the client chooses it, sends it (encrypted only because the tunnel encrypts
# everything), and exp190 stores it in the clear next to the file it opens.
b64sha() { python3 -c 'import base64,hashlib,sys;print(base64.b64encode(hashlib.sha256(sys.argv[1].encode()).digest()).decode())' "$1"; }
S1="$(b64sha 'exp189 salt one')"
S2="$(b64sha 'exp189 salt two')"

RP="example.test"

DEV="$(fido2-token -L 2>/dev/null | grep -i 'same salt' | head -1 | cut -d: -f1)"
[[ -n "$DEV" ]] || DEV="$(fido2-token -L 2>/dev/null | head -1 | cut -d: -f1)"
[[ -n "$DEV" ]] || { echo "no FIDO device — is a board running exp189?" >&2; exit 1; }

# `work/` rather than a temp directory that is deleted on exit: the unattended
# half of this experiment needs credential A, and re-making one costs a press.
# Git-ignored, and rewritten by every run.
TMP="work"
# ./bank8.sh leaves boot 2's banner here, and it is the only copy: the banner is
# printed once, at boot, and cannot be asked for again. Wiping it would put the
# `bank8` arm back where it was — no path to a transcript that says which arm it
# is except one that reflashes and destroys the key.
ARMFILE=""
if [[ -f "$TMP/arm.txt" ]]; then
    ARMFILE="$(mktemp)"; cp "$TMP/arm.txt" "$ARMFILE"
fi
rm -rf "$TMP"; mkdir -p "$TMP"
[[ -z "$ARMFILE" ]] || { cp "$ARMFILE" "$TMP/arm.txt"; rm -f "$ARMFILE"; }

# Start from a known boot, and do it by putting `target/exp189.uf2` back.
#
# Two things follow from that and neither is tidiness. The banner is printed
# once, at boot, so a run started against a board that has been up for an hour
# has no line saying which arm produced its bytes — the first transcript this
# script wrote had `key_source: ""` and verify.py refused it, correctly. And
# reflashing is what makes the transcript describe **the image in target/**
# rather than whatever happens to be resident. It costs nobody anything: from
# exp105 on, the 1200-baud touch reboots the board from the host.
# Which arm this run is of, and it is an argument rather than an assumption.
#
# This script used to flash `target/exp189.uf2` unconditionally — so a run
# started against a board carefully provisioned on the `bank8` arm reflashed the
# `constant` one over it, zeroed the SRAM the key came from, and spent seven of
# somebody's presses re-measuring an arm that was already captured. The
# transcript said `arm: key source: constant` and nobody read it until after.
#
#   ./roundtrip.sh              the constant arm, flashed fresh
#   ./roundtrip.sh bank8        the bank8 arm, flashed fresh — needs a cable
#                               pull afterwards before it can do anything
#   ./roundtrip.sh keep         whatever is on the board already, not flashed
ARM="${1:-constant}"
case "$ARM" in
    constant) IMG=target/exp189.uf2 ;;
    bank8)    IMG=target/exp189-bank8.uf2 ;;
    keep)     IMG="" ;;
    *) echo "usage: ./roundtrip.sh [constant|bank8|keep]" >&2; exit 64 ;;
esac

if [[ -n "$IMG" && -f "$IMG" ]]; then
    say "putting $IMG back, so the boot banner is this run's"
    yi26 flash "$IMG" > /dev/null 2>&1 || { echo "flash failed" >&2; exit 1; }
    sleep 3
    DEV="$(fido2-token -L 2>/dev/null | grep -i 'same salt' | head -1 | cut -d: -f1)"
    [[ -n "$DEV" ]] || DEV="$(fido2-token -L 2>/dev/null | head -1 | cut -d: -f1)"
elif [[ -n "$IMG" ]]; then
    echo "$IMG is not built — see Running it" >&2
    exit 1
else
    say "not flashing: running against whatever is already on the board"
fi

# Seven presses are seven presses. A board with no secret refuses every one of
# them in a tenth of a second, so find that out before asking for the first.
if [[ "$(yi26 log --seconds 4 2>/dev/null | grep -c 'UNPROVISIONED')" -gt 0 ]]; then
    echo "this board has no secret — it is blinking two-flashes-then-a-pause." >&2
    echo "pull the cable and put it back, then run this again. Nothing below" >&2
    echo "would have worked, and it would have cost seven presses to find out." >&2
    exit 1
fi

say "seven solid-LED windows follow. Press BOOTSEL at every one of them."
say "device $DEV"
say "the board's own account of which arm this is"
BANNER="$(yi26 log --seconds 6 2>/dev/null)"
printf '%s\n' "$BANNER" | grep -Ei "key source|hmac-secret|gates the arithmetic" | sed 's/^/    /' >&2
KEY_SOURCE="$(printf '%s\n' "$BANNER" | grep -oiE 'key source: *[a-z0-9]+' | tail -1)"
BANNER_FROM="this run's boot"

# The banner from earlier in **this same boot**, when there is one.
#
# The `bank8` arm cannot be flashed into the state it is measured in: flashing
# zeroes the SRAM the key comes from, so the run that records the banner is the
# run that has no key, and the boot that has the key is one whose banner has
# already scrolled past. ./bank8.sh writes that banner down at boot 2 together
# with the board uptime it was read at; it is good here only while the board's
# clock is still ahead of that stamp, because a reboot sends the clock backwards
# and a banner from before a reboot describes a boot that is over.
if [[ -z "$KEY_SOURCE" && -f "$TMP/arm.txt" ]]; then
    AT="$(grep -oE 'captured_at_board_ms [0-9]+' "$TMP/arm.txt" | grep -oE '[0-9]+' | tail -1)"
    NOW="$(printf '%s\n' "$BANNER" | grep -E '^\[ *[0-9]+ ms\] idle:' | grep -oE '^\[ *[0-9]+' | tr -dc '0-9\n' | sort -n | tail -1)"
    [[ -n "$NOW" ]] || NOW="$(yi26 log --seconds 35 2>/dev/null | grep -E '^\[ *[0-9]+ ms\] idle:' | grep -oE '^\[ *[0-9]+' | tr -dc '0-9\n' | sort -n | tail -1)"
    if [[ -n "$AT" && -n "$NOW" && "$NOW" -gt "$AT" ]]; then
        KEY_SOURCE="$(grep -oiE 'key source: *[a-z0-9]+' "$TMP/arm.txt" | tail -1)"
        BANNER_FROM="work/arm.txt, ${AT} ms into this boot; the board is now at ${NOW} ms"
        grep -iE 'key source|device secret|bank 8|enrolled at' "$TMP/arm.txt" | sed 's/^/    /' >&2
        say "banner from $BANNER_FROM"
    elif [[ -n "$AT" && -n "$NOW" ]]; then
        echo "work/arm.txt was stamped at ${AT} ms and the board is at ${NOW} ms —" >&2
        echo "the clock went backwards, so that banner is from a boot that is over." >&2
    fi
fi
if [[ -z "$KEY_SOURCE" ]]; then
    echo "the board did not say which arm it is — refusing to write a transcript that is not evidence" >&2
    exit 1
fi

# ------------------------------------------------------------- make a credential
# $1 label, $2 user name. Leaves $TMP/$1.cred, and echoes the credential id.
make_cred() {
    local label="$1" user="$2"
    printf '%s\n%s\n%s\n%s\n' \
        "$(head -c 32 /dev/urandom | base64)" "$RP" "$user" "$(head -c 16 /dev/urandom | base64)" \
        > "$TMP/$label.in"
    local try
    for try in 1 2; do
        say "$label: fido2-cred -M -h — PRESS BOOTSEL${try:+$([[ $try -eq 2 ]] && echo ' (again — the last window closed)')}"
        if fido2-cred -M -h "$DEV" < "$TMP/$label.in" > "$TMP/$label.cred" 2> "$TMP/$label.err"; then
            break
        fi
        if [[ $try -eq 2 ]] || ! grep -q 'FIDO_ERR_OPERATION_DENIED' "$TMP/$label.err"; then
            note "REFUSED: $(cat "$TMP/$label.err")"
            return 1
        fi
        note "nobody pressed in time — one more window"
    done
    # -V both checks the self attestation and hands back the credential id on
    # line 1 and the public key from line 2 on, which is the shape fido2-assert
    # wants. -h here means "check the extension bit was actually signed".
    if ! fido2-cred -V -h < "$TMP/$label.cred" > "$TMP/$label.verified" 2> "$TMP/$label.verr"; then
        note "attestation REFUSED: $(cat "$TMP/$label.verr")"
        return 1
    fi
    head -1 "$TMP/$label.verified" > "$TMP/$label.id"
    tail -n +2 "$TMP/$label.verified" > "$TMP/$label.pem"
    note "made, self attestation verified, hmac-secret bit signed"
    return 0
}

# ------------------------------------------------------------------ one assertion
# $1 label, $2 credential label, $3 salt (empty = no extension). Echoes the
# 32-byte key in base64, or nothing.
assert_once() {
    local label="$1" cred="$2" salt="${3-}"
    {
        head -c 32 /dev/urandom | base64
        echo "$RP"
        cat "$TMP/$cred.id"
        [[ -n "$salt" ]] && echo "$salt"
    } > "$TMP/$label.in"

    local flag=()
    [[ -n "$salt" ]] && flag=(-h)

    # Retried once, and only on the refusal that means nobody pressed.
    #
    # A missed press used to cost the whole run: the seventh case of a
    # seven-press transcript came back OPERATION_DENIED because a person was a
    # second slow, and every number above it had to be thrown away. The device
    # is what is under test, not the reflexes of whoever is standing there. Any
    # other refusal is the subject failing and is not retried.
    local tries=2
    [[ -n "${NO_RETRY-}" ]] && tries=1
    local try
    for try in $(seq 1 $tries); do
        say "$label: fido2-assert -G ${flag[*]-} — PRESS BOOTSEL${try:+$([[ $try -eq 2 ]] && echo ' (again — the last window closed)')}"
        if fido2-assert -G "${flag[@]}" "$DEV" < "$TMP/$label.in" > "$TMP/$label.out" 2> "$TMP/$label.err"; then
            break
        fi
        if [[ $try -ge $tries ]] || ! grep -q 'FIDO_ERR_OPERATION_DENIED' "$TMP/$label.err"; then
            note "REFUSED: $(cat "$TMP/$label.err")"
            return 1
        fi
        note "nobody pressed in time — one more window"
    done
    # The signature is checked by the same library that asked for it, against
    # the key the credential handed over — the assertion has to stay an
    # assertion, extension or no extension.
    if ! fido2-assert -V "${flag[@]}" "$TMP/$cred.pem" es256 < "$TMP/$label.out" 2> "$TMP/$label.verr"; then
        note "signature REFUSED: $(cat "$TMP/$label.verr")"
        return 1
    fi
    if [[ -n "$salt" ]]; then
        # The hmac secret is the last line. It is line 6 when the credential is
        # resident and line 5 when it is not, and none of these are — so
        # counting from the end is the reading that does not depend on that.
        tail -1 "$TMP/$label.out"
    fi
    return 0
}

j() { python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "${1-}"; }

# ------------------------------------------------------------------------ run
# Every case below uses credential A, so a missed first press used to spend the
# other six on `input error`. It stops here instead, and says so: re-running is
# always safe, which is the whole reason the salts are fixed.
CRED_A_OK=false; CRED_B_OK=false
if make_cred credA alice; then
    CRED_A_OK=true
else
    say "credA was not made — nothing below can run. Press when the LED goes solid."
    # Naming the arm, because the bare form is not the same command.
    #
    # This used to say "re-run ./roundtrip.sh", and the bare form flashes the
    # `constant` image — which zeroes the SRAM the `bank8` key comes from. So
    # the advice printed after a missed press destroyed the provisioning the
    # missed press had not even spent, and the next run would need another cable
    # pull to get back to where the board already was. Recovery advice that
    # undoes the user'"'"'s state is worse than none.
    say "Nothing was spent: no flash, no reboot, the board is still keyed."
    say "Re-run  ./roundtrip.sh $ARM  — the salts are fixed, so it is comparable."
    exit 1
fi
make_cred credB bob && CRED_B_OK=true

K1=""; K1B=""; K2=""; KB=""; PLAIN_OK=false
K1="$(assert_once ga-salt1        credA "$S1")"       || K1=""
K1B="$(assert_once ga-salt1-again credA "$S1")"       || K1B=""
K2="$(assert_once ga-salt2        credA "$S2")"       || K2=""
KB="$(assert_once ga-credB-salt1  credB "$S1")"       || KB=""
assert_once ga-plain credA > /dev/null && PLAIN_OK=true

# The case that must not be pressed is **not here**, and that is the whole
# lesson of this script's third run.
#
# The LED is the only interface a person at the board has: this script's prompts
# go to a terminal that, when the board is driven remotely, nobody is sitting at.
# So a solid LED has to mean exactly one thing — *press me* — and the no-press
# case ran the same firmware path, lit the same LED, and asked for the one press
# that must never happen. A key came out twice, and both times a person was
# standing there with nothing but that light to go on. Eighteen attempts with
# nobody in the room refused every one.
#
# It needs nobody, so it belongs with the things that need nobody:
# ./nopress.sh, which runs on credential A out of work/ and can be left alone.

cat > roundtrip.json <<JSON
{
  "device": $(j "$DEV"),
  "rp_id": $(j "$RP"),
  "salt_one": $(j "$S1"),
  "salt_two": $(j "$S2"),
  "key_source": $(j "$KEY_SOURCE"),
  "banner_from": $(j "$BANNER_FROM"),
  "cred_a_made": $CRED_A_OK,
  "cred_b_made": $CRED_B_OK,
  "ga_salt1": $(j "$K1"),
  "ga_salt1_again": $(j "$K1B"),
  "ga_salt2": $(j "$K2"),
  "ga_credB_salt1": $(j "$KB"),
  "ga_plain_ok": $PLAIN_OK
}
JSON

say "wrote roundtrip.json"
say "now run ./nopress.sh — it needs nobody, and nothing it does should be pressed"
python3 verify.py roundtrip.json
