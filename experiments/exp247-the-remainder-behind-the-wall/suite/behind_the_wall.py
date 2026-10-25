#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
exp247 on the emulator: exp229's kernel.bin as exp236's payload, step by step, against what proof/Wall.lean says.

`remainder_behind_the_wall` names step numbers and words, and the emulator is a separate program that can disagree:

  the theorem's run   every edge pair of every operation and 60 drawn: the kernel traps at step 53 + count op, for an
                      ecall from U-mode, with (a op b) mod p in R; the monitor is at the park word at step
                      53 + count op + 57; every register is zero; and what the host heard from reset is exactly the
                      HALT report -- 0, then 2 + count op twice -- and the exit code 0. Nothing else traps.
  a call it would not serve
                      the same kernel with the add path's `li t0, 1` made `li t0, 0`: Tier 1 would serve that ecall as
                      HASH and run on. exp236 serves no HASH: it reports a FAULT and exits 1. This is the call
                      `halts_only` rules out, and why the theorem needs it.

`count op` is read from exp229's proof/Field.lean, where the theorem's number is. `run_all()` returns the failures
and the lines to print.
"""

import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../.."))
EXP229 = os.path.join(REPO, "experiments", "exp229-the-remainder-the-kernel-keeps")
EXP236 = os.path.join(REPO, "experiments", "exp236-the-wall-the-monitor-holds")
sys.path.insert(0, EXP229)
sys.path.insert(0, os.path.join(REPO, "tools"))
sys.path.insert(0, os.path.join(REPO, "tools", "monitor"))
from field import OPS, field_cases, field_image, field_ref, result_of  # noqa: E402
import harness  # noqa: E402

PAYLOAD = 0x80010000
TRAP_VECTOR, PARK = 0x80000114, 0x80000234
BOOT, HANDLER = 53, 57
LI_T0_1, LI_T0_0 = 0x00100293, 0x00000293   # addi t0, zero, 1 / 0
ADD_HALT = 413                               # exp229's A_HALT: li a0, 0; li t0, 1; ecall


def counts() -> dict:
    """`count` from exp229's proof: `if op = 0 then 331 else if op = 1 then 238 else 1903`."""
    with open(os.path.join(EXP229, "proof", "Field.lean"), encoding="utf-8") as f:
        t = f.read()
    m = re.search(r"def count \(op : Nat\) : Nat :=\n\s*if op = 0 then (\d+) else if op = 1 then (\d+) else (\d+)", t)
    return {0: int(m.group(1)), 1: int(m.group(2)), 2: int(m.group(3))}


def walk(monitor: bytes, pay: bytes, limit: int = 20000):
    """Step the emulator from reset to the park word: the step it first trapped from U-mode, and the step it parked."""
    emu = harness.SandboxEmulator(harness.image(monitor, pay))
    trap_at = park_at = None
    for n in range(1, limit + 1):
        was = emu.mode
        emu.step()
        if trap_at is None and was == "U" and emu.mode == "M":
            trap_at = n
            trap = dict(pc=emu.pc, mcause=emu.mcause, mepc=emu.mepc, r=result_of(bytes(emu.mem[PAYLOAD - harness.BASE:])))
        if emu.pc == PARK:
            park_at = n
            break
    emu.run(10)                               # the park word itself: wfi
    return emu, trap_at, park_at, (trap if trap_at else None)


def run_all(n: int = 60):
    with open(os.path.join(EXP236, "monitor.bin"), "rb") as f:
        monitor = f.read()
    with open(os.path.join(EXP229, "kernel.bin"), "rb") as f:
        kernel = f.read()
    count = counts()
    bad, lines = [], []

    cases = field_cases(n, seed=247)
    seen = {op: set() for op in OPS}
    for op, a, b in cases:
        emu, trap_at, park_at, trap = walk(monitor, field_image(kernel, op, a, b))
        want = field_ref(op, a, b)
        c = count[op]
        heard = [harness.TAG_HALT, 0, 2 + c, 2 + c]
        why = []
        if trap_at != BOOT + c:
            why.append(f"trapped at step {trap_at}, the theorem says {BOOT + c}")
        elif trap["pc"] != TRAP_VECTOR or trap["mcause"] != 8:
            why.append(f"trapped to {trap['pc']:#x} with mcause {trap['mcause']}")
        elif trap["r"] != want:
            why.append(f"R = {trap['r']:#x} at the trap, want {want:#x}")
        if park_at != BOOT + c + HANDLER:
            why.append(f"at the park word at step {park_at}, the theorem says {BOOT + c + HANDLER}")
        if emu.prints != heard or emu.exit_code != 0:
            why.append(f"heard {[hex(w) for w in emu.prints]} and exit {emu.exit_code}, the theorem says "
                       f"{[hex(w) for w in heard]} and 0")
        if any(emu.regs[r] for r in range(32)):
            why.append("a register is not zero at the park")
        if len(emu.traps) != 1:
            why.append(f"{len(emu.traps)} traps, the theorem's run has one")
        if result_of(bytes(emu.mem[PAYLOAD - harness.BASE:])) != want:
            why.append("R is not the remainder at the park")
        if why:
            bad.append(f"{OPS[op]} {a:#x} {b:#x}: " + "; ".join(why))
        seen[op].add((trap_at, park_at, trap["mepc"] if trap else None))
    lines.append(f"PASS  {len(cases)} cases -- every edge pair of each operation, and {n} drawn from seed 247 -- run from reset")
    lines.append("      on exp236's monitor with exp229's kernel as its payload, each as the theorem says:")
    for op in OPS:
        (t, p, e), = seen[op] if len(seen[op]) == 1 else [(None, None, None)]
        if t is None:
            bad.append(f"{OPS[op]}: the cases do not all trap and park at the same steps")
            continue
        lines.append(f"      {OPS[op]}  traps at step {t} (53 + {count[op]}) from the ecall at {e:#x}, parks at step {p},"
                     f" heard HALT 0 {2 + count[op]} {2 + count[op]}, exit 0")
    lines.append("      R holds (a op b) mod p at the trap and still at the park; every register zero; one trap")

    words = bytearray(kernel)
    at = 4 * (ADD_HALT + 1)
    if struct.unpack("<I", words[at:at + 4])[0] != LI_T0_1:
        bad.append(f"a call it would not serve: the word at {at:#x} is not li t0, 1")
    else:
        words[at:at + 4] = struct.pack("<I", LI_T0_0)
        emu, trap_at, park_at, trap = walk(monitor, field_image(bytes(words), 0, 42, 58))
        rep = harness.reported(emu, harness.TAG_FAULT)
        if emu.exit_code != 1 or rep is None or trap is None or trap["mcause"] != 8:
            bad.append(f"a call it would not serve: exit {emu.exit_code}, report {rep}")
        lines.append(f"PASS  a call it would not serve: add, with li t0, 0 before its ecall at {trap['mepc']:#x} -- a HASH, which Tier 1")
        lines.append(f"      would serve and run on. exp236 traps it (mcause {trap['mcause']}), reports FAULT and exits"
                     f" {emu.exit_code}: the kernel's own")
        lines.append("      theorem would still hold, and the run behind the wall would not be its run")
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
