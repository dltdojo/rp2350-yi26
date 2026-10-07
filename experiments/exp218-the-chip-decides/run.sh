#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp218 run — the half that needs no board, recorded to capture.txt.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh
source ../../tools/hazard3/shell/shell.sh

LEAN=../../tools/lean/lean.sh

{
capture_header "exp218 — the chip decides"

echo ">>> the cases, and what lean/Pio/Machine.lean says the chip holds when each stops"
"$LEAN" exec model/Cases.lean
echo

echo ">>> the shell, for the chip and for the RTL"
./build.sh
echo

echo ">>> on the RTL, against a stand-in that holds what the model says: the verdict"
echo "    (every one of the $(grep -vc '^#' expected.txt) writes is in expected.txt, and check.sh holds the run to it)"
shell_words build/sim.bin | grep -oE '52455054 .*' | sed 's/^52455054 /REPT /'
echo

echo ">>> the checks"
./check.sh
} 2>&1 | tee capture.txt
