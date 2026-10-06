#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp207 run — the whole experiment, recorded to capture.txt. No board.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

LEAN=../../tools/lean/lean.sh

{
capture_header "exp207 — the trace the seed cannot move"

echo ">>> the theorems, and what they rest on"
echo "    $($LEAN version)"
echo
$LEAN run proof/Trace.lean
echo

echo ">>> kernels that are not constant time, wrong claims, unsound checker rules: each must be refused"
$LEAN table proof/Trace.lean
echo

echo ">>> the two runs, on the model and on the RTL"
python3 timing.py
} 2>&1 | tee capture.txt
