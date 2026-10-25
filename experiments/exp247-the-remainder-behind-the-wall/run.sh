#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp247 run — everything there is, recorded to capture.txt. No board.
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
capture_header "exp247 — the remainder behind the wall"

echo ">>> the formal theorems, and what they rest on"
"$LEAN" run proof/Wall.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong claims and wrong models: each must be refused"
"$LEAN" table proof/Wall.lean
echo

echo ">>> the kernel behind the wall, on the emulator"
python3 suite/behind_the_wall.py
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
