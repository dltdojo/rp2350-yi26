#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp202 run — the whole experiment, recorded to capture.txt. No board.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

{
capture_header "exp202 — the tests the chip passes"

echo ">>> what runs it"
echo "    $(../../tools/lean/lean.sh version)"
echo "    Hazard3 $(git -C ../../tools/hazard3/Hazard3 rev-parse --short=12 HEAD), riscv-tests $(git -C ../../tools/hazard3/Hazard3/test/sim/riscv-tests/riscv-tests rev-parse --short=12 HEAD), $(verilator --version)"
echo

echo ">>> every binary, on the model and on the RTL"
./build.sh > /dev/null
./compare.sh
echo

echo ">>> wrong models: each must be refused, and by what"
semantics/mutants.sh
} 2>&1 | tee capture.txt
