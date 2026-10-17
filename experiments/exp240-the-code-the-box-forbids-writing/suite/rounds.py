#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
exp225's Rule 30 kernel, round after round under exp240's monitor.

The kernel is exp225's `kernel.bin`, 76 bytes, loaded once at the start of the code entry. Each round the host does
what exp225's shell does and nothing more: it resets the core (harness.reenter: the RAM carries over, the registers and
the CSRs do not), and writes the last generation of the round before, one word, at +0x100 as the seed. The kernel is not
loaded again and the box is not zeroed. A round must

  - end parked with HALT 0, the monitor having counted 3,079 + 2 instructions (exp225's theorem, and the `csrwi` that
    releases the counters and the `mret`), and one trap only, the `ecall`;
  - leave at +0x200 the 1,024 bytes of generations 1 to 256 that `rule30.py` -- Rule 30 written a cell at a time --
    gives from the seed, which the kernel run alone, in M-mode with no monitor, leaves too;
  - change nothing in 256 KiB of RAM but those 1,024 bytes and the two words the monitor saved and zeroed: the code
    entry's bytes, the monitor's, and the junk in every other byte are what they were;
  - leave the machine, but for memory, exactly as the round before did: the registers, the CSRs, the report.

And the hundred rounds together are 25,600 generations of Rule 30 from the first seed.

`run_all(monitor, rounds)` returns (failures, summary); `broken_monitors.py` uses it.
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
from monitor.emulator import SandboxEmulator, BASE
sys.path.insert(0, os.path.join(oracle.REPO, "experiments", "exp225-the-life-every-beat-proved"))
import rule30

KERNEL_INSTRUCTIONS, FRAMING = 3079, 2
ROUNDS = 100
SEED_AT = oracle.BOX - BASE + rule30.SEED_OFF
HIST_AT = oracle.BOX - BASE + rule30.HIST_OFF
HIST_LEN = 4 * rule30.N
STACK_AT = harness.STACK0 - BASE


def kernel() -> bytes:
    with open(os.path.join(oracle.REPO, "experiments", "exp225-the-life-every-beat-proved", "kernel.bin"), "rb") as f:
        return f.read()


def first_ram(mon: bytes, seed: int) -> bytes:
    """256 KiB of RAM: junk in every byte, the monitor at 0, the kernel and its seed at the start of the box."""
    ram = bytearray(random.Random(240).randbytes(0x40000))
    ram[:len(mon)] = mon
    box = oracle.BOX - BASE
    ram[box:box + rule30.HIST_OFF] = rule30.image(kernel(), seed)[:rule30.HIST_OFF]
    return bytes(ram)


def expected(before: bytes, seed: int) -> bytes:
    """RAM after a round: what it was, but for the history and the monitor's two stack words, zeroed."""
    mem = bytearray(before)
    mem[HIST_AT:HIST_AT + HIST_LEN] = rule30.history_bytes(seed)
    mem[STACK_AT:STACK_AT + 8] = bytes(8)
    return bytes(mem)


def fingerprint(emu: SandboxEmulator) -> tuple:
    """The machine at the park, memory aside: nothing a round leaves in it may depend on the round."""
    return (tuple(emu.regs), emu.pc, emu.mode, emu.mstatus, emu.mtvec, emu.mscratch, emu.mepc, emu.mcause, emu.mtval,
            emu.mcountinhibit, emu.pmpcfg0, tuple(emu.pmpaddr), emu.minstret, emu.mcycle, tuple(emu.prints[-4:]),
            emu.exit_code)


