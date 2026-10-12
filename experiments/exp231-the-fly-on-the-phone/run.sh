#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp231 run — the half that needs no board, recorded to capture.txt.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

{
capture_header "exp231 — the fly on the phone"

echo ">>> what the board sends, as rule30.py and fly.py write it: the start of a round"
python3 fixtures.py build/fixtures
grep -v '^exp231' build/fixtures/good.txt | head -7 | tr -d '\r'
echo

echo ">>> the shell, for the chip and the RTL"
./build.sh
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
