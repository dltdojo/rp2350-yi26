#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp236 run — everything there is, recorded to capture.txt. No board.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

LEAN=../../tools/lean/lean.sh
export LEAN_VERDICTS="$PWD/build/verdicts"; rm -rf -- "$LEAN_VERDICTS"

{
capture_header "exp236 — the wall the monitor holds"

echo ">>> the micro-monitor binary and size budget"
python3 monitor.py --check
echo

echo ">>> the formal theorems, and what they rest on"
"$LEAN" run proof/Monitor.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong monitors and wrong sandboxes: each must be refused"
"$LEAN" table proof/Monitor.lean
echo

echo ">>> normal execution: secp256k1 field arithmetic under PMP sandbox"
python3 cases/normal_cases.py
echo

echo ">>> hostile payloads"
python3 cases/attack_cases.py
echo

echo ">>> monitors with one thing wrong: each must be caught"
python3 cases/broken_monitors.py
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee

