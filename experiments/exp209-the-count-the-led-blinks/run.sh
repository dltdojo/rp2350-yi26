#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp209 run — the cloud half, recorded to capture.txt. The board half is a
# person counting the LED; its result goes in the README by hand.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

{
capture_header "exp209 — the count the LED blinks (cloud half)"

echo ">>> the build"
./build.sh
echo

echo ">>> the shell on the Hazard3 RTL: REPT failed number instret cycles a0 cause"
../../tools/hazard3/sim.sh bare build/sim.bin --cycles 200000000 | tr '\n' ' '
echo
echo

echo ">>> every check"
./check.sh
} 2>&1 | tee capture.txt
