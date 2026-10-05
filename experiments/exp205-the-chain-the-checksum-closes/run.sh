#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp205 run — the whole experiment, recorded to capture.txt. No board.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

LEAN=../../tools/lean/lean.sh

{
capture_header "exp205 — the chain the checksum closes"

echo ">>> the kernel, as the proof states it and as kernel.bin holds it"
work="$(mktemp -d)"
$LEAN exec proof/Wots.lean "$work/kernel.bin" | grep -v axioms
echo "    sha256 $(sha256sum "$work/kernel.bin" | cut -d' ' -f1)  ($(stat -c %s "$work/kernel.bin") bytes)"
cmp -s "$work/kernel.bin" kernel.bin && echo "    byte for byte the committed kernel.bin"
rm -rf -- "$work"
echo

echo ">>> the theorems, and what they rest on"
echo "    $($LEAN version)"
echo
$LEAN run proof/Wots.lean | grep -v '^  [0-9a-f]\{4\}  '
echo

echo ">>> wrong kernels and wrong claims: each must be refused"
$LEAN table proof/Wots.lean
echo

echo ">>> what one HASH costs the RTL that the model does not count"
../../tools/hazard3/hash-cost.sh
echo

echo ">>> the kernel on the model and on the RTL, against Python"
./compare.sh
} 2>&1 | tee capture.txt
