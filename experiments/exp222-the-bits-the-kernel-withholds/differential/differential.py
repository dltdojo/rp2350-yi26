#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp222 — kernel.bin on the Lean model (rv32run) and on the Hazard3 RTL,
against exp114's health tests in Python, over every stream in
tools/hazard3/shell/streams.py.

  differential.py RV32RUN      PASS/FAIL lines; exit 0 = all pass

For each stream: the model and the RTL halt with the same code, and it is
exp114's verdict (0 healthy, 1 not); the model's count is the one for that
verdict; and the model's region afterwards is the image with the samples
copied to the output when healthy, and the image unchanged when not.
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools", "hazard3", "shell"))
from expect import model, rtl  # noqa: E402
from streams import N, healthy, streams  # noqa: E402

SAMPLES, OUT = 0x1000, 0x2000
COUNT = {True: 23574, False: 17427}


def image(kernel, words):
    img = bytearray(0x10000)
    img[:len(kernel)] = kernel
    img[SAMPLES:SAMPLES + 4 * N] = struct.pack(f"<{N}I", *words)
    return bytes(img)


def main():
    kernel = open(os.path.join(HERE, "..", "kernel.bin"), "rb").read()
    failed = 0
    for name, words in streams().items():
        ok, why = healthy(words)
        img = image(kernel, words)
        want_code = 0 if ok else 1
        ran, region = model(sys.argv[1], img, 30000)
        want_region = bytearray(img)
        if ok:
            want_region[OUT:OUT + 4 * N] = img[SAMPLES:SAMPLES + 4 * N]
        rtl_ran = rtl(img)
        problems = []
        if ran != f"halt code={want_code:08x} count={COUNT[ok]}":
            problems.append(f"model: {ran}")
        if region != bytes(want_region):
            problems.append("the model's region is not the image with the output as said")
        if not rtl_ran.startswith(f"halt code={want_code:08x} "):
            problems.append(f"RTL: {rtl_ran}")
        verdict = "healthy" if ok else f"withheld: {why}"
        if problems:
            failed = 1
            print(f"FAIL  {name}: exp114 says {verdict} — {'; '.join(problems)}")
        else:
            print(f"PASS  {name}: exp114 says {verdict}; the model and the RTL halt with {want_code}, "
                  f"the model after {COUNT[ok]}, its region as said")
    sys.exit(failed)


if __name__ == "__main__":
    main()
