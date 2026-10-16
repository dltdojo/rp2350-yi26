#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp238 run — everything there is, recorded to capture.txt. No board.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

LEAN=../../tools/lean/lean.sh
export LEAN_VERDICTS="$PWD/build/verdicts"; rm -rf -- "$LEAN_VERDICTS"

{
capture_header "exp238 — the call the monitor checks"

echo ">>> the micro-monitor binary and size budget"
python3 monitor.py --check
echo

echo ">>> the formal theorems, and what they rest on"
"$LEAN" run proof/Calls.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong monitors: each must be refused"
"$LEAN" table proof/Calls.lean
echo

echo ">>> exp228's kernel and its scripts, under the monitor"
python3 suite/kernel_cases.py
echo

echo ">>> payloads that lean on the calls"
python3 suite/attack_cases.py
echo

echo ">>> monitors with one thing wrong: each must be caught"
python3 suite/broken_monitors.py
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
