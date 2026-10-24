#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp245 run — everything there is, recorded to capture.txt. No board.
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
capture_header "exp245 — the bytes the proof blesses"

echo ">>> the micro-monitor binary, its size budget, and the charms taken away"
python3 monitor.py --check
echo

echo ">>> the formal theorems, and what they rest on"
"$LEAN" run proof/Bless.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong monitors, wrong claims and wrong models: each must be refused"
"$LEAN" table proof/Bless.lean
echo

echo ">>> the charms on the emulator: what each theorem says, and what each charm does"
python3 suite/charms_audit.py
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
