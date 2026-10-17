#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
exp223's proved kernel on exp222's fourteen sample streams, under exp239's monitor and alone.

Each stream runs twice -- alone in M-mode with no monitor (harness.reference_run), and under the monitor --
and what must agree is:

  - the exit code: 0 for the seven streams exp114's tests pass, 1 for the seven they do not, both runs;
  - the instruction count: exp223's theorem, 334,284 for a pass and 17,425 for a fail, alone; under the
    monitor, +2 for its framing (the `csrwi` that releases the counters and the `mret`);
  - the box when the kernel halts: the same in both runs, byte for byte;
  - the digest of a pass: SHA-256 of the 4,096 bytes of samples, at +0x2140, as the kernel left it;
  - memory when the monitor parks: that, with the scratch zeroed, and on a fail the digest window too
    (suite/oracle.py), every other byte as it was.

The box is seeded with junk everywhere the kernel does not own, so that a scrub which writes a word too many
or too few is seen, and the digest window and the scratch hold junk before the kernel starts so that a fail
which "writes nothing" still leaves something to zero.
"""

import hashlib
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import oracle
import harness
sys.path.insert(0, os.path.join(oracle.REPO, "tools", "hazard3", "shell"))
from streams import streams, healthy

EXP223 = os.path.join(oracle.REPO, "experiments", "exp223-the-digest-the-kernel-withholds")
PASS_COUNT, FAIL_COUNT, FRAMING = 334284, 17425, 2
SAMPLES = 0x3000


def kernel() -> bytes:
    with open(os.path.join(EXP223, "kernel.bin"), "rb") as f:
        return f.read()


def seeded(words: list) -> bytes:
    """The 64 KiB box: the kernel at 0, the samples at +0x3000, junk in every byte the kernel does not own."""
    k = kernel()
    r = random.Random(239)
    box = bytearray(r.randbytes(0x10000))
    box[:len(k)] = k
    box[len(k):0x2140] = bytes(0x2140 - len(k))             # the kernel's data: K, IV, the length
    box[SAMPLES:SAMPLES + 4096] = struct.pack("<1024I", *words)
    return bytes(box)


def run_case(mon: bytes, name: str, words: list):
    """(failures, instructions the kernel ran, exit code) for one stream."""
    ok, _ = healthy(words)
    want = 0 if ok else 1
    pay = seeded(words)
    alone = harness.reference_run(pay)
    under, snap = oracle.run(mon, pay)
    bad = harness.check_halt(under, mon, want)
    if alone.exit_code != want:
        bad.append(f"alone: exit {alone.exit_code}, exp114's tests say {want}")
    count = PASS_COUNT if ok else FAIL_COUNT
    if alone.minstret != count:
        bad.append(f"alone: {alone.minstret} instructions, exp223's theorem says {count}")
    rep = oracle.reported(under, harness.TAG_HALT)
    if rep is None or rep[1] != alone.minstret + FRAMING:
        bad.append(f"under the monitor: minstret {rep and rep[1]}, wanted {alone.minstret} + {FRAMING}")
    boxed = slice(oracle.BOX - harness.BASE, oracle.BOX - harness.BASE + harness.PAYLOAD_LEN)
    if snap is None or snap[boxed] != harness.box(alone):
        bad.append("when the kernel halted, the box differs from the run alone")
    if ok and snap is not None:
        digest = snap[oracle.DIGEST[0] - harness.BASE:oracle.DIGEST[1] - harness.BASE]
        if digest != hashlib.sha256(pay[SAMPLES:SAMPLES + 4096]).digest():
            bad.append("the digest the kernel left is not SHA-256 of the samples")
    got = bytes(under.mem[oracle.DIGEST[0] - harness.BASE:oracle.DIGEST[1] - harness.BASE])
    if ok and snap is not None and got != snap[oracle.DIGEST[0] - harness.BASE:oracle.DIGEST[1] - harness.BASE]:
        bad.append("a healthy stream's digest did not survive the monitor")
    if not ok and got != bytes(32):
        bad.append("a withheld stream left bytes in the digest window")
    bad += oracle.check_memory(under, snap, want)
    return bad, alone.minstret, want


def run_all(mon: bytes, names=None) -> list:
    out = []
    for name, words in streams().items():
        if names and name not in names:
            continue
        bad, _n, _c = run_case(mon, name, words)
        if bad:
            out.append((name, bad))
    return out


def main():
    mon = oracle.monitor()
    rows, failed = [], []
    for name, words in streams().items():
        bad, n, code = run_case(mon, name, words)
        rows.append((name, code, n))
        if bad:
            failed.append((name, bad))
    for name, bad in failed:
        print(f"FAIL  {name}: {'; '.join(bad)}")
    if failed:
        sys.exit(1)
    passed = sum(1 for _, c, _ in rows if c == 0)
    print(f"PASS  {len(rows)} streams, exp223's kernel under the monitor and alone: {passed} healthy (HALT 0 after "
          f"{PASS_COUNT}, digest kept, scratch zero), {len(rows) - passed} withheld (HALT 1 after {FAIL_COUNT}, digest window "
          f"and scratch zero); everything else as the kernel left it")
    print("      stream                      exit  instructions")
    for name, code, n in rows:
        print(f"      {name:26} {code:5} {n:13}")


if __name__ == "__main__":
    main()
