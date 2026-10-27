#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp256 run — everything there is, recorded to capture.txt. No board.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

{
capture_header "exp256 — the readings the RTL settles"

echo ">>> twenty-three probes, four readers: what each prints"
python3 probes/probes.py --table
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
