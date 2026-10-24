#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp245's monitor.bin: monitor.S assembled, its hash, its size, the words proof/Bless.lean runs, and the charms
taken away.

  monitor.py --check          exit 0 = all hold
  monitor.py --emit-lean      monitorCode, as proof/Bless.lean has it
  monitor.py --ablate 1,3     print monitor.S with those charms taken away

A charm is marked in monitor.S: the lines between `// [Charm N] {` and `// [Charm N] }` are added, and a line ending
`// [Charm N] exp240: X` is exp240's line X, changed. `ablate` takes them away; with all three gone, and with any one
alone gone but the other two kept, the check below wants what that is: all three gone is exp240's monitor.bin, byte
for byte.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools", "monitor"))
import binary

EXP240 = os.path.join(HERE, "..", "exp240-the-code-the-box-forbids-writing")
CHARMS = (1, 2, 3)
WAS = re.compile(r"^(\s*).*// \[Charm (\d)\] exp240: (.*)$")


def ablate(src: str, charms) -> str:
    """monitor.S with `charms` taken away: their blocks dropped, their changed lines put back as exp240 had them."""
    out, skip = [], None
    for line in src.split("\n"):
        m = re.match(r"^\s*// \[Charm (\d)\] ([{}])\s*$", line)
        if m and int(m.group(1)) in charms:
            skip = int(m.group(1)) if m.group(2) == "{" else None
            continue
        if skip is not None:
            continue
        w = WAS.match(line)
        if w and int(w.group(2)) in charms:
            line = w.group(1) + w.group(3)
        out.append(line)
    return "\n".join(out)


def source() -> str:
    with open(os.path.join(HERE, "monitor.S")) as f:
        return f.read()


def ablated(charms) -> bytes:
    return binary.assembled(ablate(source(), charms))


def check_ablation() -> list:
    bad = []
    with open(os.path.join(EXP240, "monitor.bin"), "rb") as f:
        exp240 = f.read()
    if ablated(CHARMS) != exp240:
        bad.append("monitor.S with all three charms taken away is not exp240's monitor.bin")
    full = binary.assembled(source())
    for c in CHARMS:
        alone = ablated([c])
        if alone == full or alone == exp240:
            bad.append(f"taking charm {c} away changes nothing, or everything")
    return bad


if __name__ == "__main__":
    if "--ablate" in sys.argv:
        print(ablate(source(), [int(x) for x in sys.argv[sys.argv.index("--ablate") + 1].split(",")]), end="")
        sys.exit(0)
    status = binary.cli(HERE, 200, "proof/Bless.lean")
    if "--emit-lean" in sys.argv:
        sys.exit(status)
    bad = check_ablation()
    for b in bad:
        print(f"FAIL  {b}")
    if not bad:
        print("PASS  monitor.S with the three charms taken away is exp240's monitor.bin, byte for byte; "
              "each charm taken away alone changes the binary")
    sys.exit(status or (1 if bad else 0))
