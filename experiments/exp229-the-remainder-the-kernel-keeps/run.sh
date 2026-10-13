#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp229 run — everything there is, recorded to capture.txt. No board.
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
capture_header "exp229 — the remainder the kernel keeps"

echo ">>> the theorems, and what they rest on"
"$LEAN" run proof/Field.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong kernels and wrong claims: each must be refused"
"$LEAN" table proof/Field.lean
echo

echo ">>> the model and the RTL against Python's integers: every edge pair, then 1000 drawn"
python3 differential/differential.py "$($LEAN exe rv32run)" kernel.bin 1000
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
