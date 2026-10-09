#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp224 — judge.bin on the Lean model (rv32run) and on the Hazard3 RTL,
against facts.py's verdict, over every case in facts.cases().

  differential.py RV32RUN      PASS/FAIL lines; exit 0 = all pass

For each case: the model and the RTL halt with the code facts.py says, and
the model's region afterwards is the image, untouched.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools", "hazard3", "shell"))
from expect import model, rtl  # noqa: E402
from facts import cases, image, verdict  # noqa: E402


def main():
    judge = open(os.path.join(HERE, "..", "judge.bin"), "rb").read()
    failed = 0
    for name, recs in cases().items():
        img = image(judge, recs)
        want = verdict(recs)
        ran, region = model(sys.argv[1], img, 2000, wide=True)
        rtl_ran = rtl(img, wide=True)
        problems = []
        if not ran.startswith(f"halt code={want:08x} "):
            problems.append(f"model: {ran}")
        if region[:len(img)] != img or any(region[len(img):]):
            problems.append("the model's region is not the image")
        if not rtl_ran.startswith(f"halt code={want:08x} "):
            problems.append(f"RTL: {rtl_ran}")
        said = f"verdict {want & 7}, source {want >> 3 & 7}, failures {want >> 6:05b}"
        if problems:
            failed = 1
            print(f"FAIL  {name}: {said} — {'; '.join(problems)}")
        else:
            print(f"PASS  {name}: the model and the RTL halt with {want:#x} ({said}), the model's region untouched")
    sys.exit(failed)


if __name__ == "__main__":
    main()
