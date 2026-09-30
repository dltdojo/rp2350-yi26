#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp199 run — the whole experiment, recorded to capture.txt. No board.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

LEAN=../../tools/lean/lean.sh

{
capture_header "exp199 — every length, not seven"

echo ">>> the proof: every theorem, and what it rests on"
echo "    $("$LEAN" version)"
echo
"$LEAN" run proof/CtapHid.lean
echo

echo ">>> the wrong versions: each must be refused"
"$LEAN" table proof/CtapHid.lean
} 2>&1 | tee capture.txt
