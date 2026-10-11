#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp228 run — the half that needs no board, recorded to capture.txt.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh
source ../../tools/hazard3/shell/shell.sh

LEAN=../../tools/lean/lean.sh
export LEAN_JOBS="${LEAN_JOBS:-2}"
# check.sh reads the mutants' verdicts from the table above rather than refusing
# each a second time (tools/lean/lean.sh says how).
export LEAN_VERDICTS="$PWD/build/verdicts"; rm -rf -- "$LEAN_VERDICTS"

{
capture_header "exp228 — the script the kernel runs"

echo ">>> the theorems, and what they rest on"
"$LEAN" run proof/Script.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong kernels and wrong claims: each must be refused"
"$LEAN" table proof/Script.lean
echo

echo ">>> the specification, run, against script.py; the model and the RTL against script.py, 3000 fuzzed"
python3 differential/spec.py "$LEAN" 3000
python3 differential/differential.py "$($LEAN exe rv32run)" kernel.bin 3000
echo

echo ">>> the shell, for the chip and for the RTL"
./build.sh
echo

echo ">>> on the RTL, every case: CASE i code want minstret sigs valid, then DONE cases"
shell_words build/sim.bin 4000000000 | sed 's/ 43415345 /\n43415345 /g'
echo
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
