#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp223 — kernel.bin on the Lean model (rv32run) and on the Hazard3 RTL, in
the 128 KiB region, against exp114's health tests in Python and hashlib's
SHA-256, over every stream in tools/hazard3/shell/streams.py.

  differential.py RV32RUN      PASS/FAIL lines; exit 0 = all pass

For each stream: the model and the RTL halt with the same code, and it is
exp114's verdict (0 healthy, 1 not); the model's count is the one for that
verdict; when healthy, the 32 bytes at 0x2140 are hashlib's SHA-256 of the
samples' 4096 bytes on both; and the model's region afterwards is the image,
unchanged when not healthy, and changed only from 0x2140 to 0x2440 when
healthy.
"""
import hashlib
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.join(HERE, "..", "..", "..", "tools", "hazard3")
sys.path.insert(0, os.path.join(TOOLS, "shell"))
sys.path.insert(0, TOOLS)
from expect import model  # noqa: E402
from sigfile import read_sig  # noqa: E402
from streams import N, healthy, streams  # noqa: E402

SAMPLES, DIGEST, SCRATCH_END = 0x3000, 0x2140, 0x2440
COUNT = {True: 334284, False: 17425}


def image(kernel, words):
    img = bytearray(SAMPLES + 4 * N)
    img[:len(kernel)] = kernel
    img[SAMPLES:] = struct.pack(f"<{N}I", *words)
    return bytes(img)


def rtl(img):
    """The RTL's one-line outcome, and the digest's 32 bytes afterwards."""
    with tempfile.TemporaryDirectory() as work:
        path, sig = os.path.join(work, "image.bin"), os.path.join(work, "region.sig")
        open(path, "wb").write(img)
        ran = subprocess.run([os.path.join(TOOLS, "sim.sh"), "run", path, "--wide", "--cycles", "50000000",
                              "--dump", str(len(img)), sig], capture_output=True, text=True).stdout.strip()
        return ran, read_sig(sig)[DIGEST:DIGEST + 32]


def main():
    kernel = open(os.path.join(HERE, "..", "kernel.bin"), "rb").read()
    failed = 0
    for name, words in streams().items():
        ok, why = healthy(words)
        img = image(kernel, words)
        want_code = 0 if ok else 1
        want_digest = hashlib.sha256(img[SAMPLES:]).digest()
        ran, region = model(sys.argv[1], img, 400000, wide=True)
        rtl_ran, rtl_digest = rtl(img)
        want_region = bytearray(img) + bytes(len(region) - len(img))
        if ok:
            want_region[DIGEST:SCRATCH_END] = region[DIGEST:SCRATCH_END]
        problems = []
        if ran != f"halt code={want_code:08x} count={COUNT[ok]}":
            problems.append(f"model: {ran}")
        if region != bytes(want_region):
            problems.append("the model's region is not the image, but for the digest and its scratch when healthy")
        if not rtl_ran.startswith(f"halt code={want_code:08x} "):
            problems.append(f"RTL: {rtl_ran}")
        if ok and region[DIGEST:DIGEST + 32] != want_digest:
            problems.append("the model's digest is not hashlib's")
        if ok and rtl_digest != want_digest:
            problems.append("the RTL's digest is not hashlib's")
        verdict = "healthy" if ok else f"withheld: {why}"
        said = (f"both digests hashlib's, {want_digest.hex()[:16]}…" if ok
                else "no digest, the model's region untouched")
        if problems:
            failed = 1
            print(f"FAIL  {name}: exp114 says {verdict} — {'; '.join(problems)}")
        else:
            print(f"PASS  {name}: exp114 says {verdict}; the model and the RTL halt with {want_code}, "
                  f"the model after {COUNT[ok]}; {said}")
    sys.exit(failed)


if __name__ == "__main__":
    main()
