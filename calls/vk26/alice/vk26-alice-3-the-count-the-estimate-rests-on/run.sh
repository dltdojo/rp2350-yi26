#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# vk26-alice-3 run — the half that needs no board, recorded to capture.txt.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
TOOLS=../../../../tools
source ../../../../experiments/lib.sh
source "$TOOLS/hazard3/shell/shell.sh"

LEAN=$TOOLS/lean/lean.sh
# check.sh reads the mutants' verdicts from the table below rather than
# refusing each a second time (tools/lean/lean.sh says how).
export LEAN_VERDICTS="$PWD/build/verdicts"; rm -rf -- "$LEAN_VERDICTS"

{
capture_header "vk26-alice-3 — the count the estimate rests on"

echo ">>> the theorems, and what they rest on"
"$LEAN" run proof/Count.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong kernels and wrong claims: each must be refused"
"$LEAN" table proof/Count.lean
echo

echo ">>> count.py's streams, their counts and estimates, and §6.3.1's example"
python3 count.py
echo

echo ">>> the shell, for the chip and for the RTL"
./build.sh
echo

echo ">>> on the RTL, every stream twice: STRM s most want minstret mcycle, the second run's minstret mcycle, then DONE streams"
shell_words build/sim.bin 400000000 | sed 's/ 5354524d /\n5354524d /g'
echo
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
