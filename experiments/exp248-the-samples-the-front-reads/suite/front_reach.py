#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
exp248 on the emulator: exp223's kernel alone, on exp222's fourteen sample streams, every access recorded.

What proof/Front.lean says of the front, held against a separate program that can disagree:

  the front        up to SHA-256's first word: every pc one of the front's 34 instructions, every load inside
                   [+0x3000, +0x4000), no store, no ecall but a HALT with t0 = 1; the samples' first and last
                   words are both read, so the window the checker computed is the one the run uses
  the way out      a healthy block reaches +0x1000 -- at step 17422, exp223's number -- with memory as it was; an
                   unhealthy one never does, and HALTs with 1 from +0x84
  SHA-256, ahead   not claimed here: the windows SHA-256 reads and writes, relative to the box, recorded for the
                   checker's next round

`run_all()` returns the failures and the lines to print.
"""

import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../.."))
sys.path.insert(0, os.path.join(REPO, "tools"))
sys.path.insert(0, os.path.join(REPO, "tools", "monitor"))
sys.path.insert(0, os.path.join(REPO, "tools", "hazard3", "shell"))
import harness  # noqa: E402
from streams import streams, healthy  # noqa: E402

EXP223 = os.path.join(REPO, "experiments", "exp223-the-digest-the-kernel-withholds")
BOX = harness.PAYLOAD_AT
FRONT_END, SHA, SAMPLES = 0x88, 0x1000, 0x3000
TO_SHA = 17422


class Recorder(harness.ReferenceEmulator):
    """The kernel alone, every load and store written down with the pc that made it."""

    def __init__(self, pay: bytes):
        super().__init__(pay)
        self.loads, self.stores, self.calls, self.pcs = [], [], [], set()

    def load(self, addr, width):
        self.loads.append((self.pc - BOX, addr - BOX, width))
        return super().load(addr, width)

    def store(self, addr, width, val):
        self.stores.append((self.pc - BOX, addr - BOX, width))
        return super().store(addr, width, val)

    def step(self):
        off = self.pc - harness.BASE
        if int.from_bytes(self.mem[off:off + 4], "little") == 0x00000073:
            self.calls.append((self.pc - BOX, self.regs[5]))
        self.pcs.add(self.pc - BOX)
        super().step()


def kernel() -> bytes:
    with open(os.path.join(EXP223, "kernel.bin"), "rb") as f:
        return f.read()


def payload(words: list) -> bytes:
    k = kernel()
    box = bytearray(0x10000)
    box[:len(k)] = k
    box[SAMPLES:SAMPLES + 4096] = struct.pack("<1024I", *words)
    return bytes(box)


def window(acc: list) -> tuple:
    return (min(a for _, a, _ in acc), max(a + w for _, a, w in acc)) if acc else None


def run_case(name: str, words: list):
    ok, _ = healthy(words)
    pay = payload(words)
    emu = Recorder(pay)
    exit_at = None
    for n in range(1, 400000):
        emu.step()
        if exit_at is None and emu.pc == BOX + SHA:
            exit_at = n
            front = (len(emu.loads), len(emu.stores), len(emu.calls), set(emu.pcs))
            mem_at_exit = bytes(emu.mem[BOX - harness.BASE:BOX - harness.BASE + 0x10000])
        if emu.halted:
            break
    bad = []
    if exit_at is None:
        front = (len(emu.loads), len(emu.stores), len(emu.calls), set(emu.pcs))
    nl, ns, nc, pcs = front
    fl, fs, fc = emu.loads[:nl], emu.stores[:ns], emu.calls[:nc]
    if any(not (0 <= p < FRONT_END and p % 4 == 0) for p in pcs):
        bad.append(f"{name}: a pc outside the front before SHA-256")
    if window(fl) != (SAMPLES, SAMPLES + 4096):
        bad.append(f"{name}: the front read {window(fl)}, not exactly the samples")
    if fs:
        bad.append(f"{name}: the front stored {len(fs)} times")
    if any(t0 != 1 for _, t0 in fc):
        bad.append(f"{name}: the front made a call with t0 != 1")
    if ok:
        if exit_at != TO_SHA:
            bad.append(f"{name}: healthy, but at SHA-256 at step {exit_at}, not {TO_SHA}")
        elif mem_at_exit != pay:
            bad.append(f"{name}: memory changed before SHA-256")
        if emu.exit_code != 0:
            bad.append(f"{name}: healthy, exit {emu.exit_code}")
    else:
        if exit_at is not None:
            bad.append(f"{name}: unhealthy, and still reached SHA-256")
        if fc != [(0x84, 1)] or emu.exit_code != 1:
            bad.append(f"{name}: unhealthy, calls {fc}, exit {emu.exit_code}")
    sha = (window(emu.loads[nl:]), window(emu.stores[ns:]), emu.calls[nc:]) if exit_at else None
    return bad, ok, len(fl), sha


def run_all():
    bad, lines = [], []
    shas, n_ok, n_bad, reads = set(), 0, 0, set()
    for name, words in streams().items():
        b, ok, nl, sha = run_case(name, words)
        bad += b
        reads.add(nl)
        if ok:
            n_ok += 1
            shas.add((sha[0], sha[1], tuple(sha[2])))
        else:
            n_bad += 1
    lines.append(f"PASS  exp222's 14 streams, exp223's kernel alone, every access recorded; up to SHA-256's first word:")
    lines.append(f"      every pc one of the front's 34 instructions, every load inside [+0x3000, +0x4000) and both ends")
    lines.append(f"      of it read ({', '.join(str(r) for r in sorted(reads))} loads), no store, no call but HALT with t0 = 1")
    lines.append(f"PASS  the way out: {n_ok} healthy streams at +0x1000 at step {TO_SHA}, memory as it was; {n_bad} unhealthy,")
    lines.append(f"      never there, each HALTing with 1 from +0x84, its only call")
    for lw, sw, calls in sorted(shas):
        lines.append(f"      SHA-256, ahead and not claimed: loads [{lw[0]:#x}, {lw[1]:#x}), stores [{sw[0]:#x}, {sw[1]:#x}),"
                     f" calls {[(hex(p), t) for p, t in calls]}")
    return bad, lines


def main():
    bad, lines = run_all()
    for b in bad[:20]:
        print(f"FAIL  {b}")
    if bad:
        sys.exit(1)
    print("\n".join(lines))


if __name__ == "__main__":
    main()
