#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp225 run — the half that needs no board, recorded to capture.txt.
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
capture_header "exp225 — the life every beat proved"

echo ">>> the kernel, as proof/Life.lean writes it"
"$LEAN" exec proof/Life.lean | grep -v axioms
echo

echo ">>> the theorems, and what they rest on"
"$LEAN" run proof/Life.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong kernels and wrong claims: each must be refused"
"$LEAN" table proof/Life.lean
echo

echo ">>> the first life's centre column, from rule30.py: what the LED plays, a beat each"
python3 rule30.py
echo

echo ">>> the shell, for the chip and for the RTL"
./build.sh
echo

echo ">>> on the RTL, two lives: LIFE round minstret gen1 gen256 centre-column"
shell_words build/sim.bin
echo
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
