#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp214 run — the half that needs no board, recorded to capture.txt.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh
source ../../tools/hazard3/shell/shell.sh

{
capture_header "exp214 — the words the PIO inverts"

echo ">>> invert.pio, as pioasm assembles it"
../../tools/pioasm/pioasm-2.3.1/pioasm --version
../../tools/pioasm/pioasm-2.3.1/pioasm -o hex invert.pio
echo

echo ">>> the shell, for the chip and for the RTL"
./build.sh
echo

echo ">>> on the RTL, against a stand-in PIO that works: every write, then the verdict"
shell_words build/sim.bin | sed 's/57524954 /\nWRIT /g; s/52455054 /\nREPT /'
echo
echo

echo ">>> the checks"
./check.sh
} 2>&1 | tee capture.txt
