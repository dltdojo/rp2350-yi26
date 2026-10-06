#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp212 — every run the shell makes, and what it must find, computed here
and compiled in.

  gen.py rtl OUT.txt                    the RTL's numbers, one line per kind
  gen.py expect OUT.h RV32RUN RTL.txt NSEEDS

The kernels are exp213's keygen.bin and sign.bin, checked against their
.sha256; the images are tools/hazard3/mss.py's. Seeds and messages come from
random.Random(212), so the chip and the RTL build agree on them.

`rtl` runs three images on the Hazard3 RTL under tools/hazard3/harness —
the key generator under seed 0, the signer under seed 0 with the message,
and with the other message — and writes each one's outcome. About seven
minutes, most of it the key generator; build.sh keeps the file.

`expect` writes the schedule for NSEEDS seeds:

  keygen-warm(0), keygen(0), sign(0), sign-other(0), keygen(1), sign(1), ..., keygen(N-1), sign(N-1)

preceded by keygen-warm(0): seed 0's key generation once more, first, held
to every check but not to the cycles — the shell's first run, which revision
2 found out of line on a board. Then for every run what the chip must find
afterwards: the SHA-256 of the
whole region as the Lean model (rv32run, at 0x20070000) left it, and the
RTL's minstret and mcycle for that kind, and its HASH calls. Before writing anything:

  - every run halts with code 0 on the model, at the same count for every
    seed of a kind;
  - the tree the model's key generator leaves is mss.py's tree_of(seed), so
    the signer's image the chip builds from it is mss.py's sign_image;
  - each kind's RTL line halts with code 0, at the minstret count + 3 + 4·S
    where S is that kind's HASH calls.
