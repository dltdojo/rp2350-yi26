#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp230 run — everything there is, recorded to capture.txt. No board.
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
capture_header "exp230 — the motion the fly sees"

echo ">>> the theorems, and what they rest on"
"$LEAN" run proof/Fly.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong kernels and wrong claims: each must be refused"
"$LEAN" table proof/Fly.lean
echo

echo ">>> T3 by brute force, apart from the proof: every one of the 2^32 rings, one generation of Rule 30"
if command -v cc > /dev/null; then
    mkdir -p build && cc -O2 -o build/every every.c && ./build/every
else
    echo "SKIP  no C compiler"
fi
echo

echo ">>> the model and the RTL against fly.py: the named stimuli, then 200 random"
python3 differential/differential.py "$($LEAN exe rv32run)" kernel.bin 200
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
