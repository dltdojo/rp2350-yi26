#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp213 run — the whole experiment, recorded to capture.txt. No board.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

LEAN=../../tools/lean/lean.sh

{
capture_header "exp213 — the signer the verifier accepts"

echo ">>> the kernels, as the proof states them and as keygen.bin and sign.bin hold them"
work="$(mktemp -d)"
$LEAN exec proof/Complete.lean "$work/keygen.bin" "$work/sign.bin" | grep -v axioms
for k in keygen sign; do
    echo "    $k.bin sha256 $(sha256sum "$work/$k.bin" | cut -d' ' -f1)  ($(stat -c %s "$work/$k.bin") bytes)"
    cmp -s "$work/$k.bin" $k.bin && echo "    byte for byte the committed $k.bin"
done
rm -rf -- "$work"
echo

echo ">>> the theorems, and what they rest on"
echo "    $($LEAN version)"
echo
$LEAN run proof/Complete.lean | grep -v '^  [0-9a-f]\{4\}  \|^keygen:\|^sign:'
echo

echo ">>> wrong kernels and wrong claims: each must be refused"
$LEAN table proof/Complete.lean
echo

echo ">>> what one HASH costs the RTL that the model does not count"
../../tools/hazard3/hash-cost.sh
echo

echo ">>> the kernels on the model and on the RTL, against Python; then the three in a row"
./compare.sh
} 2>&1 | tee capture.txt
