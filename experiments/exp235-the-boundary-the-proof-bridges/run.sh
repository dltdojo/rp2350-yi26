#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp235 run — everything there is, recorded to capture.txt. No board.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

LEAN=../../tools/lean/lean.sh
export LEAN_VERDICTS="$PWD/build/verdicts"; rm -rf -- "$LEAN_VERDICTS"

{
capture_header "exp235 — the boundary the proof bridges"

echo ">>> the theorems, and what they rest on"
"$LEAN" run proof/Bridge.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong privilege semantics and wrong claims: each must be refused"
"$LEAN" table proof/Bridge.lean
echo

echo ">>> Python test vectors for Hazard3 NAPOT boundary logic"
python3 test_vectors.py
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee

