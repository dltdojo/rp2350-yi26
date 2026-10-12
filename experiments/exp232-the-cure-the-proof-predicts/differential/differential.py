#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp232 — the differential: on many patients and schedules, the Lean model
(rv32run) and the Hazard3 RTL each run kernel.bin, and each region afterwards
must be exactly the image with cure.py's 64 generations from 0x200 — cure.py
being the rule written cell by cell, sharing nothing with the kernel's
shifts. The model must halt with 0 after exactly 3081, and the RTL with 0.

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
from cure import HIST_OFF, M, lifetime_bytes, image, lump, search  # noqa: E402
from expect import kernel_bin, model  # noqa: E402
from sigfile import read_sig  # noqa: E402

SIM = os.path.join(EXP, "..", "..", "tools", "hazard3", "sim.sh")


def cases():
    """Named inputs, then random bodies: the enrolled lumps under the answer
    and the loophole, an untreated patient, a healthy body dosed every day, a
    body all tumour, an empty one, and random gaps, tissue and tumour."""
    answer, _, _, loophole = search()
    named = [(lump(w), ~lump(w) & M, s) for w in (1, 6) for s in (answer, loophole)]
    named += [(lump(3, 20), ~lump(3, 20) & M, 0), (0, M, M), (M, 0, M), (0, 0, 0)]
    rng = random.Random(232)
    rand = []
    for _ in range(12):
        t = rng.getrandbits(32)
        rand.append((t, rng.getrandbits(32) & ~t & M, rng.getrandbits(32)))
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
    for t, h, s in cs:
        img = image(kernel, t, h, s)
        want = bytearray(img) + bytearray(0x10000 - len(img))
        want[HIST_OFF:HIST_OFF + 512] = lifetime_bytes(t, h, s)
        ran, region = model(rv32run, img, 4000)
        ok_model = ran == "halt code=00000000 count=3081" and region == bytes(want)
        rran, rregion = rtl_region(img)
        ok_rtl = rran.startswith("halt code=00000000 ") and rregion == bytes(want)
        counts.add(" ".join(w for w in rran.split() if w.startswith("instret=")))
        if not (ok_model and ok_rtl):
            failed += 1
            print(f"FAIL  t={t:08x} h={h:08x} s={s:08x}: model {ran} {'ok' if ok_model else 'differs'}, "
                  f"RTL {rran} {'ok' if ok_rtl else 'differs'}")
    if failed == 0:
        print(f"PASS  on {len(cs)} inputs the Lean model halts with 0 after exactly 3081 and the RTL with 0, "
              f"each leaving exactly cure.py's 64 generations and nothing else; the RTL's {' '.join(sorted(counts))}")
    if len(counts) != 1:
        failed += 1
        print(f"FAIL  the RTL counted differently for different inputs: {counts}")
    return failed


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(1 if main(sys.argv[1]) else 0)
