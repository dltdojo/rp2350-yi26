#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp210 run — the cloud half, recorded to capture.txt. The board half is a
# person saying "slow" or "fast"; its result goes in the README by hand.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

{
capture_header "exp210 — the hash the chip computes (cloud half)"

echo ">>> every check"
./check.sh
echo

echo ">>> every case, as gen.py found it on the Lean model and the RTL harness"
cat build/gen.txt
echo

echo ">>> the same cases under the shell on the Hazard3 RTL (HASH in software)"
python3 - build/sim-words.txt build/gen.txt <<'PY'
import sys
words = open(sys.argv[1]).read().split()
names = [line.split()[0] + (" (Lamport)" if " kernel 0 " in line else " (WOTS)")
         for line in open(sys.argv[2]) if " verdict " in line]
print(f"{'case':34} ok  failed  a0  minstret")
for i in range(0, len(words), 7):
    if words[i] != "43415345":
        print(" ".join(words[i:]))
        break
    n, ok, failed, a0, instret = (int(w, 16) for w in words[i + 1:i + 6])
    print(f"{names[n]:34} {ok}   {failed or '-':6}  {a0}   {instret}")
PY
} 2>&1 | tee capture.txt
