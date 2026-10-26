#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
exp250 on the emulator: exp223's kernel.bin as exp239's payload, from reset, against what proof/Wall.lean says.

`digest_behind_the_wall` and `no_digest_behind_the_wall` name a step, words and bytes, and the emulator is a
separate program that can disagree. exp222's fourteen streams, each in exp239's own seeded box (junk in every byte
the kernel does not own, so a byte the theorem says is untouched is one that would show if it were not):

  the trap      the kernel traps from U-mode once, at step 53 + j + 1, with j + 1 exactly exp223's count -- 334284
                for a healthy stream, 17425 for an unhealthy one -- at the trap vector, mcause 8
  the digest    healthy: SHA-256 of the samples at +0x2140 at the trap, and still there at the park
  the scrub     the confidential scratch zero at the park; unhealthy, the digest window zero too, and every other
                byte of RAM but the monitor's stack as it was at reset
  the words     what the host heard from reset: the HALT tag, the exit code, 3 + j twice; and the exit code

The theorems say j is below the count; the emulator says how far below: not at all. `run_all()` returns the failures
and the lines to print.
"""

import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../.."))
sys.path.insert(0, os.path.join(REPO, "experiments", "exp239-the-scratch-the-monitor-scrubs", "suite"))
import kernel_cases  # noqa: E402
import oracle  # noqa: E402
from kernel_cases import harness, healthy, seeded, streams, PASS_COUNT, FAIL_COUNT  # noqa: E402

BOOT, TRAP_VECTOR = 53, 0x80000114
STACK = (0x80008000, 0x80008010)
BASE = harness.BASE


def walk(mon: bytes, pay: bytes, limit: int = 400000):
    """From reset to the park: the step of the first trap from U-mode, memory then, and the emulator parked."""
    emu = harness.SandboxEmulator(harness.image(mon, pay))
    reset = bytes(emu.mem)
    trap_at = snap = trap = None
    for n in range(1, limit + 1):
        was = emu.mode
        emu.step()
        if trap_at is None and was == "U" and emu.mode == "M":
            trap_at, snap, trap = n, bytes(emu.mem), dict(pc=emu.pc, mcause=emu.mcause)
        if emu.halted:
            break
    return emu, reset, trap_at, snap, trap


def run_case(mon: bytes, name: str, words: list):
    ok, _ = healthy(words)
    code, count = (0, PASS_COUNT) if ok else (1, FAIL_COUNT)
    pay = seeded(words)
    emu, reset, trap_at, snap, trap = walk(mon, pay)
    bad = []
    if trap_at is None:
        return [f"{name}: the kernel never trapped"], None
    j = trap_at - BOOT - 1
    if j + 1 != count:
        bad.append(f"trapped at step {trap_at}, j = {j}; exp223's count is {count}")
    if trap["pc"] != TRAP_VECTOR or trap["mcause"] != 8:
        bad.append(f"trapped to {trap['pc']:#x} with mcause {trap['mcause']}")
    if len(emu.traps) != 1:
        bad.append(f"{len(emu.traps)} traps, the theorem's run has one")
    if not emu.halted or emu.exit_code != code:
        bad.append(f"parked {emu.halted} with exit {emu.exit_code}, the theorem says {code}")
    heard = [harness.TAG_HALT, code, 3 + j, 3 + j]
    if emu.prints != heard:
        bad.append(f"heard {[hex(w) for w in emu.prints]}, the theorem says {[hex(w) for w in heard]}")
    mem = bytes(emu.mem)
    at = lambda m, r: m[r[0] - BASE:r[1] - BASE]
    if at(mem, oracle.CONF) != bytes(oracle.CONF[1] - oracle.CONF[0]):
        bad.append("the confidential scratch is not zero at the park")
    if ok:
        digest = hashlib.sha256(pay[kernel_cases.SAMPLES:kernel_cases.SAMPLES + 4096]).digest()
        if at(snap, oracle.DIGEST) != digest:
            bad.append("the digest at the trap is not SHA-256 of the samples")
        if at(mem, oracle.DIGEST) != digest:
            bad.append("the digest at the park is not SHA-256 of the samples")
    else:
        if at(mem, oracle.DIGEST) != bytes(32):
            bad.append("the digest window is not zero at the park")
        kept = [lo for lo in range(len(mem)) if not (
            oracle.CONF[0] <= BASE + lo < oracle.CONF[1] or oracle.DIGEST[0] <= BASE + lo < oracle.DIGEST[1]
            or STACK[0] <= BASE + lo < STACK[1]) and mem[lo] != reset[lo]]
        if kept:
            bad.append(f"{len(kept)} bytes outside the scratch, the digest and the stack changed, the first at "
                       f"{BASE + kept[0]:#x}")
    return [f"{name}: {b}" for b in bad], (ok, trap_at, j)


def run_all():
    mon = oracle.monitor()
    bad, lines, seen = [], [], {True: set(), False: set()}
    cases = streams()
    for name, words in cases.items():
        b, r = run_case(mon, name, words)
        bad += b
        if r:
            seen[r[0]].add(r[1:])
    lines.append(f"PASS  exp222's {len(cases)} streams, exp223's kernel as exp239's payload, from reset to the park:")
    for ok, what in ((True, "healthy"), (False, "unhealthy")):
        if len(seen[ok]) != 1:
            bad.append(f"the {what} streams do not all trap at one step")
            continue
        (t, j), = seen[ok]
        if ok:
            lines.append(f"      {what}: one trap, at step {t} = 53 + {j + 1}, to {TRAP_VECTOR:#x} with mcause 8;"
                         f" heard HALT 0 {3 + j} {3 + j},")
            lines.append("      exit 0; SHA-256 of the samples at +0x2140 at the trap and at the park; the scratch zero")
        else:
            lines.append(f"      {what}: one trap, at step {t} = 53 + {j + 1}, to {TRAP_VECTOR:#x} with mcause 8;"
                         f" heard HALT 1 {3 + j} {3 + j},")
            lines.append("      exit 1; the scratch and the digest window zero, every other byte but the stack as at reset")
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
