#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
exp252 on the emulator: exp228's kernel as exp238's payload, from reset, against what proof/Wall.lean says.

`verdict_behind_the_wall` says the monitor parks with the specification's verdict, and that the last word the host
hears is that verdict, at the exit word. Its proof composes the run one Tier 1 step at a time:
  - 53 steps of boot;
  - then one Tier 2 step for each plain step, 44 for a HASHB and 48 for a CHECKSIG (the trap, the served call, the
    way back);
  - and 62 for the HALT (the trap, the report, the scrub).
The emulator is a separate program that can disagree. exp228's 34 scripts and 120 from its fuzzer run under
exp238's monitor, with the emulator's host (hashlib's SHA-256 and exp228's BIP340 verifier). Each run is also run
alone, to count its Tier 1 instructions and its calls:

  the verdict   parked at the park word with a0 = script.py's verdict, the exit word the last port write
  the count     the park word first reached at step 53 + (n - 1 - h - c) + 44 h + 48 c + 62, n the run alone's
                instructions with its HALT, h and c its HASHB and CHECKSIG calls: the steps the proof composes

`run_all()` returns the failures and the lines to print.
"""

import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../.."))
sys.path.insert(0, os.path.join(REPO, "experiments", "exp238-the-call-the-monitor-checks", "suite"))
import host  # noqa: E402
import kernel_cases  # noqa: E402
from script import script_verdict  # noqa: E402

SPEC = host.script_cases
PARK, EXIT = 0x80000320, 0xC0000008
BOOT, HASHB, CHECKSIG, HALT = 53, 44, 48, 62


class Recorder(host.ServiceEmulator):
    """exp238's emulator with its host, every port write recorded in order."""

    def __init__(self, image):
        super().__init__(image)
        self.writes = []

    def store(self, addr, width, val):
        if 0xC0000000 <= addr < 0xC0000020:
            self.writes.append((addr, val & 0xFFFFFFFF))
        return super().store(addr, width, val)


def run_case(monitor, name, script, stack):
    pay = kernel_cases.payload(script, stack)
    want = script_verdict(script, stack, sig=SPEC.valid, h=lambda b: hashlib.sha256(b).digest())
    alone = host.reference_run(pay)
    calls = [r[0] for r in alone.host.requests]
    h, c = calls.count(2), calls.count(3)
    emu = Recorder(host.image(monitor, pay))
    park_at = None
    for n in range(1, 2000000):
        emu.step()
        if emu.pc == PARK:
            park_at = n
            break
    bad = []
    if park_at is None:
        return [f"{name}: never reached the park word"], None
    if emu.regs[10] != want:
        bad.append(f"{name}: parked with a0 = {emu.regs[10]}, the specification says {want}")
    if not emu.writes or emu.writes[-1] != (EXIT, want):
        bad.append(f"{name}: the last port write is {emu.writes[-1:] }, not the verdict at the exit word")
    composed = BOOT + (alone.minstret - 1 - h - c) + HASHB * h + CHECKSIG * c + HALT
    if park_at != composed:
        bad.append(f"{name}: parked at step {park_at}, the composed count is {composed}")
    return bad, (h, c)


def run_all():
    with open(os.path.join(host.EXP238, "monitor.bin"), "rb") as f:
        monitor = f.read()
    cases = [(name, s, st) for name, (s, st, _) in SPEC.hand().items()]
    cases += [(f"fuzz {i}", s, st) for i, (s, st) in enumerate(SPEC.fuzz(kernel_cases.FUZZ))]
    bad, H, C = [], 0, 0
    for name, script, stack in cases:
        b, hc = run_case(monitor, name, script, stack)
        bad += b
        if hc:
            H += hc[0]
            C += hc[1]
    lines = [f"PASS  {len(cases)} scripts -- exp228's 34 by hand and {kernel_cases.FUZZ} from its fuzzer -- as exp238's payload,"
             " from reset:",
             "      each parks with a0 = script.py's verdict, the verdict the last port write, at the exit word;",
             f"      each first at step 53 + (n - 1 - h - c) + 44 h + 48 c + 62, the steps the proof composes ({H} HASHB, {C} CHECKSIG)"]
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
