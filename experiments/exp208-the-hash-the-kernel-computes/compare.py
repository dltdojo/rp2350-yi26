#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp208 — the kernel on the Lean model and on the Hazard3 RTL, against
hashlib, and the specification against hashlib.

  compare.py RUN SHA_BIN SPEC

RUN is rv32run's path, SHA_BIN the kernel (Lean writes it from proof/Sha.lean),
SPEC a command that prints the specification's digest of a hex message
(`lean.sh exec proof/Sha.lean digest`, as one string). For each message, one
line: its length, then whether the model's and the RTL's 32 bytes at
R + 0x140 are hashlib's SHA-256, with each one's count; and whether the
specification says the same. The model's count must be the one the theorem
`computes` states, A + B n for n blocks — A and B read from
lean/Rv32/Sha.lean, not written here — and the RTL's minstret that plus the
harness's 3. Exit 0 when every one of them holds.

The image: the kernel at 0, K and IV at 0x1000 and 0x1100, the length at
0x1120, the message at 0x2000 — proof/Sha.lean's layout.
"""
import hashlib
import os
import random
import re
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.join(HERE, "..", "..", "tools", "hazard3")
sys.path.insert(0, TOOLS)
from sigfile import read_sig  # noqa: E402

SIZE = 0x10000
R = 0x1000
K = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]
IV = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]


def sha_image(kernel, msg):
    img = bytearray(0x2000 + len(msg))
    img[:len(kernel)] = kernel
    img[R:R + 256] = struct.pack("<64I", *K)
    img[R + 0x100:R + 0x120] = struct.pack("<8I", *IV)
    img[R + 0x120:R + 0x124] = struct.pack("<I", len(msg))
    img[0x2000:] = msg
    return bytes(img)


def messages():
    rng = random.Random(208)
    out = [b"", b"a" * 64, bytes(64), b"\xff" * 64, bytes(range(64)) * 2]
    out += [bytes(rng.getrandbits(8) for _ in range(64 * n)) for n in (1, 2, 3, 5, 8)]
    return out


def theorem_count():
    lib = open(os.path.join(HERE, "..", "..", "lean", "Rv32", "Sha.lean")).read()
    a, b = re.search(r"run env \((\d+) \+ (\d+) \* n\) s = \.halted 0 s'", lib).groups()
    return int(a), int(b)


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()


def compare():
    rv32run, kernel = sys.argv[1], open(sys.argv[2], "rb").read()
    spec = sys.argv[3].split()
    a, b = theorem_count()
    bad = 0
    print(f"{'bytes':>5}  {'model':40}  {'RTL':44}  spec")
    with tempfile.TemporaryDirectory() as work:
        for msg in messages():
            want = hashlib.sha256(msg).digest()
            path, dm, dr = (os.path.join(work, f) for f in ("img.bin", "model.sig", "rtl.sig"))
            open(path, "wb").write(sha_image(kernel, msg))
            m = run([rv32run, path, "0x80010000", hex(SIZE), "10000000", str(SIZE), dm])
            r = run([os.path.join(TOOLS, "sim.sh"), "run", path, "--dump", str(SIZE), dr, "--cycles", "200000000"])
            count = a + b * (len(msg) // 64)
            mok = (m.startswith("halt code=00000000") and f"count={count}" in m.split()
                   and read_sig(dm)[R + 0x140:R + 0x160] == want)
            rok = (r.startswith("halt code=00000000") and f"instret={count + 3}" in r.split()
                   and read_sig(dr)[R + 0x140:R + 0x160] == want)
            sok = run(spec + [msg.hex()]) == want.hex()
            bad |= not (mok and rok and sok)
            print(f"{len(msg):5}  {('ok ' if mok else 'NO ') + m:40}  {('ok ' if rok else 'NO ') + r:44}  "
                  f"{'ok' if sok else 'NO'}", flush=True)
    print(("FAIL  " if bad else "PASS  ") + f"the kernel on the model and the RTL, and the specification, give "
          f"hashlib's SHA-256 of all {len(messages())} messages; the model in exactly {a} + {b} n instructions, "
          f"as computes states, and the RTL retiring 3 more")
    return bad


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(compare())
