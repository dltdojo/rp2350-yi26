#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp224 run — the half that needs no board, recorded to capture.txt.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh
source ../../tools/hazard3/shell/shell.sh

LEAN=../../tools/lean/lean.sh
# Its mutants are light enough to run side by side; exp223's are not.

{
capture_header "exp224 — the checks the kernel makes"

echo ">>> the judge, as proof/Judge.lean writes it"
"$LEAN" exec proof/Judge.lean | grep -v axioms
echo

echo ">>> the theorems, and what they rest on"
"$LEAN" run proof/Judge.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong kernels and wrong claims: each must be refused"
"$LEAN" table proof/Judge.lean
echo

echo ">>> the differential: the Lean model and the Hazard3 RTL against the specification in Python"
python3 differential/differential.py "$("$LEAN" exe rv32run)"
echo

echo ">>> the shell, for the chip and for the RTL"
./build.sh
echo

echo ">>> on the RTL, exp223's kernel and the judge for real: REPT verdict source failed code minstret cause"
shell_words build/sim.bin
echo
echo

echo ">>> the checks"
./check.sh
} 2>&1 | tee capture.txt
