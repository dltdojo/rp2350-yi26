#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp229 — kernel.bin on the Lean model (rv32run) and on the Hazard3 RTL,
against Python's integers modulo p.

  differential.py RV32RUN KERNEL [N]     PASS/FAIL lines; exit 0 = all pass

Every edge pair of every operation and N drawn ones run on the model; the
edge pairs and the first 60 drawn run on the RTL too, whose whole region is
dumped and read back. Each must halt with 0 and leave (a op b) mod p in R,
and the count must be the same for every case of one operation: the model's
instructions, and the RTL's instructions and cycles.
"""
import os
import sys
import tempfile
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools", "hazard3", "shell"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools", "hazard3"))
from expect import model  # noqa: E402
from sigfile import read_sig  # noqa: E402
from field import OPS, field_cases, field_image, field_ref, result_of  # noqa: E402

FUEL = 100000
SIM = os.path.join(HERE, "..", "..", "..", "tools", "hazard3", "sim.sh")


def rtl_region(image):
    with tempfile.TemporaryDirectory() as work:
        img, dump = os.path.join(work, "image.bin"), os.path.join(work, "region.sig")
        open(img, "wb").write(image)
        out = subprocess.run([SIM, "run", img, "--dump", "4096", dump, "--cycles", "2000000"],
                             capture_output=True, text=True).stdout.strip()
        return out, read_sig(dump)


def field_differential(rv32run, kernel, n):
    cases = field_cases(n)
    n_rtl = len(cases) - n + min(n, 60)
    failed, counts, rtl_counts = 0, {}, {}
    for k, (op, a, b) in enumerate(cases):
        img = field_image(kernel, op, a, b)
        want = field_ref(op, a, b)
        ran, region = model(rv32run, img, FUEL)
        ok = ran.startswith("halt code=00000000") and result_of(region) == want
        counts.setdefault(op, set()).add(ran.split("count=")[1].split()[0] if "count=" in ran else ran)
        if k < n_rtl:
            out, rregion = rtl_region(img)
            ok &= out.startswith("halt code=00000000 ") and result_of(rregion) == want
            rtl_counts.setdefault(op, set()).add(" ".join(w for w in out.split() if w.startswith(("instret=", "cycles="))))
        if not ok:
            failed += 1
            if failed <= 5:
                print(f"FAIL  {OPS[op]} {a:#x} {b:#x}: model {ran} {result_of(region):#x}, want {want:#x}")
    print(f"{'FAIL' if failed else 'PASS'}  {len(cases)} cases on the model, the first {n_rtl} on the RTL too: "
          f"each halts with 0 and leaves (a op b) mod p — {failed} wrong")
    same = all(len(v) == 1 for v in counts.values()) and all(len(v) == 1 for v in rtl_counts.values())
    print(f"{'PASS' if same else 'FAIL'}  one count per operation, whatever the numbers: model "
          + ", ".join(f"{OPS[op]} {sorted(v)}" for op, v in sorted(counts.items()))
          + "; RTL " + ", ".join(f"{OPS[op]} {sorted(v)}" for op, v in sorted(rtl_counts.items())))
    return failed or not same


if __name__ == "__main__":
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 200
    sys.exit(1 if field_differential(sys.argv[1], open(sys.argv[2], "rb").read(), n) else 0)
