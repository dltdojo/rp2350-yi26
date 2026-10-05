#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp210 — every case the shell runs, and what it must leave, computed here
and compiled in.

  gen.py OUT.h RV32RUN [CASE...]

Writes OUT.h from exp204's and exp205's own sources — their kernel.bin,
kernel.sha256 and images.py — and nothing typed by hand. With CASE names,
only those (check.sh's wrong shells run on two, to be quick).

For each case, the Lean model (rv32run, with SHA-256 as HASH) runs the image
at 0x20070000, where the chip will, and the Hazard3 RTL runs it under
tools/hazard3/harness. Before anything is written:

  - the model's verdict is the one images.py's Python computes;
  - the model's count is the proved one: 16663 for exp204's kernel, and
    4142 + 3 S for exp205's, S the HASH calls the message makes;
  - the RTL halts the same way, and its minstret is count + 3 + 4 S, as
    exp204 and exp205 measured.

What goes into OUT.h:

  BLOCK          every distinct 64-byte block any case puts in the region or
                 must find there afterwards, once; block 0 is all zeros
  CASE_IN        per case, the region's non-zero blocks before: (block
                 number in the region, BLOCK index), ascending
  CASE_OUT       per case, the blocks the model changed: the same pairs, for
                 the region as the model left it where it differs from before
  CASES          per case: which kernel, the verdict (a0), the RTL's minstret,
                 and where its CASE_IN and CASE_OUT entries start and end
  KERNEL_LEN, KERNEL_SHA   per kernel: kernel.bin's length and kernel.sha256,
                 checked here to be the hash of each image's first bytes

The shell zeroes the region, writes CASE_IN, runs the kernel, and then
compares every one of the region's 65536 bytes with CASE_IN overlaid by
CASE_OUT, zeros elsewhere — no hash between the chip and the model's answer.
"""
import hashlib
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools", "hazard3", "shell"))
from expect import REGION_SIZE, c_bytes, model, rtl  # noqa: E402

KERNELS = [  # (directory, images.py's cases, its image builder, proved count from S)
    ("exp204-the-signature-the-kernel-checks", "lamport_cases", "lamport_image", lambda s: 16663),
    ("exp205-the-chain-the-checksum-closes", "wots_cases", "wots_image", lambda s: 4142 + 3 * s),
]


def images_module(directory):
    path = os.path.join(HERE, "..", directory, "images.py")
    spec = importlib.util.spec_from_file_location(directory.split("-")[0] + "_images", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def hashes(k, mod, case):
    return 256 if k == 0 else mod.hashes(case[1])


def blocks_of(region):
    return {o // 64: bytes(region[o:o + 64]) for o in range(0, REGION_SIZE, 64) if any(region[o:o + 64])}


def generate(out, rv32run, only):
    pool, index = [bytes(64)], {bytes(64): 0}

    def block(b):
        if b not in index:
            index[b] = len(pool)
            pool.append(b)
        return index[b]

    kernels, cases, ins, outs = [], [], [], []
    for k, (directory, cases_fn, image_fn, proved) in enumerate(KERNELS):
        mod = images_module(directory)
        kernel = open(os.path.join(HERE, "..", directory, "kernel.bin"), "rb").read()
        want = open(os.path.join(HERE, "..", directory, "kernel.sha256")).read().strip()
        if hashlib.sha256(kernel).hexdigest() != want:
            sys.exit(f"gen.py: {directory}'s kernel.sha256 is not kernel.bin's hash")
        kernels.append((len(kernel), want))
        for name, case in getattr(mod, cases_fn)().items():
            if only and name not in only:
                continue
            image = getattr(mod, image_fn)(*case).ljust(REGION_SIZE, b"\0")
            if image[:len(kernel)] != kernel:
                sys.exit(f"gen.py: {name}'s image does not start with {directory}'s kernel")
            verdict, s = mod.verdict(*case), hashes(k, mod, case)
            count = proved(s)
            ran, region = model(rv32run, image, 20000)
            if ran != f"halt code={verdict:08x} count={count}":
                sys.exit(f"gen.py: {name}: the model said {ran}, not verdict {verdict} at the proved {count}")
            instret = count + 3 + 4 * s
            ran = rtl(image)
            if not ran.startswith(f"halt code={verdict:08x} instret={instret} "):
                sys.exit(f"gen.py: {name}: the RTL said {ran}, not verdict {verdict} and minstret {instret}")
            before, after = blocks_of(image), blocks_of(region)
            changed = sorted(n for n in set(before) | set(after) if before.get(n) != after.get(n))
            i0, o0 = len(ins), len(outs)
            ins += [(n, block(before[n])) for n in sorted(before)]
            outs += [(n, block(after.get(n, bytes(64)))) for n in changed]
            cases.append((name, k, verdict, s, instret, i0, len(ins), o0, len(outs)))
            print(f"{name:24} kernel {k}  verdict {verdict}  S {s:3}  count {count:5}  minstret {instret:5}  "
                  f"in {len(before):3} blocks, {len(changed)} changed")

    with open(out, "w") as f:
        f.write("// Generated by exp210/gen.py from exp204's and exp205's sources. Do not edit.\n")
        f.write("#pragma once\n#include <stdint.h>\n\n")
        f.write(f"#define NKERNELS {len(kernels)}\n#define NCASES {len(cases)}\n#define NBLOCKS {len(pool)}\n\n")
        f.write("struct pair { uint16_t at, block; };   // region block number, BLOCK index\n")
        f.write("struct expect { uint32_t kernel, a0, instret, in0, in1, out0, out1; };\n\n")
        f.write("static const uint32_t KERNEL_LEN[NKERNELS] = {" + ", ".join(str(n) for n, _ in kernels) + "};\n")
        f.write("static const uint8_t KERNEL_SHA[NKERNELS][32] = {\n")
        for _, sha in kernels:
            f.write("    {" + c_bytes(bytes.fromhex(sha)) + "},\n")
        f.write("};\n\n")
        f.write("static const struct expect CASES[NCASES] = {\n")
        for name, k, verdict, s, instret, i0, i1, o0, o1 in cases:
            f.write(f"    {{{k}, {verdict}, {instret}u, {i0}, {i1}, {o0}, {o1}}},   // {name}, S = {s}\n")
        f.write("};\n\n")
        for label, pairs in (("CASE_IN", ins), ("CASE_OUT", outs)):
            f.write(f"__attribute__((section(\".above\"))) static const struct pair {label}[{max(len(pairs), 1)}] = {{\n")
            for i in range(0, len(pairs), 8):
                f.write("    " + " ".join(f"{{{a}, {b}}}," for a, b in pairs[i:i + 8]) + "\n")
            f.write("};\n")
        f.write("\n__attribute__((section(\".above\"))) static const uint8_t BLOCK[NBLOCKS][64] = {\n")
        for b in pool:
            f.write("    {" + c_bytes(b) + "},\n")
        f.write("};\n")
    print(f"expect.h: {len(cases)} cases, {len(pool)} distinct blocks ({len(pool) * 64} bytes), "
          f"{len(ins)} placed, {len(outs)} changed")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    generate(sys.argv[1], sys.argv[2], set(sys.argv[3:]))
