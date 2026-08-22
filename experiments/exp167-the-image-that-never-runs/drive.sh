#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Drive one full round of exp167 and print the transcript, both voices.
#
#   ./drive.sh [seed]
#
# Used by check.sh and to produce capture.txt. Separate from both because the
# sequence is the experiment: slot A refuses three requests, accepts the fourth,
# and the ROM takes the board back because slot B never buys.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
SEED="${1:-$(date +%s)}"
UF2=target/exp167-ab.uf2
R=../..

say() { printf '%s\n' "$*"; }

ask() { # mode
    local j esc
    j="$(python3 sign.py "$UF2" "$1" "$SEED")" || return 1
    esc="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["escaped"])' <<< "$j")"
    python3 -c '
import json, sys
d = json.load(sys.stdin)
print(">>> host: mode=%s expect=%s trial=%s virtual=%#x len=%#x physical=%#x sha256=%s"
      % (d["mode"], d["expect"], str(d["starts_trial"]).lower(),
         d["virtual_offset"], d["length"], d["physical"], d["sha256"]))' <<< "$j"
    yi26 send "$esc" 2>&1 | grep -vE '^yi26:|^ *try:'
}

say ">>> host: flashing the A/B pair and reading slot A's boot"
yi26 bootsel > /dev/null 2>&1
sleep 2
yi26 pflash "$UF2" > /dev/null 2>&1
sleep 4
yi26 log --seconds 8 2>&1 | grep -vE '^yi26:|^ *try:'

for MODE in wrong-key unreadable truncated good; do
    say ""
    ask "$MODE"
done

say ""
say ">>> host: slot B is on trial now. It never buys, so the ROM takes the board back."
sleep 3
yi26 log --seconds 16 2>&1 | grep -vE '^yi26:|^ *try:|read failed'
say ""
sleep 6
say ">>> host: and the board is back on: $(yi26 port --json 2>/dev/null | sed -n 's/.*"product":"\([^"]*\)".*/\1/p')"
