#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
exp254 on the emulator: exp225's kernel as exp240's payload, from reset, against what proof/Box.lean says.

`life_behind_the_box` says that from reset, or from any CSRs that lock no PMP entry, after exactly 61 + 3079 + 57
steps the monitor is parked with HALT 0 and every register zero; that memory is exp225's `lived` but for the
monitor's stack and report words; and that the host has heard the HALT report -- a0 = 0, 3081 instructions, 3081
cycles -- then 0 at the exit word, and nothing before. Its proof composes the run: 61 steps of boot, the kernel's
3079 one Tier 2 step each, every step before the last in U-mode and the last the `ecall` that traps, then 57 to the
park.

The emulator is a separate program that can disagree. On 104 seeds -- 0, 1, one live cell, all ones, and 100 drawn
from a fixed seed -- in 256 KiB of junk, every other one from a reset that leaves junk in the CSRs:

  the count     the park word first reached at step 61 + 3079 + 57, U-mode from step 61 to the trap, one trap only
  the park      M-mode, every register zero, exit code 0
  the report    the print words exactly the HALT tag, 0, 3081, 3081
  the memory    rule30.py's history at +0x200, and every other byte as it was but the monitor's 16 stack bytes

`run_all()` returns the failures and the lines to print.
"""

import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../.."))
EXP225 = os.path.join(REPO, "experiments", "exp225-the-life-every-beat-proved")
sys.path.insert(0, os.path.join(REPO, "experiments", "exp240-the-code-the-box-forbids-writing", "suite"))
sys.path.insert(0, EXP225)
import oracle  # noqa: E402
import harness  # noqa: E402
import rule30  # noqa: E402
from monitor.emulator import SandboxEmulator, BASE  # noqa: E402
from rounds import kernel  # noqa: E402

PARK = 0x80000254
BOOT, KERNEL, HALT = 61, 3079, 57
STACK = (0x80008000 - BASE, 0x80008010 - BASE)
HIST = oracle.BOX - BASE + rule30.HIST_OFF


def ram(mon: bytes, seed: int, junk: random.Random) -> bytes:
    """256 KiB: junk in every byte, the monitor at 0, the kernel and its seed at the start of the box."""
    r = bytearray(junk.randbytes(0x40000))
    r[:len(mon)] = mon
    box = oracle.BOX - BASE
    r[box:box + rule30.HIST_OFF] = rule30.image(kernel(), seed)[:rule30.HIST_OFF]
    return bytes(r)


def run_case(mon: bytes, seed: int, junk: random.Random, junk_csrs: bool):
    before = ram(mon, seed, junk)
    emu = harness.reenter(SandboxEmulator(before), junk_csrs=junk_csrs)
    tag = f"seed {seed:#010x}{' (junk CSRs)' if junk_csrs else ''}"
    modes, park_at = [], None
    for n in range(1, BOOT + KERNEL + HALT + 100):
        emu.step()
        modes.append(emu.mode)
        if emu.pc == PARK:
            park_at = n
            break
    if park_at is None:
        return [f"{tag}: never reached the park word"]
    bad = []
    if park_at != BOOT + KERNEL + HALT:
        bad.append(f"{tag}: parked at step {park_at}, the composed count is {BOOT} + {KERNEL} + {HALT}")
    # modes[i] is the mode after step i + 1: U from step 61 to step 61 + 3078, M at the trap
    if set(modes[BOOT - 1:BOOT + KERNEL - 1]) != {"U"} or modes[BOOT + KERNEL - 1] != "M":
        bad.append(f"{tag}: not in U-mode from step {BOOT} to {BOOT + KERNEL - 1} and M-mode after the trap")
    if [(t["cause"], t["mode"]) for t in emu.traps] != [(8, "U")]:
        bad.append(f"{tag}: traps {[(t['cause'], t['mode']) for t in emu.traps]}, wanted one ecall from U-mode")
    emu.run(10)
    if not emu.halted or emu.mode != "M" or any(emu.regs) or emu.exit_code != 0:
        bad.append(f"{tag}: not parked in M-mode with every register zero and exit 0")
    if emu.prints != [harness.TAG_HALT, 0, 3081, 3081]:
        bad.append(f"{tag}: the print words are {[hex(p) for p in emu.prints]}, wanted HALT, 0, 3081, 3081")
    want = bytearray(before)
    want[HIST:HIST + 4 * rule30.N] = rule30.history_bytes(seed)
    got = bytearray(emu.mem)
    got[STACK[0]:STACK[1]] = want[STACK[0]:STACK[1]]
    if got != want:
        bad.append(f"{tag}: memory is not exp225's lived but for the stack words: differs at "
                   + ", ".join(harness.differences(bytes(want), bytes(got))))
    return bad


def run_all(n: int = 100):
    mon = oracle.monitor()
    r = random.Random(254)
    seeds = [0, 1, 1 << 16, 0xFFFFFFFF] + [r.getrandbits(32) for _ in range(n)]
    junk = random.Random(225)
    bad = []
    for i, s in enumerate(seeds):
        bad += run_case(mon, s, junk, junk_csrs=i % 2 == 1)
    lines = [f"PASS  {len(seeds)} seeds -- 0, 1, one live cell, all ones, and {n} from seed 254 -- exp225's kernel as exp240's",
             "      payload in 256 KiB of junk, from reset, every other one from a reset that leaves junk in the CSRs:",
             f"      each first at the park word at step {BOOT} + {KERNEL} + {HALT}, in U-mode from step {BOOT} to the trap, one trap,",
             "      the ecall; parked in M-mode, every register zero, exit 0; the print words HALT, 0, 3081, 3081;",
             "      memory rule30.py's history at +0x200 and every other byte as it was, but the monitor's 16 stack bytes"]
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
