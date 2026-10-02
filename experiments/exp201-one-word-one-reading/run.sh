#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp201 run — the whole experiment, recorded to capture.txt. No board.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

LEAN=../../tools/lean/lean.sh

{
capture_header "exp201 — one word, one reading"

echo ">>> the two theorems, and what they rest on"
echo "    $("$LEAN" version)"
echo
"$LEAN" run proof/Roundtrip.lean
echo

echo ">>> wrong versions of the library: each must be refused"
"$LEAN" table proof/Roundtrip.lean
echo

echo ">>> LLVM's reading against Lean's"
echo "    $(llvm-mc --version | grep -m1 -i 'llvm version' | sed 's/^ *//')"
"$LEAN" exec differential/Gen.lean | python3 differential/differential.py
echo

echo ">>> wrong versions Lean cannot see: each must be accepted by Lean and refused by LLVM"
differential/gap.sh --show
} 2>&1 | tee capture.txt
