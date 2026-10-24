#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
exp245's charms, on the emulator of tools/monitor: what each theorem says, and what each charm does.

Every act reports two things: that the charm's own theorem holds in this run, and what actually happened.

  Act 1a  the shrine seal: a payload overwrites its whole output and HALTs. The seal is intact, the HALT is
          reported; the payload's output is not what the seal is about, and nothing claimed it was.
  Act 1b  the shrine seal, from outside the model: the suite writes a word of the seal while the payload runs,
          standing for a DMA channel or the other core. Under exp245 the HALT becomes a FAULT; under exp240, the
          same write, the HALT stands. The one place a charm does anything, and it is outside the model.
  Act 2   the shadowed entry: entry 3 is read-only over the seed window, as booted; a payload stores into the
          window, reads it back and HALTs with what it read. The store goes in: entry 1 decides first.
  Act 3   the ceremonial scrub: in round 1 a payload leaves a 32-byte key on its stack and HALTs; between the
          rounds the host writes one word in the data; in round 2 the same payload copies what is on the stack
          to its output. The slot is zero at both parks, and round 2's output is round 1's key.
  Act 4   the ablation: monitor.S with the three charms taken away is exp240's monitor.bin (monitor.py checks
          that); and here, exp240, exp245 and exp245 with each charm taken away alone run exp240's hostile
          payloads, exp225's Rule 30 kernel for rounds, and Acts 1a, 2 and 3. Everything the payload can see or
          the host hears is the same for all five. What differs is a list: the monitor's own words, the trap
          vector, and the bytes and CSRs that the charms present write -- the shrine, the slot, entry 3.

`run_all()` returns the failures and the lines to print.
"""

import importlib.util
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EXP245 = os.path.dirname(HERE)
REPO = os.path.abspath(os.path.join(EXP245, "../.."))
SUITE240 = os.path.join(REPO, "experiments", "exp240-the-code-the-box-forbids-writing", "suite")
sys.path.insert(0, SUITE240)
import oracle            # exp240's box: CODE, DATA, STACK, and its monitor.bin
import harness
import rounds
import wx_attacks
from monitor.emulator import SandboxEmulator, BASE

_spec = importlib.util.spec_from_file_location("exp245_monitor", os.path.join(EXP245, "monitor.py"))
mon245 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mon245)

SHRINE, SEAL = (0x80008010, 0x80008018), (0x4D414D4F, 0x4941554B)
SEED = (0x80010100, 0x80010200)
SLOT = (0x80010E00, 0x80010E20)
KEY = (0x8001FFC0, 0x8001FFE0)            # where Act 3's payload leaves its key: on the stack, not in the slot
MODE_AT, OUT_AT = 0x80010700, 0x80010900  # Act 3: the host's word, and where round 2 writes what it found
YELLOW = 0x4C4C4559                       # "YELL": what Act 1b writes over "KUAI"
ENTRY3 = (0x19, 0x2000405F)               # charm 2's entry 3: NAPOT read-only, and its address


def monitor() -> bytes:
    with open(os.path.join(EXP245, "monitor.bin"), "rb") as f:
        return f.read()


def monitors() -> dict:
    """The five monitors Act 4 compares, by name: exp240, exp245, and exp245 with one charm taken away."""
    out = {"exp240": oracle.monitor(), "exp245": monitor()}
    for c in mon245.CHARMS:
        out[f"exp245 without charm {c}"] = mon245.ablated([c])
    return out


def charms_of(name: str) -> set:
    if name == "exp240":
        return set()
    if name == "exp245":
        return {1, 2, 3}
    return {1, 2, 3} - {int(name.rsplit(" ", 1)[1])}


def word(emu, addr):
    return harness.word(emu, addr)


def sealed(emu) -> bool:
    return (word(emu, SHRINE[0]), word(emu, SHRINE[0] + 4)) == SEAL


def slot_zero(emu) -> bool:
    return bytes(emu.mem[SLOT[0] - BASE:SLOT[1] - BASE]) == bytes(SLOT[1] - SLOT[0])


# ---- the payloads

ACT1A = """
    lui   t3, 0x80010
    addi  t3, t3, 0x200
    addi  t4, t3, 0x400
    li    t1, 0x5a5a5a5a
