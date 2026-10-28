#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp257 run — everything there is, recorded to capture.txt. No board.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

{
capture_header "exp257 — the bits the chip transposes"

echo ">>> twenty-eight probes, two cores: what each reads back"
python3 probes/probes.py
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
