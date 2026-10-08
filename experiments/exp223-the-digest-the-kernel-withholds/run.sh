#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp223 run — the half that needs no board, recorded to capture.txt.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh
source ../../tools/hazard3/shell/shell.sh

LEAN=../../tools/lean/lean.sh
# One mutant at a time: each loads SHA-256's proof, and four side by side run
# out of memory, which tools/lean/lean.sh now says rather than counting.
export LEAN_JOBS=1

{
capture_header "exp223 — the digest the kernel withholds"

echo ">>> the front, as proof/Condition.lean writes it (exp208's SHA-256 follows at 0x1000)"
"$LEAN" exec proof/Condition.lean | grep -v axioms
echo

echo ">>> the theorems, and what they rest on"
"$LEAN" run proof/Condition.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong kernels and wrong claims: each must be refused"
"$LEAN" table proof/Condition.lean
echo

echo ">>> the differential: the Lean model and the Hazard3 RTL against exp114's tests and hashlib"
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
} 2>&1 | tee capture.txt