1:  sw    t1, 0(t3)
    addi  t3, t3, 4
    bne   t3, t4, 1b
    li    t0, 1
    li    a0, 0
    ecall
"""

ACT1B = """
    li    t2, 1000
1:  addi  t2, t2, -1
    bnez  t2, 1b
    li    t0, 1
    li    a0, 0
    ecall
"""

ACT2 = """
    lui   t3, 0x80010
    addi  t3, t3, 0x100
    li    t1, 0x5eed5eed
    sw    t1, 0(t3)
    lw    a0, 0(t3)
    li    t0, 1
    ecall
"""

ACT3 = """
    lui   t3, 0x80010
    lw    t4, 0x700(t3)        // the host's word: 0 in round 1, 1 in round 2
    lui   t5, 0x80020
    addi  t5, t5, -64          // 0x8001ffc0, below sp
    addi  t6, t5, 32
    bnez  t4, 2f
    li    t1, 0x6b657930       // round 1: the key, eight words, on the stack
1:  sw    t1, 0(t5)
    addi  t1, t1, 1
    addi  t5, t5, 4
    bne   t5, t6, 1b
    j     4f
2:  addi  a1, t3, 0x700        // round 2: copy what is there to the output, 0x80010900
    addi  a1, a1, 0x200
3:  lw    t1, 0(t5)
    sw    t1, 0(a1)
    addi  t5, t5, 4
    addi  a1, a1, 4
    bne   t5, t6, 3b
4:  li    t0, 1
    li    a0, 0
    ecall
"""
KEYWORDS = [0x6B657930 + i for i in range(8)]


def run_act1a(mon):
    return harness.run(mon, wx_attacks.assembled(ACT1A))


def run_act1b(mon, intrude=True):
    """Act 1b: 200 steps into the payload, a word of the seal is written from outside the model."""
    emu = SandboxEmulator(harness.image(mon, wx_attacks.assembled(ACT1B)))
    u = 0
    for _ in range(400000):
        if emu.halted:
            break
        emu.step()
        if emu.mode == "U":
            u += 1
            if u == 200 and intrude:
                emu.mem[SHRINE[0] + 4 - BASE:SHRINE[0] + 8 - BASE] = struct.pack("<I", YELLOW)
    return emu


def run_act2(mon):
    return harness.run(mon, wx_attacks.assembled(ACT2))


def run_act3(mon):
    """(round 1, round 2): the same payload twice, the host's one write between."""
    one = harness.run(mon, wx_attacks.assembled(ACT3))
    host = harness.reenter(one)
    host.mem[MODE_AT - BASE:MODE_AT + 4 - BASE] = struct.pack("<I", 1)
    host.run(400000)
    return one, host


# ---- Act 4: what a payload can see and the host hears, and what differs

def visible(emu) -> tuple:
    """Everything of a parked machine the payload could see or the host hears, but memory and the CSRs a charm writes."""
    return (tuple(emu.regs), emu.halted, emu.exit_code, emu.mode, tuple(emu.prints),
            tuple((t["cause"], t["tval"], t["mepc"], t["mode"], t["by"]) for t in emu.traps),
            emu.mstatus, emu.mscratch, emu.mepc, emu.mcause, emu.mcountinhibit, emu.minstret, emu.mcycle,
            emu.pmpcfg0 & 0x00FFFFFF, tuple(emu.pmpaddr[:3]))


def allowed(charms: set, mon_len: int) -> list:
    """The byte ranges a run under a monitor with `charms` may differ in from exp240's: the monitor's own words, and
    what the charms write."""
    out = [(BASE, BASE + max(mon_len, len(oracle.monitor())))]
    if 1 in charms:
        out.append(SHRINE)
    if 3 in charms:
        out.append(SLOT)
    return out


