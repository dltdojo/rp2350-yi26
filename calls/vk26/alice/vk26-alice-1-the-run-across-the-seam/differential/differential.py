#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""vk26-alice-1 — kernel.bin on the Lean model (rv32run) and on the Hazard3
RTL, against seam.py's tests and hashlib's SHA-256, over every stream in
seam.streams().

  differential.py RV32RUN      PASS/FAIL lines; exit 0 = all pass

For each stream: the model and the RTL halt with seam.py's code (0 if every
window passed, else the failing window's number); the model's count is the
one for that code; the 32 bytes for each window that passed are hashlib's
SHA-256 of its 4096 bytes, on both; and the model's region afterwards is the
image with those digests and nothing else.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EXP = os.path.join(HERE, "..")
TOOLS = os.path.join(EXP, "..", "..", "..", "..", "tools", "hazard3")
sys.path.insert(0, EXP)
sys.path.insert(0, os.path.join(TOOLS, "shell"))
sys.path.insert(0, TOOLS)
sys.path.insert(0, os.path.join(EXP, "..", "tools"))
from expect import model  # noqa: E402
from region import rtl_region as rtl  # noqa: E402
from seam import DIGESTS, WINDOWS, image, seam_outcome, streams  # noqa: E402

PASS_COST, FAIL_COST, INIT, DONE = 17421, 17419, 12, 3


def count(code):
    """Instructions to the halt: every window that passed, then the one that
    failed and FAIL, or the halt after the fourth."""
    if code == 0:
        return INIT + WINDOWS * PASS_COST + DONE
    return INIT + (code - 1) * PASS_COST + FAIL_COST


def main():
    kernel = open(os.path.join(EXP, "kernel.bin"), "rb").read()
    failed = 0
    for name, words in streams().items():
        code, digests, why = seam_outcome(words)
        img = image(kernel, words)
        want = bytearray(img) + bytes(0x10000 - len(img))
        for w, d in enumerate(digests):
            want[DIGESTS + 32 * w:DIGESTS + 32 * w + 32] = d
        ran, region = model(sys.argv[1], img, 100000)
        rtl_ran, rtl_region = rtl(img)
        problems = []
        if ran != f"halt code={code:08x} count={count(code)}":
            problems.append(f"model: {ran}")
        if region != bytes(want):
            problems.append("the model's region is not the image with the digests")
        if not rtl_ran.startswith(f"halt code={code:08x} "):
            problems.append(f"RTL: {rtl_ran}")
        if rtl_region[:len(want)] != bytes(want):
            problems.append("the RTL's region is not the image with the digests")
        said = why or "every window passed"
        if problems:
            failed = 1
            print(f"FAIL  {name}: {said} — {'; '.join(problems)}")
        else:
            print(f"PASS  {name}: {said}; the model and the RTL halt with {code}, the model after "
                  f"{count(code)}; {len(digests)} digest(s), hashlib's, and nothing else written")
    sys.exit(failed)


if __name__ == "__main__":
    main()
