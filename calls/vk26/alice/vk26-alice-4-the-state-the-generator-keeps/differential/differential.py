#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""vk26-alice-4 — kernel.bin on the Lean model (rv32run) and on the Hazard3
RTL, against drbg.py.

  differential.py RV32RUN      PASS/FAIL lines; exit 0 = all pass

Every NIST case: drbg.py instantiates; the kernel generates 4 blocks; the
region it leaves, as it is, is the image of the second Generate; that
second Generate's blocks are NIST's ReturnedBits. Each run's region is the
image with drbg.outcome's bytes and nothing else, on the model and on the
RTL, each chained on its own; the model halts after exactly COST(m).

Then states chosen for their edges: carries through all 55 bytes, a sum
that wraps past 2^440, a counter whose bytes all carry, one block and
many, the counter at the interval and one past it.
"""
import os
import random
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
from drbg import OUT, SEEDLEN, cavp_cases, drbg_image, drbg_outcome, drbg_generate, drbg_instantiate  # noqa: E402


def cost(m):
    """Instructions to the halt: 4 to the reseed check, 333 to copy V, 2,
    566 a block (HASHB, and ADD's 555 for data + 1), 5 for H, three ADDs of
    558 with their calls, 7 for the counter's bytes, 5 to the halt."""
    return 4 + 333 + 2 + 566 * m + 5 + 3 * 558 + 7 + 5


RESEED = 7   # to the reseed check, then HALT 1


def expected(img, state, interval, m):
    code, writes = drbg_outcome(state, interval, m)
    out = bytearray(img) + bytes(0x10000 - len(img))
    for at, b in writes.items():
        out[at:at + len(b)] = b
    return code, bytes(out)


def one(rv32run, img, state, interval, m, where):
    """One Generate, from `img`, on `where` ('model' or 'rtl'): the region
    afterwards, and what is wrong."""
    code, want = expected(img, state, interval, m)
    if where == "model":
        ran, region = model(rv32run, img, cost(m) + 10)
        ok = ran == f"halt code={code:08x} count={cost(m) if code == 0 else RESEED}"
    else:
        ran, region = rtl(img, cycles=5000000)
        ok = ran.split()[:2] == ["halt", f"code={code:08x}"]
    problems = [] if ok else [f"{where}: {ran}"]
    if region[:len(want)] != want:
        problems.append(f"{where}'s region is not the image with drbg.py's outcome")
    return problems, region, ran


def nist(rv32run, kernel, case, where):
    """Two Generates chained through the kernel's own region; the second's blocks against NIST's."""
    state = drbg_instantiate(case["entropy"], case["nonce"], case["pers"])
    interval, m = 2 ** 32 - 2, len(case["want"]) // 32
    img = drbg_image(kernel, state, interval, m)
    p1, region, _ = one(rv32run, img, state, interval, m, where)
    _, state = drbg_generate(state, 32 * m, interval)
    p2, region2, ran = one(rv32run, region[:OUT], state, interval, m, where)
    problems = p1 + p2
    if region2[OUT:OUT + 32 * m] != case["want"]:
        problems.append(f"{where}: the second Generate's blocks are not NIST's")
    return problems, ran


def edges():
    rnd = random.Random(4)
    ff, z = b"\xff" * SEEDLEN, bytes(SEEDLEN)
    r = lambda: bytes(rnd.randrange(256) for _ in range(SEEDLEN))  # noqa: E731
    return [
        ("V and C all ones: every byte carries, and the sum wraps", (ff, ff, 1), 1000, 2),
        ("V all ones, C zero: data + 1 wraps to zero", (ff, z, 5), 1000, 3),
        ("V and C zero", (z, z, 1), 1000, 1),
        ("the counter 0x00ffffff: its bytes carry into V", (r(), r(), 0x00ffffff), 0x01000000, 2),
        ("the counter at the interval: allowed", (r(), r(), 77), 77, 1),
        ("the counter one past the interval: reseed required", (r(), r(), 78), 77, 4),
        ("the counter at 2^32 - 2, the largest the kernel allows", (r(), r(), 2 ** 32 - 2), 2 ** 32 - 2, 1),
        ("seven blocks", (r(), r(), 12345), 2 ** 20, 7),
        ("one block", (r(), r(), 2), 2 ** 20, 1),
        ("forty blocks", (r(), r(), 3), 2 ** 20, 40),
    ]


def differential():
    rv32run = sys.argv[1]
    kernel = open(os.path.join(EXP, "kernel.bin"), "rb").read()
    cases = cavp_cases()
    jobs = [(c, w) for c in cases for w in ("model", "rtl")]
    with ThreadPoolExecutor(4) as pool:
        results = list(pool.map(lambda j: nist(rv32run, kernel, *j), jobs))
    failed = 0
    bad = [(c["name"], w, p) for (c, w), (p, _) in zip(jobs, results) if p]
    rtl_counts = {ran.split()[2] for (c, w), (p, ran) in zip(jobs, results) if w == "rtl" and not p}
    if bad:
        failed = 1
        for name, w, p in bad[:5]:
            print(f"FAIL  {name} on the {w}: {'; '.join(p)}")
    else:
        print(f"PASS  all {len(cases)} NIST cases, on the model and on the RTL: two Generates of 4 blocks each, "
              f"chained through the kernel's own region, the model after {cost(4)} instructions each, every "
              f"region drbg.py's, and the second's 1024 bits NIST's ReturnedBits")
    print(f"      the RTL's minstret for a Generate of 4 blocks: {' '.join(sorted(rtl_counts))}")
    for name, state, interval, m in edges():
        img = drbg_image(kernel, state, interval, m)
        problems = []
        for w in ("model", "rtl"):
            p, _, ran = one(rv32run, img, state, interval, m, w)
            problems += p
            if w == "rtl":
                rtl_ran = ran
        code = drbg_outcome(state, interval, m)[0]
        if problems:
            failed = 1
            print(f"FAIL  {name}: {'; '.join(problems)}")
        else:
            print(f"PASS  {name}: the model and the RTL halt with {code}, the model after "
                  f"{cost(m) if code == 0 else RESEED}; the region drbg.py's  [{rtl_ran.split()[2]}]")
    sys.exit(failed)


if __name__ == "__main__":
    differential()
