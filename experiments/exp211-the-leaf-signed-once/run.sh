#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp211 run — the cloud half, recorded to capture.txt. The board half is a
# person pulling the power and reading the LED; its result goes in the README
# by hand.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

{
capture_header "exp211 — the leaf signed once (cloud half)"

echo ">>> every check"
./check.sh
echo

echo ">>> the model, design by attacker"
../../tools/tlc/tlc.sh table model
echo

echo ">>> every leaf on the Lean model, as gen.py found it"
cat build/gen.txt
echo

echo ">>> the shell on the Hazard3 RTL, booted 18 times over one flash"
python3 - build/sim-words.txt <<'PY'
import sys
w = sys.argv[1] and open(sys.argv[1]).read().split()
names = ["signed", "exhausted", "corrupt", "unwritten", "kernel", "sign failed", "rejected"]
steps = {2: "in a flash write", 3: "in the window"}
print(f"{'boot':5} {'what happened':28} leaf  used  done  wasted")
i = 0
while i < len(w):
    tag = w[i]
    if tag == "4355545f":
        boot, step = int(w[i + 1], 16), int(w[i + 2], 16)
        print(f"{boot:<5} {'power cut ' + steps.get(step, str(step)):28}")
        i += 3
    elif tag == "424f4f54":
        boot, out, leaf, used, done, wasted = (int(x, 16) for x in w[i + 1:i + 7])
        print(f"{boot:<5} {names[out]:28} {leaf if out == 0 else '-':<5} {used:<5} {done:<5} {wasted}")
        i += 7
    else:
        print(" ".join(w[i:]))
        break
PY
} 2>&1 | tee capture.txt
