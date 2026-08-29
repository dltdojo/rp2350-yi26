#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
#
# exp189 — the control, with nobody there. Needs a board and nobody.
#
#   ./control.sh            three presses; every solid LED is one to answer
#   ./control-nopress.sh    start it and walk away
#
# This is a separate file for the reason exp189 and exp191 both paid for: a
# solid LED means press, always, with no exception to remember. A no-press case
# living inside a press script lights the same light and gets answered, and the
# transcript then cannot say whether the tool gave up or a person helped it.
#
# It runs against the ciphertext ./control.sh left behind, so it costs no
# registration and no press of its own.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

W=work/control
ENC="$W/secret.enc"
PLAIN="$W/plain.txt"
[[ -f "$ENC" && -f "$PLAIN" ]] || {
    echo "$ENC is missing — run ./control.sh first, which leaves it there." >&2
    exit 1
}
AGE=./bin/age
[[ -x "$AGE" ]] || { echo "$AGE is missing — run ./setup.sh" >&2; exit 1; }
export PATH="$PWD/bin:$PATH"

ATTEMPTS="${1:-3}"
echo ">>> $ATTEMPTS attempts, and the board should be left alone for all of them." >&2
echo ">>> Every solid LED here is one nobody answers. That is the measurement." >&2

# The board's log is a ring and replays, so a `presence:` line from ./control.sh
# would let a real failure be excused as "somebody pressed". Only lines after
# this reading count.
BASE_MS="$(yi26 log --seconds 4 2>/dev/null | grep -oE '^\[ *[0-9]+' | tr -dc '0-9\n' | sort -n | tail -1)"
BASE_MS="${BASE_MS:-0}"
echo ">>> only BOOTSEL reads after ${BASE_MS} ms of board uptime count as this run's" >&2

LOG="$W/nopress-board.log"
: > "$LOG"
OPENED=0
LEAKED=0
ERR=""
for i in $(seq 1 "$ATTEMPTS"); do
    yi26 log --seconds 40 >> "$LOG" 2>/dev/null &
    LOGGER=$!
    sleep 1
    OUT="$W/nopress$i.out"
    : > "$OUT"
    if timeout 60 "$AGE" -d -j fido2-hmac "$ENC" > "$OUT" 2> "$W/nopress$i.err"; then
        OPENED=$((OPENED + 1)); printf 'X' >&2
    else
        printf '.' >&2
        # The *error*, not the footer. `age` ends its stderr with
        # "report unexpected or unhelpful errors at https://filippo.io/age/report",
        # so `tail -1` recorded a support link as the word for the refusal.
        [[ -n "$ERR" ]] || ERR="$(grep -E '^age: (error|warning)' "$W/nopress$i.err" | head -1)"
        [[ -n "$ERR" ]] || ERR="$(head -1 "$W/nopress$i.err")"
    fi
    # A refusal that still wrote the plaintext somewhere is not a refusal.
    [[ -s "$OUT" ]] && LEAKED=$((LEAKED + 1))
    kill "$LOGGER" 2>/dev/null; wait "$LOGGER" 2>/dev/null || true
done
echo >&2

BOOTSEL="$(grep -oE '^\[ *[0-9]+ ms\]   presence: BOOTSEL read low at [0-9]+ ms' "$LOG" \
    | sed -E 's/^\[ *([0-9]+) ms\].*at ([0-9]+) ms$/\1 \2/' \
    | awk -v base="$BASE_MS" '$1 + 0 > base + 0 { print $1 " " $2 }' | tail -1)"
[[ -z "$BOOTSEL" ]] || BOOTSEL="presence: BOOTSEL read low at board uptime ${BOOTSEL%% *} ms"

j() { python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "${1-}"; }
cat > control-nopress.json <<JSON
{
  "attempts": $ATTEMPTS,
  "opened": $OPENED,
  "wrote_plaintext_anyway": $LEAKED,
  "refusal": $(j "$ERR"),
  "bootsel_line": $(j "$BOOTSEL")
}
JSON
echo ">>> wrote control-nopress.json" >&2
python3 -c '
import json
d = json.load(open("control-nopress.json"))
for k, v in d.items():
    print(f"      {k}: {v}")
'