def one_round(mon: bytes, start: SandboxEmulator, seed: int):
    """(failures, emulator) for one round from a core just out of reset, its RAM holding `seed` at +0x100."""
    bad = []
    ram = bytes(start.mem)
    emu, snap = harness.snapshot(start)
    bad += harness.check_halt(emu, mon, 0)
    if len(emu.traps) != 1 or emu.traps[0]["cause"] != 8 or emu.traps[0]["mode"] != "U":
        bad.append(f"traps {[(t['cause'], t['mode']) for t in emu.traps]}, wanted one ecall from U-mode")
    rep = harness.reported(emu, harness.TAG_HALT)
    if rep is None or rep[1] != KERNEL_INSTRUCTIONS + FRAMING:
        bad.append(f"HALT reports minstret {rep and rep[1]}, wanted {KERNEL_INSTRUCTIONS} + {FRAMING}")
    want_hist = rule30.history_bytes(seed)
    if bytes(emu.mem[HIST_AT:HIST_AT + HIST_LEN]) != want_hist:
        bad.append("the 256 generations are not rule30.py's")
    want = expected(ram, seed)
    if bytes(emu.mem) != want:
        bad.append("RAM is not what it was but for the history and the monitor's stack words: differs at "
                   + ", ".join(harness.differences(want, bytes(emu.mem))))
    alone = harness.reference_run(ram[oracle.BOX - BASE:oracle.BOX - BASE + harness.PAYLOAD_LEN])
    if alone.exit_code != 0 or alone.minstret != KERNEL_INSTRUCTIONS:
        bad.append(f"alone: exit {alone.exit_code}, {alone.minstret} instructions, wanted 0 and {KERNEL_INSTRUCTIONS}")
    if harness.box(alone)[rule30.HIST_OFF:rule30.HIST_OFF + HIST_LEN] != want_hist:
        bad.append("alone: the 256 generations are not rule30.py's")
    if snap is None or snap[oracle.BOX - BASE:oracle.BOX - BASE + harness.PAYLOAD_LEN] != harness.box(alone):
        bad.append("when the kernel halted, the box differs from the run alone")
    return bad, emu


def run_all(mon: bytes, rounds: int = ROUNDS):
    """(failures, summary): `rounds` rounds from one first RAM, the seed of each the last generation of the one before."""
    seed0 = rule30.SEED0
    seed, core = seed0, SandboxEmulator(first_ram(mon, seed0))
    code0 = bytes(core.mem[oracle.CODE[0] - BASE:oracle.CODE[1] - BASE])
    prints_set, prints_fp = set(), set()
    chain = hashlib.sha256()
    failures = []
    for n in range(1, rounds + 1):
        bad, emu = one_round(mon, core, seed)
        failures += [f"round {n}: {b}" for b in bad]
        if bytes(emu.mem[oracle.CODE[0] - BASE:oracle.CODE[1] - BASE]) != code0:
            failures.append(f"round {n}: the code entry's bytes changed")
        hist = bytes(emu.mem[HIST_AT:HIST_AT + HIST_LEN])
        chain.update(hist)
        prints_fp.add(fingerprint(emu))
        prints_set.add(tuple(harness.reported(emu, harness.TAG_HALT) or ()))
        seed = struct.unpack_from("<I", hist, HIST_LEN - 4)[0]
        emu.mem[SEED_AT:SEED_AT + 4] = struct.pack("<I", seed)      # the host's one write
        core = harness.reenter(emu)
        if failures:
            break
    cells = rule30.history(seed0, rule30.N * rounds)
    ref = hashlib.sha256(struct.pack(f"<{len(cells)}I", *cells))
    if not failures and chain.hexdigest() != ref.hexdigest():
        failures.append(f"the {rounds * rule30.N} generations are not rule30.py's from the first seed")
    if not failures and len(prints_fp) != 1:
        failures.append(f"the parked machine differs from round to round: {len(prints_fp)} different machines")
    summary = {"rounds": rounds, "generations": rounds * rule30.N, "digest": chain.hexdigest(),
               "report": next(iter(prints_set)) if prints_set else None}
    return failures, summary


def main():
    mon = oracle.monitor()
    bad, s = run_all(mon)
    for b in bad:
        print(f"FAIL  {b}")
    if bad:
        sys.exit(1)
    a0, minstret, mcycle = s["report"]
    print(f"PASS  {s['rounds']} rounds of exp225's Rule 30 kernel under the monitor, {s['generations']} generations, "
          f"the kernel loaded once:")
    print(f"      each round: HALT {a0}, minstret {minstret} = {KERNEL_INSTRUCTIONS} + {FRAMING}, mcycle {mcycle}; "
          "one trap, the ecall")
    print("      each round: the 1,024 bytes of history are rule30.py's, and the kernel run alone leaves the same")
    print("      each round: 256 KiB of RAM unchanged but for the history and the monitor's two stack words")
    print("      the code entry's 128 bytes the same after every round; the parked machine the same after every round")
    print(f"      SHA-256 of the {s['generations']} generations: {s['digest']}")
    ctl = run_all(oracle.monitor236(), 10)
    if ctl[0]:
        for b in ctl[0]:
            print(f"FAIL  exp236's monitor: {b}")
        sys.exit(1)
    print("PASS  exp236's monitor, one RWX entry over the box, gives the same: the stricter box costs the kernel nothing")


if __name__ == "__main__":
    main()
