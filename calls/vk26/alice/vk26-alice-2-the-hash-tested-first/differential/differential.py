#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""vk26-alice-2 — kernel.bin on the Lean model (rv32run) and on the Hazard3
RTL, against trust.py and hashlib's SHA-256: every stream in trust.trust_streams()
with the right expected digest, and the fair stream with each of
trust.bad_wants().

  differential.py RV32RUN      PASS/FAIL lines; exit 0 = all pass

For each: the model and the RTL halt with trust.py's code; the model after
the count for that code; and each region afterwards is the image with
trust.py's writes — the KAT's answer, and the output only with 0 — and
nothing else.
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
from trust import bad_wants, image, trust_outcome, trust_streams  # noqa: E402

# Instructions to the halt, by code: the KAT is 43 to its branch and halt;
# a window is 17415 and its branch 1; the output 7, the halt 3.
COUNT = {2: 43, 1: 43 + 17415 + 1 + 3, 3: 43 + 2 * (17415 + 1) + 3, 0: 43 + 2 * (17415 + 1) + 7 + 3}


def main():
    kernel = open(os.path.join(EXP, "kernel.bin"), "rb").read()
    fair = trust_streams()["fair"]
    cases = [(name, words, None) for name, words in trust_streams().items()]
    cases += [(f"KAT: {name}", fair, want) for name, want in bad_wants().items()]
    failed = 0
    for name, words, want in cases:
        code, writes, why = trust_outcome(words, want)
        img = image(kernel, words, want)
        expected = bytearray(img) + bytes(0x10000 - len(img))
        for at, b in writes.items():
            expected[at:at + len(b)] = b
        ran, region = model(sys.argv[1], img, 100000)
        rtl_ran, rtl_region = rtl(img)
        problems = []
        if ran != f"halt code={code:08x} count={COUNT[code]}":
            problems.append(f"model: {ran}")
        if region != bytes(expected):
            problems.append("the model's region is not the image with trust.py's writes")
        if not rtl_ran.startswith(f"halt code={code:08x} "):
            problems.append(f"RTL: {rtl_ran}")
        if rtl_region[:len(expected)] != bytes(expected):
            problems.append("the RTL's region is not the image with trust.py's writes")
        said = why or "both windows passed"
        if problems:
            failed = 1
            print(f"FAIL  {name}: {said} — {'; '.join(problems)}")
        else:
            print(f"PASS  {name}: {said}; the model and the RTL halt with {code}, the model after "
                  f"{COUNT[code]}; {'the KAT answer and the output' if code == 0 else 'the KAT answer only'} written")
    sys.exit(failed)


if __name__ == "__main__":
    main()
