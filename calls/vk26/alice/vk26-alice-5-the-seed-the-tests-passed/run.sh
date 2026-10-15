#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# vk26-alice-5 run — the half that needs no board, recorded to capture.txt.
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
capture_header "vk26-alice-5 — the seed the tests passed"

echo ">>> the theorems, and what they rest on"
"$LEAN" run proof/Seed.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong kernels and wrong claims: each must be refused"
"$LEAN" table proof/Seed.lean
echo

echo ">>> seed.py, from SP 800-90A's text, against NIST's vectors"
python3 seed.py
echo

echo ">>> the shell, for the chip and for the RTL"
./build.sh
echo

echo ">>> on the RTL, every NIST case: CASE i, then minstret mcycle of Instantiate and two Generates;"
echo ">>> then each chain: CHN s code, alice-2's minstret mcycle, and with 0 Instantiate's and Generate's; then DONE cases"
shell_words build/sim.bin 600000000 | sed 's/ \(43415345\|43484e00\|444f4e45\) /\n\1 /g'
echo
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