"""
import hashlib
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.join(HERE, "..", "..", "tools", "hazard3")
sys.path.insert(0, TOOLS)
sys.path.insert(0, os.path.join(TOOLS, "shell"))
import mss  # noqa: E402
from expect import REGION_SIZE, c_bytes, kernel_bin, model, rtl  # noqa: E402

KERNELS = os.path.join(HERE, "..", "exp213-the-signer-the-verifier-accepts")
KINDS = ("keygen", "sign", "sign-other")
LEAF = 5
# HASH calls: the key generator derives 67 secrets for each of 16 leaves and
# walks each 15 steps, hashes each leaf, then the 15 inner nodes; the signer
# derives its leaf's 67 secrets and walks each to its digit.
KEYGEN_HASHES = 16 * (67 * 16 + 1) + 15


def inputs(nseeds):
    rng = random.Random(212)
    seeds = [bytes(rng.getrandbits(8) for _ in range(32)) for _ in range(nseeds)]
    rng = random.Random(2120)
    m = bytes(rng.getrandbits(8) for _ in range(32))
    other = bytes(rng.getrandbits(8) for _ in range(32))
    return seeds, m, other


def hashes(kind, m, other):
    if kind == "keygen":
        return KEYGEN_HASHES
    return mss.N + sum(mss.digits(m if kind == "sign" else other))


def image(kind, seed, m, other):
    if kind.startswith("keygen"):
        return mss.keygen_image(kernel_bin(os.path.join(KERNELS, "keygen"))[0], seed)
    return mss.sign_image(kernel_bin(os.path.join(KERNELS, "sign"))[0], seed, mss.tree_of(seed), LEAF, m if kind == "sign" else other)


def gen_rtl(out):
    (seed,), m, other = inputs(1)
    lines = []
    for kind in KINDS:
        ran = rtl(image(kind, seed, m, other), 4000000000)
        print(f"{kind:10} {ran}", flush=True)
        lines.append(f"{kind} {ran}")
    open(out, "w").write("\n".join(lines) + "\n")


def read_rtl(path):
    got = {}
    for line in open(path):
        kind, halt, code, instret, cycles = line.split()
        if (halt, code) != ("halt", "code=00000000"):
            sys.exit(f"gen.py: the RTL's {kind} did not halt with code 0: {line.strip()}")
        got[kind] = (int(instret.split("=")[1]), int(cycles.split("=")[1]))
    return got


def schedule(nseeds):
    runs = [("keygen-warm", 0)]
    for i in range(nseeds):
        runs.append(("keygen", i))
        runs.append(("sign", i))
        if i == 0:
            runs.append(("sign-other", 0))
    return runs


def gen_expect(out, rv32run, rtl_txt, nseeds):
    seeds, m, other = inputs(nseeds)
    measured = read_rtl(rtl_txt)
    rows, counts = [], {}
    for name, i in schedule(nseeds):
        kind = "keygen" if name == "keygen-warm" else name
        img = image(kind, seeds[i], m, other)
        ran, region = model(rv32run, img.ljust(REGION_SIZE, b"\0"), 100000)
        if not ran.startswith("halt code=00000000 count="):
            sys.exit(f"gen.py: {kind}({i}): the model said {ran}")
        count = int(ran.split("count=")[1])
        if counts.setdefault(kind, count) != count:
            sys.exit(f"gen.py: {kind}({i}): the model counted {count}, seed 0 {counts[kind]}")
        if kind == "keygen" and region[mss.K_TREE:mss.K_TREE + 31 * 32] != b"".join(mss.tree_of(seeds[i])):
            sys.exit(f"gen.py: keygen({i}): the model's tree is not mss.py's")
        instret, cycles = measured[kind]
        s = hashes(kind, m, other)
        if instret != count + 3 + 4 * s:
            sys.exit(f"gen.py: {kind}: the RTL's minstret {instret} is not {count} + 3 + 4·{s}")
        digest = hashlib.sha256(region).digest()
        rows.append((name, i, instret, cycles, s, digest))
        print(f"{name:11} seed {i:2}  model count {count:5}  region {digest.hex()[:16]}…  "
              f"RTL minstret {instret:6}  mcycle {cycles:6}", flush=True)

    keygen, keygen_sha = kernel_bin(os.path.join(KERNELS, "keygen"))
    sign, sign_sha = kernel_bin(os.path.join(KERNELS, "sign"))
    with open(out, "w") as f:
        f.write("// Generated by exp212/gen.py from exp213's kernels and tools/hazard3/mss.py. Do not edit.\n")
        f.write("#pragma once\n#include <stdint.h>\n\n")
        f.write(f"#define NSEEDS {nseeds}\n#define NRUNS {len(rows)}\n#define LEAF {LEAF}\n")
        f.write(f"#define TREE_LEN {31 * 32}\n")
        for name in ("K_SEED", "K_TREE", "S_MSG", "S_IDX", "S_SEED", "S_TREE"):
            f.write(f"#define {name} 0x{getattr(mss, name):04x}u\n")
        f.write("\nenum kind { KEYGEN, SIGN, SIGN_OTHER, KEYGEN_WARM };\n")
        f.write("struct fill { uint16_t at, len; };     // 0xee before the kernel runs\n")
        f.write("struct run { uint32_t kind, seed, instret, cycles, hashes; uint8_t region[32]; };\n\n")
        for name, fill in (("K_FILL", mss.K_FILL), ("S_FILL", mss.S_FILL)):
            f.write(f"static const struct fill {name}[{len(fill)}] = {{" +
                    ", ".join(f"{{0x{a:04x}, {n}}}" for a, n in fill) + "};\n")
        for name, b, sha in (("KEYGEN", keygen, keygen_sha), ("SIGN", sign, sign_sha)):
            f.write(f"\n#define {name}_LEN {len(b)}\n")
            f.write(f"static const uint8_t {name}_SHA[32] = {{{c_bytes(bytes.fromhex(sha))}}};\n")
            f.write(f"static const uint8_t {name}_BIN[{len(b)}] = {{\n")
            for o in range(0, len(b), 16):
                f.write(f"    {c_bytes(b[o:o + 16])},\n")
            f.write("};\n")
        f.write(f"\nstatic const uint8_t MSG[32] = {{{c_bytes(m)}}};\n")
        f.write(f"static const uint8_t OTHER[32] = {{{c_bytes(other)}}};\n")
        f.write("static const uint8_t SEED[NSEEDS][32] = {\n")
        for s in seeds:
            f.write(f"    {{{c_bytes(s)}}},\n")
        f.write("};\n\nstatic const struct run RUNS[NRUNS] = {\n")
        for kind, i, instret, cycles, calls, digest in rows:
            enum = {"keygen": "KEYGEN", "sign": "SIGN", "sign-other": "SIGN_OTHER", "keygen-warm": "KEYGEN_WARM"}[kind]
            f.write(f"    {{{enum}, {i}, {instret}u, {cycles}u, {calls}u, {{{c_bytes(digest)}}}}},\n")
        f.write("};\n")
    print(f"expect.h: {nseeds} seeds, {len(rows)} runs")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "rtl":
        gen_rtl(sys.argv[2])
    elif len(sys.argv) == 6 and sys.argv[1] == "expect":
        gen_expect(sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]))
    else:
        sys.exit(__doc__)
