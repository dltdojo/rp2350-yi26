#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp216 run — the half that needs no board, recorded to capture.txt.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh
source ../../tools/hazard3/shell/shell.sh

LEAN=../../tools/lean/lean.sh

{
capture_header "exp216 — the pin the PIO drives"

echo ">>> the program, as Lean instructions and the words Lean's encode makes"
"$LEAN" exec proof/Program.lean | grep -v axioms
echo

echo ">>> drive.pio, as pioasm assembles it"
../../tools/pioasm/pioasm-2.3.1/pioasm -o hex drive.pio
echo

echo ">>> the shell, for the chip and for the RTL"
./build.sh
echo

echo ">>> on the RTL, against a stand-in PIO and pin that work: every write, then the verdict"
shell_words build/sim.bin | sed 's/57524954 /\nWRIT /g; s/52455054 /\nREPT /'
echo
echo

echo ">>> the checks"
./check.sh
} 2>&1 | tee capture.txt
