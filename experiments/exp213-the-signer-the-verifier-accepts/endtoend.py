#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp213 — the three binaries in a row, on one executor, as the end-to-end
theorem has them: keygen's tree into sign's image, sign's region into
exp206's verifier with only the code replaced.

  endtoend.py RUN LEAF...

RUN is `model` (rv32run at the RTL's base) or `rtl` (tools/hazard3/sim.sh).
For each leaf, one line: keygen's, sign's and verify's outcomes; then one
PASS/FAIL line, and exit 0 when keygen and sign halt with 0, verify accepts
every leaf, and the tree is what Python makes of the seed. It is
proof/Complete.lean's `three_binaries`, run: the same images, the same
copying.
Only the copying between runs is this script's — the shell's job on a chip,
and outside every theorem.
"""
import os
import random
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.join(HERE, "..", "..", "tools")
sys.path.insert(0, os.path.join(TOOLS, "hazard3"))
from sigfile import read_sig  # noqa: E402
import images  # noqa: E402

VERIFY = os.path.join(HERE, "..", "exp206-the-root-the-path-climbs", "kernel.bin")
SIZE = 0x10000


def runner(kind):
    if kind == "model":
        rv32run = subprocess.run([os.path.join(TOOLS, "lean", "lean.sh"), "exe", "rv32run"],
                                 capture_output=True, text=True).stdout.strip()
        return lambda img, dump: [rv32run, img, "0x80010000", hex(SIZE), "100000", str(SIZE), dump]
    return lambda img, dump: [os.path.join(TOOLS, "hazard3", "sim.sh"), "run", img, "--dump", str(SIZE), dump,
                              "--cycles", "4000000000"]


def run(cmd, work, name, data):
    img, dump = os.path.join(work, name + ".bin"), os.path.join(work, name + ".sig")
    open(img, "wb").write(data)
    out = subprocess.run(cmd(img, dump), capture_output=True, text=True).stdout.strip()
    return out, read_sig(dump)[:SIZE]


def endtoend():
    cmd, leaves = runner(sys.argv[1]), [int(a) for a in sys.argv[2:]]
    seed = bytes(random.Random(2130).getrandbits(8) for _ in range(32))
    bad = 0
    with tempfile.TemporaryDirectory() as work:
        k_out, k_reg = run(cmd, work, "keygen", images.image(("keygen", seed)))
        tree = bytes(k_reg[images.K_TREE:images.K_TREE + 31 * 32])
        nodes = [tree[32 * n:32 * n + 32] for n in range(31)]
        ok_tree = nodes == images.tree_of(seed)
        print(f"keygen         {k_out}  tree {'is' if ok_tree else 'is NOT'} Python's")
        bad |= not (k_out.startswith("halt code=00000000") and ok_tree)
        for leaf in leaves:
            m = bytes(random.Random(leaf).getrandbits(8) for _ in range(32))
            s_out, s_reg = run(cmd, work, f"sign{leaf}", images.image(("sign", seed, nodes, leaf, m)))
            verify = bytearray(s_reg)
            kernel = open(VERIFY, "rb").read()
            verify[:len(kernel)] = kernel
            v_out, _ = run(cmd, work, f"verify{leaf}", bytes(verify))
            print(f"leaf {leaf:2}  sign {s_out}  verify {v_out}")
            bad |= not (s_out.startswith("halt code=00000000") and v_out.startswith("halt code=00000000"))
    what = (f"keygen, sign and exp206's verify in a row on the {sys.argv[1]}: the verifier accepts "
            f"leaves {', '.join(map(str, leaves))}")
    print(("FAIL  " if bad else "PASS  ") + what)
    return bad


if __name__ == "__main__":
    sys.exit(endtoend())