def compare(base, other, charms: set, mon_len: int, what: str) -> list:
    """What differs between a run under exp240 (`base`) and one under a monitor with `charms` (`other`), outside what
    those charms are allowed to differ in."""
    bad = []
    if visible(base) != visible(other):
        bad.append(f"{what}: the machine differs where the payload or the host would see it")
    ok = allowed(charms, mon_len)
    for lo, hi in harness.difference_ranges(bytes(base.mem), bytes(other.mem)):
        if not any(a <= lo and hi <= b for a, b in ok):
            bad.append(f"{what}: memory differs at [{lo:#x}, {hi:#x})")
    want3 = ENTRY3 if 2 in charms else (base.pmpcfg0 >> 24, base.pmpaddr[3])
    if (other.pmpcfg0 >> 24, other.pmpaddr[3]) != want3:
        bad.append(f"{what}: entry 3 is not what the charms present set")
    return bad


def act4_rounds(mons: dict, n: int) -> list:
    """exp225's Rule 30 kernel, `n` rounds under each monitor from the same first RAM, junk in the CSRs every other
    round; each round compared with exp240's."""
    bad = []
    seed0 = rounds.rule30.SEED0
    cores = {k: SandboxEmulator(rounds.first_ram(m, seed0)) for k, m in mons.items()}
    for r in range(1, n + 1):
        done = {}
        for k, core in cores.items():
            core.run(400000)
            done[k] = core
        bad += [f"exp240, round {r}: {x}" for x in harness.check_halt(done["exp240"], mons["exp240"], 0)]
        for k in mons:
            if k != "exp240":
                bad += compare(done["exp240"], done[k], charms_of(k), len(mons[k]), f"{k}, round {r}")
        hist = bytes(done["exp240"].mem[rounds.HIST_AT:rounds.HIST_AT + rounds.HIST_LEN])
        seed = struct.unpack_from("<I", hist, rounds.HIST_LEN - 4)[0]
        nxt = {}
        for k, core in done.items():
            core.mem[rounds.SEED_AT:rounds.SEED_AT + 4] = struct.pack("<I", seed)
            nxt[k] = harness.reenter(core, junk_csrs=r % 2 == 1)
        cores = nxt
    return bad


def act4(mons: dict, n_rounds: int = 20) -> list:
    bad = []
    for name, src, _want in wx_attacks.ATTACKS:
        pay = wx_attacks.assembled(src)
        base = harness.run(mons["exp240"], pay)
        for k, m in mons.items():
            if k != "exp240":
                bad += compare(base, harness.run(m, pay), charms_of(k), len(m), f"{k}, {name}")
    for label, run in (("Act 1a", run_act1a), ("Act 2", run_act2), ("Act 3, round 2", lambda m: run_act3(m)[1])):
        base = run(mons["exp240"])
        for k, m in mons.items():
            if k != "exp240":
                bad += compare(base, run(m), charms_of(k), len(m), f"{k}, {label}")
    bad += act4_rounds(mons, n_rounds)
    return bad


# ---- the acts

