#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp239 run — everything there is, recorded to capture.txt. No board.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

LEAN=../../tools/lean/lean.sh
# A refused mutant is a proof that fails, and a failing proof holds its goals in memory: two at a time.
export LEAN_JOBS="${LEAN_JOBS:-2}"
export LEAN_VERDICTS="$PWD/build/verdicts"; rm -rf -- "$LEAN_VERDICTS"

{
capture_header "exp239 — the scratch the monitor scrubs"

echo ">>> the micro-monitor binary and size budget"
python3 monitor.py --check
echo

echo ">>> the formal theorems, and what they rest on"
"$LEAN" run proof/Scrub.lean | grep -E "axioms|^exit"
echo

echo ">>> wrong monitors and wrong claims: each must be refused"
"$LEAN" table proof/Scrub.lean
echo

echo ">>> exp223's kernel on fourteen sample streams, alone and under the monitor"
python3 suite/kernel_cases.py
echo

echo ">>> payloads that leave secrets in memory"
python3 suite/attack_cases.py
echo

echo ">>> monitors with one thing wrong: each must be caught"
python3 suite/broken_monitors.py
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
