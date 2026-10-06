#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp208 run — the whole experiment, recorded to capture.txt. No board.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

LEAN=../../tools/lean/lean.sh

{
capture_header "exp208 — the hash the kernel computes"

echo ">>> the kernel, as the proof states it and as sha.bin holds it"
work="$(mktemp -d)"
$LEAN exec proof/Sha.lean kernel "$work/sha.bin"
echo "    sha.bin sha256 $(sha256sum "$work/sha.bin" | cut -d' ' -f1)  ($(stat -c %s "$work/sha.bin") bytes)"
cmp -s "$work/sha.bin" sha.bin && echo "    byte for byte the committed sha.bin"
rm -rf -- "$work"
echo

echo ">>> the theorems, and what they rest on"
echo "    $($LEAN version)"
echo
$LEAN run proof/Sha.lean
echo

echo ">>> wrong kernels, wrong claims and a wrong specification: each must be refused"
$LEAN table proof/Sha.lean
echo

echo ">>> the kernel on the model and on the RTL, and the specification, against hashlib"
python3 compare.py "$($LEAN exe rv32run)" sha.bin "$LEAN exec proof/Sha.lean digest"
} 2>&1 | tee capture.txt
