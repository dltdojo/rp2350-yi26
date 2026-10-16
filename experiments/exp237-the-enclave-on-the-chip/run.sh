#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp237 run — the half that needs no board, recorded to capture.txt.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

{
capture_header "exp237 — the enclave on the chip"

echo ">>> the shell, for the chip"
./build.sh
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee

