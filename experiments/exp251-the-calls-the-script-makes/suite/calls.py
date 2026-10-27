#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
exp251 on the emulator: every call exp228's kernel makes, against what proof/Calls.lean says.

`calls_the_script_makes` says that every `ecall` the run makes is HALT, or HASHB or CHECKSIG with its ranges in the
box. The emulator is a separate program that can disagree. exp228's kernel runs alone in its 64 KiB box
(exp238's suite/host.py, the run its kernel cases compare against), on exp228's 34 scripts and 120 drawn by its
fuzzer, and every `ecall` is recorded: its `t0`, and the ranges it names.

  the calls     every `t0` is 1, 2 or 3, never 0, the call the world here does not serve; each run ends in one HALT
  the ranges    each HASHB's input and output, each CHECKSIG's key and signature, wholly in the box
  the verdict   each run halts with script.py's verdict

`run_all()` returns the failures and the lines to print.
"""

import hashlib
import os
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../.."))
sys.path.insert(0, os.path.join(REPO, "experiments", "exp238-the-call-the-monitor-checks", "suite"))
import host  # noqa: E402
import kernel_cases  # noqa: E402
from script import script_verdict  # noqa: E402

SPEC = host.script_cases
FUZZ = kernel_cases.FUZZ
M32 = 0xFFFFFFFF


class Recorder(host.ReferenceEmulator):
    """The run alone, with every `ecall` recorded before it is answered."""

    def __init__(self, *a):
        super().__init__(*a)
        self.calls = []

    def step(self):
        off = self.pc - host.BASE
        if int.from_bytes(self.mem[off:off + 4], "little") == 0x00000073:
            R = self.regs
            self.calls.append((R[5], R[10], R[11], R[12]))
        return super().step()


def run_case(name, script, stack):
    pay = kernel_cases.payload(script, stack)
    emu = Recorder(bytes(0x10000) + pay, host.BOX_LO, host.BOX_HI)
    emu.run(400000)
    want = script_verdict(script, stack, sig=SPEC.valid, h=lambda b: hashlib.sha256(b).digest())
    bad = []
    if not emu.halted or emu.exit_code != want:
        bad.append(f"{name}: exit {emu.exit_code}, the specification says {want}")
    t0s = [c[0] for c in emu.calls]
    if any(t not in (1, 2, 3) for t in t0s):
        bad.append(f"{name}: a call with t0 = {[t for t in t0s if t not in (1, 2, 3)]}")
    if t0s.count(1) != 1 or (t0s and t0s[-1] != 1):
        bad.append(f"{name}: the run does not end in its one HALT: {t0s}")
    for c in emu.calls:
        if c[0] in (2, 3) and not host.boxed(c):
            bad.append(f"{name}: a call names a range out of the box: {[hex(x) for x in c]}")
    return bad, Counter(t0s)


def run_all():
    bad, total, n = [], Counter(), 0
    cases = [(name, s, st) for name, (s, st, _) in SPEC.hand().items()]
    cases += [(f"fuzz {i}", s, st) for i, (s, st) in enumerate(SPEC.fuzz(FUZZ))]
    for name, script, stack in cases:
        b, c = run_case(name, script, stack)
        bad += b
        total += c
        n += 1
    lines = [f"PASS  {n} scripts -- exp228's 34 by hand and {FUZZ} from its fuzzer -- run by exp228's kernel alone in its box,",
             f"      every ecall recorded: {total[1]} HALT, {total[2]} HASHB, {total[3]} CHECKSIG, none with t0 = 0 or above 3;",
             "      each HASHB's input and output and each CHECKSIG's key and signature wholly in the box;",
             "      each run ends in its one HALT, with script.py's verdict"]
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
