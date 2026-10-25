#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
exp246 on the emulator: exp240's monitor and exp245's, two rounds each, the same payload, the same host.

What proof/Equiv.lean says, run: one round under either monitor is the same round -- the exit code, the report, the
traps, the box at the park but for exp245's slot -- and the next round is the same too when the first left the slot
zero. And what it does not say: when the first round leaves something in the slot, the second may differ.

  the slot kept     round 1 stores a word in the slot and HALTs; round 2 HALTs with what the slot holds. The rounds
                    differ: exp240's round 2 finds the word, exp245's finds 0. The hypothesis is not idle.
  the slot cleared  the same, but round 1 zeroes the slot before its HALT. The two are the same, both rounds.
  random payloads   200 payloads from a fixed seed: eight operations each, stores and loads to the code, the data, the
                    slot, the stack and outside the box, register arithmetic, and a HALT or a fault. Each round 1 is
                    the same under the two monitors; each round 2 is the same whenever round 1 left the slot zero;
                    and the payloads that left something in the slot are counted, with how many of those round 2
                    told apart.

`run_all()` returns the failures and the lines to print.
"""

import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../.."))
sys.path.insert(0, os.path.join(REPO, "experiments", "exp240-the-code-the-box-forbids-writing", "suite"))
import oracle
import harness
import wx_attacks
from monitor.emulator import BASE

EXP245 = os.path.join(REPO, "experiments", "exp245-the-bytes-the-proof-blesses")
SLOT = (0x80010E00, 0x80010E20)
SHRINE = (0x80008010, 0x80008018)
MODE_AT = 0x80010700
MONITOR_END = 0x800002C8          # the longer of the two monitors' words


def monitors():
    with open(os.path.join(EXP245, "monitor.bin"), "rb") as f:
        return oracle.monitor(), f.read()


def two_rounds(mon: bytes, pay: bytes):
    one = harness.run(mon, pay)
    two = harness.reenter(one)
    two.mem[MODE_AT - BASE:MODE_AT + 4 - BASE] = struct.pack("<I", 1)
    two.run(400000)
    return one, two


def seen(emu) -> tuple:
    """What the host heard and the payload left: the exit code, the reports, the traps and the box."""
    box = bytes(emu.mem[0x80010000 - BASE:0x80020000 - BASE])
    return (emu.exit_code, tuple(emu.prints), tuple((t["cause"], t["tval"], t["mepc"], t["mode"]) for t in emu.traps),
            box, tuple(emu.regs))


def without_slot(emu) -> tuple:
    exit_code, prints, traps, box, regs = seen(emu)
    lo, hi = SLOT[0] - 0x80010000, SLOT[1] - 0x80010000
    return exit_code, prints, traps, box[:lo] + box[hi:], regs


def slot_zero(emu) -> bool:
    return bytes(emu.mem[SLOT[0] - BASE:SLOT[1] - BASE]) == bytes(SLOT[1] - SLOT[0])


KEPT = """
    lui   t3, 0x80010
    lw    t4, 0x700(t3)
    addi  t5, t3, 0x700
    addi  t5, t5, 0x700        // the slot
    bnez  t4, 1f
    li    t1, 0x51075107
    sw    t1, 0(t5)
    li    a0, 0
    j     2f
1:  lw    a0, 0(t5)
2:  li    t0, 1
    ecall
