#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""vk26-alice-3 — kernel.bin on the Lean model (rv32run) and on the Hazard3
RTL, against count.py: every stream in count.count_streams().

  differential.py RV32RUN      PASS/FAIL lines; exit 0 = all pass

For each: the model and the RTL halt with 0; the model after exactly COUNT
instructions; each region afterwards is the image with count.py's histogram
and largest count and nothing else. And, across all of them, the RTL takes
the same number of cycles: what the proof's constant time says an observer
of the core sees, measured on the core.
"""
import os
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
EXP = os.path.join(HERE, "..")
TOOLS = os.path.join(EXP, "..", "..", "..", "..", "tools", "hazard3")
sys.path.insert(0, EXP)
sys.path.insert(0, os.path.join(TOOLS, "shell"))
sys.path.insert(0, TOOLS)
sys.path.insert(0, os.path.join(EXP, "..", "tools"))
from expect import model  # noqa: E402
from region import rtl_region as rtl  # noqa: E402
from count import count_image, count_outcome, count_streams, histogram  # noqa: E402

# Instructions to the halt: 8 to set up; for each of 256 values, 2, then 6
# for each of 4096 samples, then 9; then 4.
COUNT = 8 + 256 * (2 + 6 * 4096 + 9) + 4


def one(rv32run, kernel, samples):
    """The model's and the RTL's runs of one stream, and what is wrong with them."""
    img = count_image(kernel, samples)
    expected = bytearray(img) + bytes(0x10000 - len(img))
    for at, b in count_outcome(samples).items():
        expected[at:at + len(b)] = b
    ran, region = model(rv32run, img, COUNT + 10)
    rtl_ran, rtl_region = rtl(img, cycles=20000000)
    problems = []
    if ran != f"halt code=00000000 count={COUNT}":
        problems.append(f"model: {ran}")
    if region != bytes(expected):
        problems.append("the model's region is not the image with count.py's histogram")
    said = rtl_ran.split()
    if said[:2] != ["halt", "code=00000000"]:
        problems.append(f"RTL: {rtl_ran}")
    if rtl_region[:len(expected)] != bytes(expected):
        problems.append("the RTL's region is not the image with count.py's histogram")
    return problems, said[3] if len(said) > 3 else None


def main():
    kernel = open(os.path.join(EXP, "kernel.bin"), "rb").read()
    streams = count_streams()
    # Four at a time: a run is ~34 s on the model and ~8 s on the RTL.
    with ThreadPoolExecutor(4) as pool:
        results = list(pool.map(lambda smp: one(sys.argv[1], kernel, smp), streams.values()))
    failed, cycles = 0, set()
    for (name, samples), (problems, cyc) in zip(streams.items(), results):
        cycles.add(cyc)
        if problems:
            failed = 1
            print(f"FAIL  {name}: {'; '.join(problems)}")
        else:
            print(f"PASS  {name}: the model and the RTL halt with 0, the model after {COUNT}; the most "
                  f"{max(histogram(samples))}, and the whole histogram, count.py's")
    if len(cycles) == 1 and None not in cycles:
        print(f"PASS  the RTL takes the same time on all {len(streams)} streams: {next(iter(cycles))}")
    else:
        failed = 1
        print(f"FAIL  the RTL takes the same time on every stream — {sorted(map(str, cycles))}")
    sys.exit(failed)


if __name__ == "__main__":
    main()
