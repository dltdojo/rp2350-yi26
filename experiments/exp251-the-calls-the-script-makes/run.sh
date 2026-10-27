#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp251 run — everything there is, recorded to capture.txt. No board.
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
capture_header "exp251 — the calls the script makes"

echo ">>> the formal theorems, and what they rest on"
"$LEAN" run proof/Calls.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong claims and a wrong model: each must be refused"
"$LEAN" table proof/Calls.lean
echo

echo ">>> exp228 alone on the emulator, every call recorded"
python3 suite/calls.py
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