def run_all():
    mon, m240 = monitor(), oracle.monitor()
    bad, lines = [], []

    e = run_act1a(mon)
    b = harness.check_halt(e, mon, 0)
    if not sealed(e):
        b.append("the seal is not intact at the park")
    bad += [f"Act 1a: {x}" for x in b]
    lines.append("PASS  Act 1a, the shrine seal: a payload overwrites its whole output [0x80010200, 0x80010600) and HALTs 0;")
    lines.append("      the theorem's conclusion holds -- the seal reads \"OMAMKUAI\", the HALT is reported -- and that is all it")
    lines.append("      says: the 8 bytes it checks are the monitor's own, and the payload's output was never among them")

    e, e0 = run_act1b(mon), run_act1b(m240)
    b = harness.check_fault(e, mon, 8) + harness.check_halt(e0, m240, 0)
    if sealed(e):
        b.append("the write from outside did not land")
    clean = run_act1b(mon, intrude=False)
    b += harness.check_halt(clean, mon, 0)
    bad += [f"Act 1b: {x}" for x in b]
    lines.append("PASS  Act 1b, the shrine seal from outside the model: 200 steps into the payload the suite writes \"YELL\"")
    lines.append(f"      over \"KUAI\" at {SHRINE[0] + 4:#x}, standing for a DMA channel or the other core. exp245: FAULT, mcause 8")
    lines.append("      (the ecall), a0 = 1; exp240, the same write: HALT 0. Without the write, exp245 HALTs 0. The one place a")
    lines.append("      charm does anything, and the writer is not in the model the theorems are about")

    e = run_act2(mon)
    b = harness.check_halt(e, mon, 0x5EED5EED)
    ent = e.pmp_entry(3)
    if ent[:4] != ("NAPOT", True, False, False) or ent[5:] != SEED:
        b.append(f"entry 3 as booted is {ent}, wanted NAPOT read-only over {SEED}")
    if [t["cause"] for t in e.traps] != [8]:
        b.append(f"traps {[t['cause'] for t in e.traps]}, wanted the ecall alone")
    bad += [f"Act 2: {x}" for x in b]
    lines.append("PASS  Act 2, the shadowed entry: entry 3 as booted is NAPOT, read-only, over [0x80010100, 0x80010200) -- the")
    lines.append("      theorem's conclusion -- and a payload stores 0x5eed5eed at 0x80010100, reads it back and HALTs with it:")
    lines.append("      HALT 0x5eed5eed, one trap, the ecall. Entry 1, the data, is tried first and lets the store in")

    one, two = run_act3(mon)
    b = harness.check_halt(one, mon, 0) + harness.check_halt(two, mon, 0)
    if not (slot_zero(one) and slot_zero(two)):
        b.append("the slot is not zero at a park")
    got = list(struct.unpack_from("<8I", two.mem, OUT_AT - BASE))
    if got != KEYWORDS:
        b.append(f"round 2's output is {[hex(x) for x in got]}, not round 1's key")
    bad += [f"Act 3: {x}" for x in b]
    lines.append("PASS  Act 3, the ceremonial scrub: round 1 leaves a key of eight words at [0x8001ffc0, 0x8001ffe0) on its")
    lines.append("      stack and HALTs 0; the host writes one word in the data; round 2, the same payload, copies the stack to")
    lines.append("      0x80010900 and HALTs 0. The slot [0x80010e00, 0x80010e20) is zero at both parks -- the theorem's")
    lines.append(f"      conclusion -- and round 2's output is round 1's key: {KEYWORDS[0]:#x} .. {KEYWORDS[-1]:#x}")

    mons = monitors()
    b = act4(mons)
    bad += [f"Act 4: {x}" for x in b]
    lines.append(f"PASS  Act 4, the ablation: exp240, exp245, and exp245 with each charm taken away alone, under "
                 f"{len(wx_attacks.ATTACKS)} hostile")
    lines.append("      payloads, Acts 1a, 2 and 3, and 20 rounds of exp225's Rule 30 kernel: the registers, the reports and")
    lines.append("      the exit codes, the traps, the counters and every CSR the payload's box is made of are the same for")
    lines.append("      all five; memory differs only in the monitor's words, the shrine if charm 1 is there and the slot if")
    lines.append("      charm 3 is; entry 3 differs only if charm 2 is")
    return bad, lines


def main():
    bad, lines = run_all()
    if bad:
        for b in bad[:40]:
            print(f"FAIL  {b}")
        if len(bad) > 40:
            print(f"FAIL  and {len(bad) - 40} more")
        sys.exit(1)
    print("\n".join(lines))


if __name__ == "__main__":
    main()
