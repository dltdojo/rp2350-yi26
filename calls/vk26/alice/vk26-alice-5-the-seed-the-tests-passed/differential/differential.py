#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""vk26-alice-5 — the three kernels on the Lean model (rv32run) and on the
Hazard3 RTL, chained as the shell chains them, against seed.py.

  differential.py RV32RUN KERNEL TRUST DRBG     PASS/FAIL lines; exit 0 = all pass

KERNEL is this experiment's Instantiate kernel; TRUST and DRBG are
vk26-alice-2's and vk26-alice-4's, as alice's package writes them.

Every NIST case: the Instantiate kernel on the seed material NIST's entropy,
nonce and personalization string make; the region it leaves must be
seed.py's, and the model must halt after exactly INST_COST. Then
vk26-alice-4's Generate twice on what it left, the second's blocks NIST's.

Then every stream of alice's trustref.py (vk26-alice-2's) through the whole chain, the
nonce a round number: alice-2's kernel halts with trust.py's code; with 0,
the Instantiate kernel and the Generate follow, and the blocks are seed.py's
chain. A KAT the hash fails stops the chain at the first kernel.
"""
import os
import struct
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
EXP = os.path.join(HERE, "..")
TOOLS = os.path.join(EXP, "..", "..", "..", "..", "tools", "hazard3")
sys.path.insert(0, EXP)
sys.path.insert(0, os.path.join(TOOLS, "shell"))
sys.path.insert(0, os.path.join(EXP, "..", "tools"))
from expect import model  # noqa: E402
from region import rtl_region  # noqa: E402
from hashdrbg import OUT, cavp_cases  # noqa: E402
from trustref import OUTPUT, bad_wants, image as trust_image, trust_outcome, trust_streams  # noqa: E402
from seed import INTERVAL, NONCE, PI, chain, inst_image, inst_region, load_code, nonce_of  # noqa: E402

# proof/Seed.lean's count, to the halt.
INST_COST = 241
M = 4


def run(rv32run, img, where, fuel):
    """One kernel from `img` on `where`: (halt code or None, the outcome line, the region)."""
    if where == "model":
        ran, region = model(rv32run, img, fuel)
    else:
        ran, region = rtl_region(img, 5000000)
    said = ran.split()
    code = int(said[1].split("=")[1], 16) if said[:1] == ["halt"] else None
    return code, ran, region


def nist(rv32run, kernels, case, where):
    inst, _, drbg = kernels
    problems = []
    img = inst_image(load_code(b"", inst), case["entropy"] + case["nonce"] + case["pers"], M)
    code, ran, region = run(rv32run, img, where, INST_COST + 10)
    if code != 0 or (where == "model" and f"count={INST_COST}" not in ran):
        problems.append(f"Instantiate: {ran}")
    if region != inst_region(img):
        problems.append("Instantiate's region is not seed.py's")
    for _ in range(2):
        code, ran, region = run(rv32run, load_code(region, drbg), where, 5000)
        if code != 0:
            problems.append(f"Generate: {ran}")
    if region[OUT:OUT + 32 * M] != case["want"]:
        problems.append("the second Generate's blocks are not NIST's")
    return problems, ran


def chain_image(trust, words, nonce, want=None):
    r = bytearray(trust_image(trust, words, want)) + bytes(0x10000 - OUTPUT)
    r[NONCE:NONCE + len(nonce)] = nonce
    r[PI:PI + 12] = struct.pack("<3I", M, INTERVAL, 32 + len(nonce))
    return bytes(r)


def through(rv32run, kernels, words, nonce, want, where):
    """The chain on `where`: (alice-2's code, the blocks or None, the problems)."""
    inst, trust, drbg = kernels
    problems = []
    img = chain_image(trust, words, nonce, want)
    code, ran, region = run(rv32run, img, where, 40000)
    expect, writes, _ = trust_outcome(words, want)
    if code != expect:
        problems.append(f"alice-2's kernel: {ran}, not halt {expect}")
    if code != 0:
        return code, None, problems
    code, ran, region = run(rv32run, load_code(region, inst), where, INST_COST + 10)
    if code != 0:
        problems.append(f"Instantiate: {ran}")
    code, ran, region = run(rv32run, load_code(region, drbg), where, 5000)
    if code != 0:
        problems.append(f"Generate: {ran}")
    return 0, region[OUT:OUT + 32 * M], problems


def differential():
    rv32run = sys.argv[1]
    kernels = tuple(open(p, "rb").read() for p in sys.argv[2:5])
    failed = 0
    cases = cavp_cases()
    jobs = [(c, w) for c in cases for w in ("model", "rtl")]
    with ThreadPoolExecutor(4) as pool:
        results = list(pool.map(lambda j: nist(rv32run, kernels, *j), jobs))
    bad = [(c["name"], w, p) for (c, w), (p, _) in zip(jobs, results) if p]
    for name, w, p in bad[:5]:
        print(f"FAIL  {name} on the {w}: {'; '.join(p)}")
    if not bad:
        print(f"PASS  all {len(cases)} NIST cases, on the model and on the RTL: the Instantiate kernel's region "
              f"seed.py's, the model after {INST_COST} instructions, then vk26-alice-4's Generate twice from it, "
              f"the second's 1024 bits NIST's ReturnedBits")
    failed |= bool(bad)

    streams = list(trust_streams().items())
    runs = [(f"{name}, nonce {k}", words, nonce_of(k), None) for k, (name, words) in enumerate(streams)]
    runs += [(f"fair, a KAT the hash fails ({what})", streams[0][1], nonce_of(99), want)
             for what, want in bad_wants().items()]
    for name, words, nonce, want in runs:
        code, bits, why = chain(words, nonce, M, want)
        problems = []
        for w in ("model", "rtl"):
            got_code, got_bits, p = through(rv32run, kernels, words, nonce, want, w)
            problems += [f"{w}: {x}" for x in p]
            if got_code != code or got_bits != bits:
                problems.append(f"{w}: code {got_code}, blocks {'seed.py' if got_bits == bits else 'not seed.py'}'s")
        if problems:
            failed = 1
            print(f"FAIL  {name}: {'; '.join(problems)}")
        else:
            print(f"PASS  {name}: the model and the RTL stop with alice-2's halt {code}"
                  + (", then Instantiate and Generate: seed.py's 1024 bits" if code == 0 else ", nothing after it"))
    sys.exit(failed)


if __name__ == "__main__":
    differential()