"""
CLEARED = KEPT.replace("    li    a0, 0\n    j     2f\n", "    sw    zero, 0(t5)\n    li    a0, 0\n    j     2f\n")

# random payloads: where a load or a store may go, from inside the box to outside it
INSIDE = [0x80010100, 0x80010700, 0x80010E00, 0x80010E04, 0x80010E1C, 0x80010FFC, 0x8001F000, 0x8001FFC0, 0x8001FFFC]
OUTSIDE = [0x80010000, 0x80010040, 0x80011000, 0x80020000, 0x80008010, 0x80000000]
TARGETS = INSIDE * 6 + OUTSIDE       # mostly where a store goes in, so that most payloads run to their HALT
REGS = ["t1", "t2", "s0", "s1", "a1", "a2", "a3"]


def random_payload(rng: random.Random) -> str:
    lines = ["lui t3, 0x80010", "lw t4, 0x700(t3)"]
    for _ in range(8):                  # at most 29 words: the code entry holds 32
        r = rng.choice(REGS)
        k = rng.randrange(6)
        if k == 0:
            lines.append(f"li {r}, {rng.randrange(-2048, 2048)}")
        elif k == 1:
            lines.append(f"add {r}, {r}, {rng.choice(REGS)}")
        elif k == 2:
            lines.append(f"xor {r}, {r}, t4")
        else:
            a = rng.choice(TARGETS)
            op = rng.choice(["sw", "lw", "sw", "sb"])
            lines.append(f"li t6, {a:#x}")
            if op == "sb":
                lines.append(f"sb {r}, 0(t6)")
            else:
                lines.append(f"{op} {r}, 0(t6)")
    lines += [f"mv a0, {rng.choice(REGS)}", "li t0, 1", "ecall"]
    return "\n".join(lines)


def run_all(n: int = 200, seed: int = 246):
    m240, m245 = monitors()
    bad, lines = [], []

    one_a, two_a = two_rounds(m240, wx_attacks.assembled(KEPT))
    one_b, two_b = two_rounds(m245, wx_attacks.assembled(KEPT))
    if without_slot(one_a) != without_slot(one_b):
        bad.append("the slot kept: round 1 differs")
    if (two_a.exit_code, two_b.exit_code) != (0x51075107, 0):
        bad.append(f"the slot kept: round 2 exits {two_a.exit_code:#x} and {two_b.exit_code:#x}, wanted 0x51075107 and 0")
    lines.append("PASS  the slot kept: round 1 the same under the two monitors; round 2 HALTs 0x51075107 under exp240's and 0")
    lines.append("      under exp245's -- round 1 left the slot holding a word, and the theorem asks it not to")

    one_a, two_a = two_rounds(m240, wx_attacks.assembled(CLEARED))
    one_b, two_b = two_rounds(m245, wx_attacks.assembled(CLEARED))
    if not slot_zero(one_a):
        bad.append("the slot cleared: round 1 did not leave the slot zero")
    if seen(one_a)[:3] != seen(one_b)[:3] or seen(two_a) != seen(two_b):
        bad.append("the slot cleared: the rounds differ")
    lines.append("PASS  the slot cleared: round 1 zeroes the slot before its HALT; both rounds the same under the two monitors,")
    lines.append("      round 2's box byte for byte")

    rng = random.Random(seed)
    kept = told = 0
    ends = {}
    for i in range(n):
        src = random_payload(rng)
        pay = wx_attacks.assembled(src)
        one_a, two_a = two_rounds(m240, pay)
        one_b, two_b = two_rounds(m245, pay)
        if without_slot(one_a) != without_slot(one_b):
            bad.append(f"random payload {i}: round 1 differs")
            continue
        end = "HALT" if one_a.traps and one_a.traps[-1]["cause"] == 8 and one_a.exit_code != 1 else f"mcause {one_a.mcause}"
        ends[end] = ends.get(end, 0) + 1
        if slot_zero(one_a):
            if seen(two_a)[:3] != seen(two_b)[:3] or without_slot(two_a) != without_slot(two_b):
                bad.append(f"random payload {i}: round 1 left the slot zero, and round 2 differs")
        else:
            kept += 1
            if without_slot(two_a) != without_slot(two_b):
                told += 1
    lines.append(f"PASS  {n} random payloads from seed {seed}, two rounds each: every round 1 the same under the two monitors,")
    lines.append(f"      the slot aside; every round 2 the same when round 1 left the slot zero ({n - kept} of them); {kept}")
    lines.append(f"      left something in the slot, and round 2 told the monitors apart for {told} of those")
    lines.append("      round 1 ended: " + ", ".join(f"{v} {k}" for k, v in sorted(ends.items(), key=lambda kv: -kv[1])))
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
