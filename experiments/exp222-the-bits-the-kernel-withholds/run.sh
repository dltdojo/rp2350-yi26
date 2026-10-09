#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp222 run — the half that needs no board, recorded to capture.txt.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh
source ../../tools/hazard3/shell/shell.sh

LEAN=../../tools/lean/lean.sh
# check.sh reads the mutants' verdicts from the table above rather than refusing
# each a second time (tools/lean/lean.sh says how).
export LEAN_VERDICTS="$PWD/build/verdicts"; rm -rf -- "$LEAN_VERDICTS"

{
capture_header "exp222 — the bits the kernel withholds"

echo ">>> the kernel, as proof/Health.lean writes it"
"$LEAN" exec proof/Health.lean | grep -v axioms
echo

echo ">>> the theorems, and what they rest on"
"$LEAN" run proof/Health.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong kernels: each must be refused"
"$LEAN" table proof/Health.lean
echo

echo ">>> the differential: the Lean model and the Hazard3 RTL against exp114's tests"
python3 differential/differential.py "$("$LEAN" exe rv32run)"
echo

echo ">>> the shell, for the chip and for the RTL"
./build.sh
echo

echo ">>> on the RTL, the kernel for real on three sources: REPT verdict source failed a0 minstret cause"
shell_words build/sim.bin
echo
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
