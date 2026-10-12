#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp234 — the differential: on many patients and masks, the Lean model
(rv32run) and the Hazard3 RTL each run kernel.bin, and each region afterwards
must be exactly the image with exp232's cure.py's world — written cell by
cell, sharing nothing with the kernel — in 64 generations from 0x400. The
model must halt with 0 after exactly 4043, and the RTL with 0, counting the
same for every input.

  differential.py RV32RUN
"""
import os
import random
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
EXP = os.path.join(HERE, "..")
sys.path.insert(0, EXP)
sys.path.insert(0, os.path.join(EXP, "..", "..", "tools", "hazard3"))
sys.path.insert(0, os.path.join(EXP, "..", "..", "tools", "hazard3", "shell"))
from expect import kernel_bin, model  # noqa: E402
from sigfile import read_sig  # noqa: E402
from world import HIST_OFF, cure, history_bytes, world_image  # noqa: E402

SIM = os.path.join(EXP, "..", "..", "tools", "hazard3", "sim.sh")


def cases():
    """Named: an enrolled lump under the answer with no mutation (the model),
    with its own patient's masks, with every bit a mutation, untreated; a
    healthy body; then random bodies, schedules and masks."""
    answer = cure.search()[0]
    M = cure.M
    lump6 = cure.lump(6)
    named = [(lump6, ~lump6 & M, answer, [0] * 64),
             (lump6, ~lump6 & M, answer, cure.masks_of(0xd75dc8a3)),
             (lump6, ~lump6 & M, answer, [M] * 64),
             (cure.lump(3, 20), ~cure.lump(3, 20) & M, 0, cure.masks_of(0x2e8b3fbd)),
             (0, M, M, [M] * 64)]
    rng = random.Random(234)
    rand = []
    for _ in range(10):
        t = rng.getrandbits(32)
        rand.append((t, rng.getrandbits(32) & ~t & M, rng.getrandbits(32),
                     [rng.getrandbits(32) & rng.getrandbits(32) for _ in range(64)]))
    return named + rand


def rtl_region(img):
    with tempfile.TemporaryDirectory() as work:
        p, sig = os.path.join(work, "image.bin"), os.path.join(work, "region.sig")
        open(p, "wb").write(img)
        ran = subprocess.run([SIM, "run", p, "--dump", "65536", sig], capture_output=True, text=True).stdout.strip()
        return ran, read_sig(sig)[:0x10000] if os.path.exists(sig) else b""


def main(rv32run):
    kernel, _ = kernel_bin(os.path.join(EXP, "kernel"))
    failed, counts = 0, set()
    cs = cases()
    for t, h, s, masks in cs:
        img = world_image(kernel, t, h, s, masks)
        want = bytearray(img) + bytearray(0x10000 - len(img))
        want[HIST_OFF:HIST_OFF + 768] = history_bytes(t, h, s, masks)
        ran, region = model(rv32run, img, 5000)
        ok_model = ran == "halt code=00000000 count=4043" and region == bytes(want)
        rran, rregion = rtl_region(img)
        ok_rtl = rran.startswith("halt code=00000000 ") and rregion == bytes(want)
        counts.add(" ".join(w for w in rran.split() if w.startswith("instret=")))
        if not (ok_model and ok_rtl):
            failed += 1
            print(f"FAIL  t={t:08x} h={h:08x} s={s:08x}: model {ran} {'ok' if ok_model else 'differs'}, "
                  f"RTL {rran} {'ok' if ok_rtl else 'differs'}")
    if failed == 0:
        print(f"PASS  on {len(cs)} bodies and mask sets the Lean model halts with 0 after exactly 4043 and the RTL "
              f"with 0, each leaving exactly cure.py's world, 64 generations, and nothing else; the RTL's "
              f"{' '.join(sorted(counts))}")
    if len(counts) != 1:
        failed += 1
        print(f"FAIL  the RTL counted differently for different inputs: {counts}")
    return failed


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(1 if main(sys.argv[1]) else 0)
