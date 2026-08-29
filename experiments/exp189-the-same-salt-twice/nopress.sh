#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp189 — the case that must not be pressed. Needs a board and nobody.
#
# This used to be the last case of ./roundtrip.sh, and moving it out is a
# finding rather than tidying. That script asks a person for seven presses, and
# the only signal reaching a person at the board is the LED going solid — the
# script's own prompts go to a terminal that, when the board is driven remotely,
# nobody is sitting at. The no-press case ran the same firmware path and lit the
# same light, so the one press that must never happen was being requested by the
# only channel the person had. A key came out twice, and the transcript could
# not say whether the device had lied or a person had pressed.
#
# So: **a solid LED means press, always, with no exceptions to remember.** This
# half needs nobody, runs on credential A out of `work/`, and should be started
# and walked away from.
#
#   ./roundtrip.sh          seven presses, seven solid LEDs
#   ./nopress.sh            leave the board alone
#
# Writes nopress.json. The board's own `presence: BOOTSEL read low` line is
# captured across every attempt, so a key that does come out says which of the
# two causes it was.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

ATTEMPTS="${1:-3}"

[[ -f work/credA.id ]] || {
    echo "work/credA.id is missing — run ./roundtrip.sh first, which leaves it there." >&2
    exit 1
}

DEV="$(fido2-token -L 2>/dev/null | grep -i 'same salt' | head -1 | cut -d: -f1)"
[[ -n "$DEV" ]] || DEV="$(fido2-token -L 2>/dev/null | head -1 | cut -d: -f1)"
[[ -n "$DEV" ]] || { echo "no FIDO device — is a board running exp189?" >&2; exit 1; }

S1="$(python3 -c 'import base64,hashlib;print(base64.b64encode(hashlib.sha256(b"exp189 salt one").digest()).decode())')"

echo ">>> $ATTEMPTS attempts, and the board should be left alone for all of them." >&2
echo ">>> Every solid LED here is one nobody answers. That is the measurement." >&2

# The board's log is a ring, so `yi26 log` replays lines from earlier in this
# boot — including the presses ./roundtrip.sh just asked for. A stale
# `presence:` line would let a real failure be excused as "somebody pressed", so
# the clock is read first and only lines after it count. The board prints an
# `idle:` line periodically, so there is always a timestamp to anchor on.
BASE_MS="$(yi26 log --seconds 4 2>/dev/null | grep -oE '^\[ *[0-9]+' | tr -dc '0-9\n' | sort -n | tail -1)"
BASE_MS="${BASE_MS:-0}"
echo ">>> only BOOTSEL reads after ${BASE_MS} ms of board uptime count as this run's" >&2

LOG="work/nopress.log"
: > "$LOG"
ANSWERED=0
CODE=""
for i in $(seq 1 "$ATTEMPTS"); do
    {
        head -c 32 /dev/urandom | base64
        echo "example.test"
        cat work/credA.id
        echo "$S1"
    } > "work/np$i.in"
    ( yi26 log --seconds 30 >> "$LOG" 2>/dev/null & )
    sleep 1
    if timeout 40 fido2-assert -G -h "$DEV" < "work/np$i.in" > "work/np$i.out" 2> "work/np$i.err"; then
        ANSWERED=$((ANSWERED + 1))
        printf 'X' >&2
    else
        printf '.' >&2
        [[ -n "$CODE" ]] || CODE="$(grep -oE 'FIDO_ERR_[A-Z_]+' "work/np$i.err" | tail -1)"
    fi
    sleep 2
done
echo >&2

# Every presence line the board emitted, filtered to this run by its own clock.
# Two numbers live on such a line — the log's own timestamp and the millisecond
# within the wait — and stripping everything but digits left both, so the
# recorded string read `(board uptime  154921  2743 ms)`. Only the first is the
# board clock this run is filtered against.
BOOTSEL="$(grep -oE '^\[ *[0-9]+ ms\]   presence: BOOTSEL read low at [0-9]+ ms' "$LOG" \
    | sed -E 's/^\[ *([0-9]+) ms\].*at ([0-9]+) ms$/\1 \2/' \
    | awk -v base="$BASE_MS" '$1 + 0 > base + 0 { print $1 " " $2 }' \
    | tail -1)"
[[ -z "$BOOTSEL" ]] || BOOTSEL="presence: BOOTSEL read low at board uptime ${BOOTSEL%% *} ms"

j() { python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "${1-}"; }
cat > nopress.json <<JSON
{
  "attempts": $ATTEMPTS,
  "answered": $ANSWERED,
  "refusal_code": $(j "$CODE"),
  "bootsel_line": $(j "$BOOTSEL")
}
JSON
echo ">>> wrote nopress.json" >&2
python3 verify.py roundtrip.json nopress.json
