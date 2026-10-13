#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp234 run — the half that needs no board, recorded to capture.txt.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

LEAN=../../tools/lean/lean.sh
# check.sh reads the mutants' verdicts from the table above rather than refusing
# each a second time (tools/lean/lean.sh says how).
export LEAN_VERDICTS="$PWD/build/verdicts"; rm -rf -- "$LEAN_VERDICTS"

{
capture_header "exp234 — the rate the proof predicts"

echo ">>> the theorems, and what they rest on"
"$LEAN" run proof/World.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong kernels and wrong claims: each must be refused"
"$LEAN" table proof/World.lean
echo

echo ">>> the rate M7 predicts, and 40000 treated patients in cure.py's world"
python3 world.py --check && python3 world.py
echo

echo ">>> the shell, for the chip and the RTL"
./build.sh
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
