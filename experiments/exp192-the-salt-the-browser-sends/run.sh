#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
#
# exp192 — the browser half. Needs a board, a browser, and a person.
#
#   ./run.sh
#
# Three clicks in the page, and a BOOTSEL press for each. The browser will not
# tell anybody when the board wants a finger — it shows its own dialog and then
# waits — so the LED is the only signal, exactly as everywhere else here.
#
# What this cannot do is run headless. Chrome reaches the board through its own
# CTAP stack on /dev/hidraw, not through WebUSB, and a headless browser has
# neither a user gesture nor a finger. exp174 established the shape; this one
# needs the same person in the same room.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

say() { printf '>>> %s\n' "$*" >&2; }

PORT=8192
FW=../exp189-the-same-salt-twice

# ---- the firmware has to be the one that says what arrived ------------------
#
# exp189's default build prints the salt's *length* and not the salt. That is
# the right default — its own transcripts were taken that way — so this asks for
# the flag build, and asking is the whole reason this experiment needs a flash.
#
# The `constant` arm on purpose: the `bank8` arm's key would be zeroed by the
# flash and cost a cable pull to bring back, and nothing here depends on where
# the secret lives. What is being measured is what the *client* sends.
if [[ "${EXP192_SKIP_FLASH:-0}" != "1" ]]; then
    # Four flags, and every one of them was bought with a browser round.
    #
    #   EXP189_LOG_SALT=1        say which salt arrived — the original question
    #   EXP189_ADVERTISE_UV=0    stop claiming a configured verification method
    #   EXP189_SELECTION=1       answer CTAP 2.1 authenticatorSelection (0x0B)
    #   EXP189_ADVERTISE_PIN=0   stop claiming a PIN this board has not got
    #
    # The last three are not conveniences. Each one, left as exp189 shipped it,
    # ended the conversation before the board's LED ever lit — and none of them
    # is visible to libfido2, which is why every other client in this
    # repository worked. See the README.
    say "building exp189 for a browser (constant arm, four flags)"
    ( cd "$FW" && EXP189_KEY=constant EXP189_LOG_SALT=1 EXP189_ADVERTISE_UV=0 \
        EXP189_SELECTION=1 EXP189_ADVERTISE_PIN=0 cargo build --release --quiet ) \
        || { echo "build failed" >&2; exit 1; }
    ELF="$FW/target/thumbv8m.main-none-eabihf/release/exp189-the-same-salt-twice"
    UF2=target/exp192-browser.uf2
    mkdir -p target
    elf2flash convert -b rp2350 "$ELF" "$UF2" > /dev/null 2>&1 \
        || { echo "elf2flash failed" >&2; exit 1; }
    say "flashing $UF2"
    yi26 flash "$UF2" > /dev/null 2>&1 || { echo "flash failed" >&2; exit 1; }
    sleep 5
fi

# The board must actually be the flag build, or every reading below is missing
# and it would look like the browser sent nothing.
say "the board's own account of what it is"
yi26 log --seconds 5 2>/dev/null | grep -iE 'exp189|key source|hmac-secret:' | sed 's/^/    /' >&2

rm -f transcript.json
: > board.log

# ---- the origin, and the log, both running for the whole session -----------
python3 serve.py "$PORT" > serve.log 2>&1 &
SERVER=$!
yi26 log --seconds 900 >> board.log 2>/dev/null &
LOGGER=$!
cleanup() { kill "$SERVER" "$LOGGER" 2>/dev/null; }
trap cleanup EXIT INT TERM
sleep 1

BROWSER="$(command -v google-chrome || command -v chromium || command -v chromium-browser || true)"
[[ -n "$BROWSER" ]] || { echo "no chromium-family browser found" >&2; exit 1; }
say "opening $BROWSER at http://localhost:$PORT"
"$BROWSER" --new-window "http://localhost:$PORT" > /dev/null 2>&1 &

cat >&2 <<'EOF'
>>> In the page, click the three buttons in order. Each one lights the board.
>>>
>>>   1 — register                        PRESS BOOTSEL
>>>   2 — evaluate prf, uv discouraged    PRESS BOOTSEL
>>>   3 — evaluate prf, uv required       PRESS BOOTSEL
>>>
>>> Chrome may send authenticatorSelection first — "which key do you mean" —
>>> which lights the LED too. Press at every one; there is no window here that
>>> should be left alone.
>>>
>>> Every solid LED here is one to press, including the third: a refusal that
>>> comes from the browser is a finding, and a refusal that comes from nobody
>>> pressing is not the same finding.
EOF

# Waiting for the page's own reports rather than for a clock. Three entries is
# the whole run; anything fewer and the analysis below would describe a session
# that had not happened.
say "waiting for three transcript entries (up to 15 minutes)"
for _ in $(seq 1 180); do
    [[ -f transcript.json ]] && [[ "$(wc -l < transcript.json)" -ge 3 ]] && break
    sleep 5
done
N="$(wc -l < transcript.json 2>/dev/null || echo 0)"
if [[ "$N" -lt 3 ]]; then
    echo "only $N of 3 steps came back — nothing below would be a full reading." >&2
    echo "the page is still open; run ./run.sh again with EXP192_SKIP_FLASH=1" >&2
    echo "to keep this board and this credential." >&2
fi
sleep 2
cleanup

say "what the board says arrived, salt by salt"
grep -oE 'hmac-secret: salt in = [0-9a-f]+' board.log | sed 's/^/    /' >&2

python3 analyse.py transcript.json board.log > analysis.json
say "wrote analysis.json"
python3 verify.py analysis.json
