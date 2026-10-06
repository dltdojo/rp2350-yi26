# SPDX-License-Identifier: Apache-2.0
"""tools/hazard3/shell — what a shell checks against, from the two executors
that are not the chip. A shell's gen.py writes these into its expect.h, so
nothing the chip is compared with is typed by hand:

  model(rv32run, image, fuel)  the Lean model (rv32run) running the image at
                               CHIP_REGION, where the chip will: its one-line
                               outcome, and the whole region afterwards
  rtl(image, cycles)           the Hazard3 RTL running it under
                               tools/hazard3/harness, for at most cycles: its
                               one-line outcome, whose minstret (and, for
                               exp212, mcycle) the chip is asked to match
  c_bytes(b)                   bytes as a C initialiser list
  kernel_bin(path)             PATH.bin, checked against PATH.sha256 beside
                               it: (its bytes, the hash) — exp212 wrote it,
                               exp211 needed it second, exp207 a third time
"""
import hashlib
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
from sigfile import read_sig  # noqa: E402

CHIP_REGION, REGION_SIZE = 0x20070000, 0x10000


def kernel_bin(path):
    b = open(path + ".bin", "rb").read()
    want = open(path + ".sha256").read().split()[0]
    if hashlib.sha256(b).hexdigest() != want:
        sys.exit(f"{os.path.basename(path)}.sha256 is not {os.path.basename(path)}.bin's hash")
    return b, want


def c_bytes(b):
    return ", ".join(f"0x{x:02x}" for x in b)


def model(rv32run, image, fuel):
    with tempfile.TemporaryDirectory() as work:
        img, sig = os.path.join(work, "image.bin"), os.path.join(work, "region.sig")
        open(img, "wb").write(image)
        ran = subprocess.run([rv32run, img, hex(CHIP_REGION), hex(REGION_SIZE), str(fuel), str(REGION_SIZE), sig],
                             capture_output=True, text=True).stdout.strip()
        return ran, read_sig(sig)[:REGION_SIZE]


def rtl(image, cycles=50000000):
    with tempfile.TemporaryDirectory() as work:
        img = os.path.join(work, "image.bin")
        open(img, "wb").write(image)
        return subprocess.run([os.path.join(HERE, "..", "sim.sh"), "run", img, "--cycles", str(cycles)],
                              capture_output=True, text=True).stdout.strip()
