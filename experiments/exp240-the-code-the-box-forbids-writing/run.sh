#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp240 run — everything there is, recorded to capture.txt. No board.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

LEAN=../../tools/lean/lean.sh
# A refused mutant is a proof that fails, and a failing proof holds its goals in memory: two at a time.
export LEAN_JOBS="${LEAN_JOBS:-2}"
export LEAN_VERDICTS="$PWD/build/verdicts"; rm -rf -- "$LEAN_VERDICTS"

{
capture_header "exp240 — the code the box forbids writing"

echo ">>> the micro-monitor binary and size budget"
python3 monitor.py --check
echo

echo ">>> the formal theorems, and what they rest on"
"$LEAN" run proof/Wx.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong monitors, wrong claims and wrong models: each must be refused"
"$LEAN" table proof/Wx.lean
echo

echo ">>> exp225's Rule 30 kernel, round after round, under the monitor"
python3 suite/rounds.py
echo

echo ">>> payloads that write the code, run the data, and fall off the stack"
python3 suite/wx_attacks.py
echo

echo ">>> monitors with one thing wrong: each must be caught"
python3 suite/broken_monitors.py
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
