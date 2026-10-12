#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp233 run — everything there is without a board, recorded to capture.txt.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

{
capture_header "exp233 — the trial on the phone"

echo ">>> what exp232's board sends, as cure.py writes it: the first patient"
python3 fixtures.py build/fixtures
head -4 build/fixtures/good.txt | tr -d '\r'
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
