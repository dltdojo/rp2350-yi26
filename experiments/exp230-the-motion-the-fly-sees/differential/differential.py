#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp230 — kernel.bin on the Lean model (rv32run) and on the Hazard3 RTL,
against fly.py.

  differential.py RV32RUN KERNEL [N]     PASS/FAIL lines; exit 0 = all pass

Every named stimulus and N random ones run on the model; the named ones and
the first few random run on the RTL too, whose region is dumped and read
back. Each must halt with 0 and leave every step's two counts and the totals
fly.py computes, in one count of instructions whatever the frames.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools", "hazard3", "shell"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools", "hazard3"))
from expect import model  # noqa: E402
from sigfile import read_sig  # noqa: E402
from fly import fly_cases, fly_image, fly_ref, result_of, stimuli  # noqa: E402

FUEL = 200000
SIM = os.path.join(HERE, "..", "..", "..", "tools", "hazard3", "sim.sh")
RTL_RANDOM = 3


def rtl_region(image):
    with tempfile.TemporaryDirectory() as work:
        img, dump = os.path.join(work, "image.bin"), os.path.join(work, "region.sig")
        open(img, "wb").write(image)
        out = subprocess.run([SIM, "run", img, "--dump", "4096", dump, "--cycles", "2000000"],
                             capture_output=True, text=True).stdout.strip()
        return out, read_sig(dump)


def fly_differential(rv32run, kernel, n):
    cases = fly_cases(n)
    n_rtl = len(stimuli()) + min(n, RTL_RANDOM)
    failed, counts, rtl_counts = 0, set(), set()
    for k, (name, frames) in enumerate(cases):
        img = fly_image(kernel, frames)
        want = fly_ref(frames)
        ran, region = model(rv32run, img, FUEL)
        ok = ran.startswith("halt code=00000000") and result_of(region) == want
        counts.add(ran.split("count=")[1].split()[0] if "count=" in ran else ran)
        if k < n_rtl:
            out, rregion = rtl_region(img)
            ok &= out.startswith("halt code=00000000 ") and result_of(rregion) == want
            rtl_counts.add(" ".join(w for w in out.split() if w.startswith(("instret=", "cycles="))))
        if k < len(stimuli()):
            steps, up, down = want
            s_up = sum(1 for u, d in steps if u > d)
            s_dn = sum(1 for u, d in steps if d > u)
            print(f"      {name:18} up {up:5}  down {down:5}  {'up' if up > down else 'down' if down > up else 'no way'}"
                  f"   steps: {s_up} up, {len(steps) - s_up - s_dn} not moving, {s_dn} down")
        if not ok:
            failed += 1
            if failed <= 5:
                print(f"FAIL  {name}: model {ran}")
    print(f"{'FAIL' if failed else 'PASS'}  {len(cases)} stimuli on the model, the first {n_rtl} on the RTL too: "
          f"each halts with 0 and leaves every step's counts and the totals fly.py computes — {failed} wrong")
    same = len(counts) == 1 and len(rtl_counts) == 1
    print(f"{'PASS' if same else 'FAIL'}  one count whatever the frames: model {sorted(counts)}; RTL {sorted(rtl_counts)}")
    return failed or not same


if __name__ == "__main__":
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 50
    sys.exit(1 if fly_differential(sys.argv[1], open(sys.argv[2], "rb").read(), n) else 0)
