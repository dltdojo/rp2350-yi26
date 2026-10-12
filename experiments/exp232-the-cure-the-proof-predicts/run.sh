#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp232 run — the half that needs no board, recorded to capture.txt.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

LEAN=../../tools/lean/lean.sh
export LEAN_JOBS="${LEAN_JOBS:-2}"
# check.sh reads the mutants' verdicts from the table above rather than refusing
# each a second time (tools/lean/lean.sh says how).
export LEAN_VERDICTS="$PWD/build/verdicts"; rm -rf -- "$LEAN_VERDICTS"

{
capture_header "exp232 — the cure the proof predicts"

echo ">>> the theorems, and what they rest on"
"$LEAN" run proof/Cure.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong kernels and wrong claims: each must be refused"
"$LEAN" table proof/Cure.lean
echo

echo ">>> the search as the chip runs it, and 2000 patients in cure.py's world"
python3 cure.py
echo

echo ">>> the shell, for the chip and the RTL"
./build.sh
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
