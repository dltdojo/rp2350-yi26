#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp227 run — the half that needs no board, recorded to capture.txt.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

{
capture_header "exp227 — the life on the phone"

echo ">>> what the board sends, as rule30.py writes it: the start of a life"
python3 fixtures.py build/fixtures
grep -v '^exp227' build/fixtures/good.txt | head -5 | tr -d '\r'
echo

echo ">>> the shell, for the chip"
./build.sh
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
