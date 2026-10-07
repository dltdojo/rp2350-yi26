#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp217 run — the whole experiment, recorded to capture.txt. No board.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

LEAN=../../tools/lean/lean.sh

{
capture_header "exp217 — the words the model inverts"

echo ">>> the theorems, and what they rest on"
echo "    $("$LEAN" version)"
echo
"$LEAN" run proof/Invert.lean
echo

echo ">>> wrong models: each must be refused by the proof"
"$LEAN" table proof/Invert.lean
echo

work="$(mktemp -d)"
differential/traces.sh "$work" --lean
python3 differential/differential.py "$work"/{cases,lean,js,py}
rm -rf "$work"

echo ">>> wrong models the proof cannot see: each must pass it and be refused by the emulators"
differential/gap.sh --show
} 2>&1 | tee capture.txt
