#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp254 run — everything there is, recorded to capture.txt. No board.
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
capture_header "exp254 — the life the box lets through"

echo ">>> the formal theorems, and what they rest on"
"$LEAN" run proof/Box.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong claims and a wrong bridge: each must be refused"
"$LEAN" table proof/Box.lean
echo

echo ">>> exp225 behind exp240 on the emulator, from reset to the park"
python3 suite/life.py
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
