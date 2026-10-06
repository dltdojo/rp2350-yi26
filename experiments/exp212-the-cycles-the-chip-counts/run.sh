#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp212 run — the cloud half, recorded to capture.txt. The board half is a
# person saying "slow", "double" or "fast"; its result goes in the README by
# hand.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

{
capture_header "exp212 — the cycles the chip counts (cloud half)"

echo ">>> every check"
./check.sh
echo

echo ">>> the RTL harness, once per kind of run"
cat build/rtl.txt
echo

echo ">>> every run the chip will make, as gen.py found it on the Lean model"
cat build/chip/gen.txt
echo

echo ">>> the same shell on the Hazard3 RTL, two seeds (HASH in software)"
python3 - build/sim-words.txt build/sim/gen.txt <<'PY'
import sys
words = open(sys.argv[1]).read().split()
names = [" ".join(line.split()[:3]) for line in open(sys.argv[2]) if " seed " in line]
print(f"{'run':18} failed  mcycle  minstret")
i = 0
while i < len(words) and words[i] == "52554e5f":
    n, failed, cycles, instret = (int(w, 16) for w in words[i + 1:i + 5])
    print(f"{names[n]:18} {failed or '-':6}  {cycles:6}  {instret}")
    i += 5
print(" ".join(words[i:]))
PY
} 2>&1 | tee capture.txt
