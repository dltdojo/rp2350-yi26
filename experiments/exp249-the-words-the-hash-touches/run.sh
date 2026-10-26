#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp249 run — everything there is, recorded to capture.txt. No board.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

LEAN=../../tools/lean/lean.sh
# A refused mutant is a proof that fails, and a failing proof holds its goals in memory: two at a time.
export LEAN_JOBS="${LEAN_JOBS:-2}"
export LEAN_VERDICTS="$PWD/build/verdicts"; rm -rf -- "$LEAN_VERDICTS"

{
capture_header "exp249 — the words the hash touches"

echo ">>> the formal theorems, and what they rest on"
"$LEAN" run proof/Hash.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong claims and a wrong checker: each must be refused"
"$LEAN" table proof/Hash.lean
echo

echo ">>> SHA-256 inside exp223, on the emulator, every access recorded"
python3 suite/hash_reach.py
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
