#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp207 — the theorem's two runs, on the model and on the Hazard3 RTL.

  timing.py

The proof says two runs that differ only in secret bytes take the same steps.
On a core with no caches and no data-dependent latency that is the same time,
which is what this measures: exp213's key generator under two seeds, and its
signer under three seeds — each with its own tree — signing one message
under one leaf. For each, the model's count and the RTL's minstret and
mcycle must be equal across the seeds. Then the signer once more under the
first seed with another message: a public input, which may move the count,
and does — the measurement is not blind.

One key generation takes the RTL about six minutes; all of it about fifteen.
"""
import os
import random
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.join(HERE, "..", "..", "tools")
sys.path.insert(0, os.path.join(TOOLS, "hazard3"))
sys.path.insert(0, os.path.join(TOOLS, "hazard3", "shell"))
from expect import kernel_bin  # noqa: E402
from mss import keygen_image, sign_image, tree_of  # noqa: E402

KERNELS = os.path.join(HERE, "..", "exp213-the-signer-the-verifier-accepts")
SIZE = 0x10000


def runs(images, work):
    """For each image: the model's line and the RTL's."""
    rv32run = subprocess.run([os.path.join(TOOLS, "lean", "lean.sh"), "exe", "rv32run"],
                             capture_output=True, text=True).stdout.strip()
    out = []
    for name, img in images:
        path = os.path.join(work, name + ".bin")
        open(path, "wb").write(img)
        model = subprocess.run([rv32run, path, "0x80010000", hex(SIZE), "100000"],
                               capture_output=True, text=True).stdout.strip()
        rtl = subprocess.run([os.path.join(TOOLS, "hazard3", "sim.sh"), "run", path, "--cycles", "4000000000"],
                             capture_output=True, text=True).stdout.strip()
        print(f"{name:22} {model:32} {rtl}", flush=True)
        out.append((model, rtl))
    return out


def same(what, results):
    ok = len(set(results)) == 1 and results[0][0].startswith("halt code=00000000")
    print(("PASS  " if ok else "FAIL  ") + what)
    return ok


def timing():
    rng = random.Random(207)
    seeds = [bytes(rng.getrandbits(8) for _ in range(32)) for _ in range(3)]
    m = bytes(rng.getrandbits(8) for _ in range(32))
    other = bytes(rng.getrandbits(8) for _ in range(32))
    leaf = 5
    ok = True
    print(f"{'run':22} {'model at 0x80010000':32} RTL")
    with tempfile.TemporaryDirectory() as work:
        k = runs([(f"keygen-seed-{i}", keygen_image(kernel_bin(os.path.join(KERNELS, "keygen"))[0], seeds[i])) for i in range(2)], work)
        trees = [tree_of(s) for s in seeds]
        s = runs([(f"sign-seed-{i}", sign_image(kernel_bin(os.path.join(KERNELS, "sign"))[0], seeds[i], trees[i], leaf, m)) for i in range(3)],
                 work)
        c = runs([("sign-other-message", sign_image(kernel_bin(os.path.join(KERNELS, "sign"))[0], seeds[0], trees[0], leaf, other))], work)
    print()
    ok &= same("the key generator under two seeds: the same count on the model, the same minstret and mcycle "
               "on the RTL", k)
    ok &= same("the signer under three seeds, each with its tree: the same count, minstret and mcycle", s)
    moved = c[0] != s[0]
    print(("PASS  " if moved else "FAIL  ") +
          "another message — a public input — does move them: the measurement can see a difference")
    return 0 if ok and moved else 1


if __name__ == "__main__":
    sys.exit(timing())
