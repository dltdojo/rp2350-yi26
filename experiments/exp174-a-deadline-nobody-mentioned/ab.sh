#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp174's browser half. This one needs a person, and only for two clicks.
#
#   python3 serve.py &     # in another terminal, or it will not have an origin
#   ./ab.sh
#
# Two firmwares from one source, differing in whether the board says "still
# here" while it waits for a finger. Both answer on the board's own clock at
# EXP174_HOLD_MS, so the person's timing is not part of the measurement — press
# whenever, the answer leaves when the board decides.
#
# The script does not ask anybody to press enter. It watches transcript.json,
# which the page posts to, so "done" is a fact about a file rather than a
# judgement somebody has to make. Two earlier versions of this measurement put
# the precision inside a human reflex — counting to nine and a half, holding a
# button for half a minute — and both were the wrong instrument.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

HOLD="${EXP174_HOLD_MS:-25000}"
WINDOW="${EXP174_TIMEOUT_MS:-35000}"
PORT="${EXP174_PORT:-8174}"
TRANSCRIPT="transcript.json"

say() { printf '>>> %s\n' "$*"; }

curl -sf -o /dev/null "http://localhost:$PORT/index.html" || {
    echo "nothing is serving http://localhost:$PORT — run: python3 serve.py"
    exit 1
}

lines() { [[ -f "$TRANSCRIPT" ]] && wc -l < "$TRANSCRIPT" || echo 0; }

run_arm() {  # run_arm <keepalive on|off>
    local ka="$1"
    say "building and flashing: keepalive=$ka, floor ${HOLD} ms, window ${WINDOW} ms"
    EXP174_UP=button EXP174_KEEPALIVE="$ka" EXP174_HOLD_MS="$HOLD" \
        EXP174_TIMEOUT_MS="$WINDOW" cargo build --release > /dev/null 2>&1 || {
        echo "build failed"; exit 1; }
    elf2flash convert -b rp2350 \
        target/thumbv8m.main-none-eabihf/release/exp174-a-deadline-nobody-mentioned \
        "target/exp174-ab-$ka.uf2" > /dev/null 2>&1
    yi26 bootsel > /dev/null 2>&1
    sleep 2
    yi26 pflash "target/exp174-ab-$ka.uf2" > /dev/null 2>&1
    sleep 7

    local before
    before="$(lines)"
    yi26 log --seconds 300 > "board-$ka.log" 2>&1 &
    local logpid=$!
    sleep 1

    cat <<TXT

    ---------------------------------------------------------------
    In the browser, at http://localhost:$PORT

      1. press  register
      2. when the browser asks you to touch your security key,
         press BOOTSEL — once, whenever you like, then let go
      3. wait. The board answers at ${HOLD} ms by its own clock.

    If the dialog stops responding, that is a result: cancel it and
    the page will report what the browser says.
    ---------------------------------------------------------------

TXT
    say "watching $TRANSCRIPT for the browser's answer"
    local waited=0
    while [[ "$(lines)" == "$before" ]]; do
        sleep 2
        waited=$((waited + 2))
        if (( waited > 300 )); then
            echo "    nothing after five minutes; stopping"
            kill "$logpid" 2>/dev/null
            exit 1
        fi
    done
    say "the page reported after ${waited} s"
    sleep 2
    kill "$logpid" 2>/dev/null
    wait "$logpid" 2>/dev/null
    cp "$TRANSCRIPT" "transcript-$ka.json"
    grep -E 'answered at|credential made|TRNG took' "board-$ka.log" | sed 's/^/    /'
}

rm -f "$TRANSCRIPT"
run_arm off
run_arm on

say "assembling browser-ab.json"
python3 - <<'PY'
import json, re

def board(path):
    txt = open(path).read()
    def g(pat):
        m = re.search(pat, txt)
        return m.group(1) if m else None
    return {
        "log": path,
        "arm": "keepalive" if "KEEPALIVE every 100 ms" in txt else "silent",
        "hold_ms": int(g(r"not answered before (\d+) ms") or -1),
        "window_ms": int(g(r"the window is (\d+) ms") or -1),
        "pressed_at_ms": int(g(r"pressed at (\d+) ms") or -1),
        "answered_at_ms": int(g(r"answered at (\d+) ms") or -1),
        "keepalives": int(g(r"answered at \d+ ms, (\d+) keepalives") or -1),
        "trng_us": int(g(r"TRNG took (\d+) us") or -1),
        "credential_made": "credential made" in txt,
    }

def last_create(path):
    out = None
    for line in open(path):
        e = json.loads(line)
        if e.get("step") == "create":
            out = e
    return out

doc = {
    "what": "exp174: the same source, the same board, the same browser, one flag",
    "arms": [
        {"board": board("board-off.log"), "browser": last_create("transcript-off.json")},
        {"board": board("board-on.log"), "browser": last_create("transcript-on.json")},
    ],
}
open("browser-ab.json", "w").write(json.dumps(doc, indent=2) + "\n")
PY

say "and checking it"
python3 verify.py browser-ab.json
