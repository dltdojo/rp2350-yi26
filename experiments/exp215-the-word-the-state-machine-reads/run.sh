#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp215 run — the whole experiment, recorded to capture.txt. No board.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

LEAN=../../tools/lean/lean.sh
PIOASM=../../tools/pioasm/pioasm-2.3.1/pioasm

{
capture_header "exp215 — the word the state machine reads"

echo ">>> the two theorems, and what they rest on"
echo "    $("$LEAN" version)"
echo
"$LEAN" run proof/Roundtrip.lean
echo

echo ">>> wrong versions of the library: each must be refused"
"$LEAN" table proof/Roundtrip.lean
echo

echo ">>> pioasm's reading against Lean's, over all 65536 words"
echo "    $("$PIOASM" --version)"
"$LEAN" exec differential/Gen.lean | python3 differential/differential.py
echo

echo ">>> wrong versions Lean cannot see: each must be accepted by Lean and refused by pioasm"
differential/gap.sh --show
} 2>&1 | tee capture.txt
