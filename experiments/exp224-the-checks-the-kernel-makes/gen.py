#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp224 — what the shell compiles in, computed here.

  gen.py OUT.h RV32RUN

  KERNEL, KERNEL_SHA      exp223's kernel.bin, checked against its kernel.sha256
  INSTRET_PASS/_FAIL      the Hazard3 RTL's minstret for it on a stream that
                          passes and on one that does not — the records'
                          "what it should say", which the judge holds the
                          trap's minstret to
  JUDGE, JUDGE_SHA        judge.bin, as proof/Judge.lean writes it, checked
                          against judge.sha256

and, before writing anything: exp223's kernel on the Lean model, as exp223's
gen.py has it (tools/hazard3/shell/healthexpect.py); and the judge on the
model, on records as the chip should give them, halting with 0.
"""
import hashlib
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EXP223 = os.path.join(HERE, "..", "exp223-the-digest-the-kernel-withholds")
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools", "hazard3", "shell"))
sys.path.insert(0, os.path.join(HERE, "differential"))
from expect import c_bytes, kernel_bin, model  # noqa: E402
from facts import image as judge_image, record  # noqa: E402
from healthexpect import write_health  # noqa: E402
from streams import N  # noqa: E402

SAMPLES, DIGEST = 0x3000, 0x2140


def image(kernel, words):
    img = bytearray(SAMPLES + 4 * N)
    img[:len(kernel)] = kernel
    img[SAMPLES:] = struct.pack(f"<{N}I", *words)
    return bytes(img)


def digest(ok, img, region):
    if ok and region[DIGEST:DIGEST + 32] != hashlib.sha256(img[SAMPLES:]).digest():
        return "the model's digest is not hashlib's"
    return None


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    out, rv32run = sys.argv[1], sys.argv[2]
    sha, counts = write_health(out, rv32run, "exp224", os.path.join(EXP223, "kernel"), image,
                               {True: 334284, False: 17425}, wide=True, also=digest)
    judge, jsha = kernel_bin(os.path.join(HERE, "judge"))
    ip, if_ = counts["pass"], counts["fail"]
    good = [record(instret=ip, pas=ip, fail=if_), record(a0=1, instret=if_, pas=ip, fail=if_),
            record(a0=1, instret=if_, pas=ip, fail=if_)]
    ran, _ = model(rv32run, judge_image(judge, good), 2000, wide=True)
    if not ran.startswith("halt code=00000000 "):
        sys.exit(f"gen.py: on records as the chip should give them the judge said {ran}")
    with open(out, "a") as f:
        f.write(f"\n#define JUDGE_LEN {len(judge)}\n")
        f.write("static const uint8_t JUDGE[JUDGE_LEN] = {" + c_bytes(judge) + "};\n")
        f.write("static const uint8_t JUDGE_SHA[32] = {" + c_bytes(bytes.fromhex(jsha)) + "};\n")
    print(f"{out}: exp223's kernel {sha[:16]}…, RTL minstret {counts['pass']} conditioned, "
          f"{counts['fail']} withheld; judge {jsha[:16]}…")
