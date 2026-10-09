#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp225 — the differential: on many seeds, the Lean model (rv32run) and the
Hazard3 RTL each run kernel.bin, and each region afterwards must be exactly
the image with rule30.py's 256 generations from 0x200 — rule30.py being Rule
30 written cell by cell, sharing nothing with the kernel's shifts. The model
must halt with 0 after exactly 3079, and the RTL with 0.

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
from rule30 import HIST_OFF, SEED0, history_bytes, image  # noqa: E402
from sigfile import read_sig  # noqa: E402

SIM = os.path.join(EXP, "..", "..", "tools", "hazard3", "sim.sh")


def seeds():
    rng = random.Random(225)
    return [SEED0, 0, 1, 0xffffffff, 0x80000000, 0xaaaaaaaa] + [rng.getrandbits(32) for _ in range(14)]


def rtl_region(img):
    with tempfile.TemporaryDirectory() as work:
        p, sig = os.path.join(work, "image.bin"), os.path.join(work, "region.sig")
        open(p, "wb").write(img)
        ran = subprocess.run([SIM, "run", p, "--dump", "65536", sig], capture_output=True, text=True).stdout.strip()
        return ran, read_sig(sig)[:0x10000] if os.path.exists(sig) else b""


def main(rv32run):
    kernel, _ = kernel_bin(os.path.join(EXP, "kernel"))
    failed = 0
    ss = seeds()
    for seed in ss:
        img = image(kernel, seed)
        want = bytearray(img) + bytearray(0x10000 - len(img))
        want[HIST_OFF:HIST_OFF + 1024] = history_bytes(seed)
        ran, region = model(rv32run, img, 4000)
        ok_model = ran == "halt code=00000000 count=3079" and region == bytes(want)
        rran, rregion = rtl_region(img)
        ok_rtl = rran.startswith("halt code=00000000 ") and rregion == bytes(want)
        if not (ok_model and ok_rtl):
            failed += 1
            print(f"FAIL  seed {seed:#010x}: model {ran} {'ok' if ok_model else 'differs'}, "
                  f"RTL {rran} {'ok' if ok_rtl else 'differs'}")
    if failed == 0:
        print(f"PASS  on {len(ss)} seeds the Lean model halts with 0 after exactly 3079 and the RTL with 0, "
              f"each leaving exactly rule30.py's 256 generations and nothing else")
    return failed


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(1 if main(sys.argv[1]) else 0)
