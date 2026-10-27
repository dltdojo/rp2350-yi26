#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
exp255 on the emulator: exp225's kernel as exp240's payload, round after round, against what proof/Rounds.lean says.

`life_round` and `life_rounds` say that every round from a machine that is `Ready` -- after any rounds and any of the
host's writes but the monitor's words, the code and a lock -- parks after 61 + 3079 + 57 steps with HALT 0, the host
hearing HALT, 0, 3081, 3081 and 0, and memory exp225's `lived` of what the round found but for the monitor's stack
words. `life_forever` says that with the host copying the history's last word into the seed, round n + 1's history is
generations 256 n + 1 to 256 n + 256 of the first seed. The emulator is a separate program that can disagree.

  rounds.py's host   100 rounds from one RAM, the kernel loaded once, every other reset leaving junk in the CSRs;
                     the host's one write the last generation into the seed; each round as above, and its history
                     the generations life_forever names, read from rule30.py's 25,600 from the first seed
  any host           20 rounds after each of which the host writes junk over every byte but the monitor's words and
                     the code entry, the seed among them, and resets with junk in the CSRs; each round as above, its
                     history rule30.py's from whatever seed the junk left

`run_all()` returns the failures and the lines to print.
"""

import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../.."))
sys.path.insert(0, os.path.join(REPO, "experiments", "exp240-the-code-the-box-forbids-writing", "suite"))
import oracle  # noqa: E402
import harness  # noqa: E402
import rounds  # noqa: E402
from rounds import rule30  # noqa: E402
from monitor.emulator import BASE  # noqa: E402

PARK, STEPS = 0x80000254, 61 + 3079 + 57
REPORT = [harness.TAG_HALT, 0, 3081, 3081]
MON = 604
CODE = (oracle.CODE[0] - BASE, oracle.CODE[1] - BASE)
SEED = oracle.BOX - BASE + rule30.SEED_OFF
HIST = oracle.BOX - BASE + rule30.HIST_OFF
LAST = HIST + 4 * (rule30.N - 1)
STACK = (harness.STACK0 - BASE, harness.STACK0 - BASE + 16)


def one_round(core, tag):
    """(failures, parked emulator, the seed it found) for one round from a core just out of reset."""
    before = bytes(core.mem)
    seed = struct.unpack_from("<I", before, SEED)[0]
    park_at = None
    for n in range(1, STEPS + 100):
        core.step()
        if core.pc == PARK:
            park_at = n
            break
    core.run(10)
    bad = []
    if park_at != STEPS:
        bad.append(f"{tag}: first at the park word at step {park_at}, the proof's is {STEPS}")
    if not core.halted or core.mode != "M" or any(core.regs) or core.exit_code != 0 or core.prints != REPORT:
        bad.append(f"{tag}: not parked with every register zero, exit 0 and the report HALT, 0, 3081, 3081")
    want = bytearray(before)
    want[HIST:HIST + 4 * rule30.N] = rule30.history_bytes(seed)
    got = bytearray(core.mem)
    got[STACK[0]:STACK[1]] = want[STACK[0]:STACK[1]]
    if got != want:
        bad.append(f"{tag}: memory is not exp225's lived of what the round found: differs at "
                   + ", ".join(harness.differences(bytes(want), bytes(got))))
    return bad, core, seed


def rounds_py_host(mon, n_rounds):
    seed0 = rule30.SEED0
    cells = rule30.history(seed0, rule30.N * n_rounds)
    core = harness.reenter(rounds.SandboxEmulator(rounds.first_ram(mon, seed0)))
    bad = []
    for n in range(n_rounds):
        b, emu, seed = one_round(core, f"round {n + 1}")
        bad += b
        if seed != (cells[rule30.N * n - 1] if n else seed0):
            bad.append(f"round {n + 1}: found the seed {seed:#x}, not generation {rule30.N * n} of the first")
        got = list(struct.unpack_from(f"<{rule30.N}I", emu.mem, HIST))
        if got != cells[rule30.N * n:rule30.N * (n + 1)]:
            bad.append(f"round {n + 1}: the history is not generations {rule30.N * n + 1} to {rule30.N * (n + 1)}")
        emu.mem[SEED:SEED + 4] = emu.mem[LAST:LAST + 4]          # the host's one write
        core = harness.reenter(emu, junk_csrs=n % 2 == 0)
        if bad:
            break
    return bad


def any_host(mon, n_rounds):
    junk = random.Random(255)
    core = harness.reenter(rounds.SandboxEmulator(rounds.first_ram(mon, rule30.SEED0)), junk_csrs=True)
    bad = []
    for n in range(n_rounds):
        b, emu, _ = one_round(core, f"any host, round {n + 1}")
        bad += b
        keep = {o: emu.mem[o] for o in list(range(MON)) + list(range(*CODE))}
        emu.mem[:] = junk.randbytes(len(emu.mem))                 # the host writes everything it may
        for o, v in keep.items():
            emu.mem[o] = v
        core = harness.reenter(emu, junk_csrs=True)
        if bad:
            break
    return bad


def run_all(n_rounds=100, n_any=20):
    mon = oracle.monitor()
    bad = rounds_py_host(mon, n_rounds) + any_host(mon, n_any)
    lines = [f"PASS  {n_rounds} rounds of rounds.py's host, the kernel loaded once, every other reset with junk in the CSRs:",
             f"      each first at the park word at step 61 + 3079 + 57, parked with every register zero, exit 0, the report",
             f"      HALT, 0, 3081, 3081, memory exp225's lived of what it found; round n + 1's seed generation 256 n of the",
             f"      first and its history generations 256 n + 1 to 256 n + 256, {rule30.N * n_rounds} in all",
             f"PASS  {n_any} rounds after a host that writes junk over every byte but the monitor's words and the code entry,",
             "      each from a reset with junk in the CSRs: each the same, its history Rule 30 of the seed the junk left"]
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
