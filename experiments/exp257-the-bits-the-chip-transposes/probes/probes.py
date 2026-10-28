#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Probes: what the two RP2350 cores read back, and where the older one -- the chip's -- differs.

exp256's probes, on exp256's scaffolding (an M-mode program alone in RAM from reset, printing what it found), asked
of tb_e6-rp2350 beside tb-rp2350, and these besides:

  * the hardwired regions' registers, which no access in the testbench can reach (pmpdiff.py says why);
  * E6 itself, a byte at a time: the specification's R and W (`0x1b`) and R, W in the chip's order (`0x1e`);
  * PMPCFGM0 written all ones;
  * exp209's check 2, the one thing its board run found the chip doing that the RTL did not.

`--table` prints both cores' words, a line each, marking where they differ; `--check` holds that to table.txt. What
the board reads, the same programs on the chip, is the next round's.
"""

import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../.."))
sys.path.insert(0, os.path.join(REPO, "tools", "monitor"))
import privdiff  # noqa: E402

# exp256's probes, by path: this file has the same name
_spec = importlib.util.spec_from_file_location(
    "exp256_probes", os.path.join(REPO, "experiments", "exp256-the-readings-the-rtl-settles", "probes", "probes.py"))
exp256 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(exp256)
from monitor.emulator import SandboxEmulator  # noqa: E402

P = exp256.PRINT
TBDIR = os.path.join(REPO, "tools", "hazard3", "Hazard3", "test", "sim", "tb_verilator")
CORES = ["tb_e6-rp2350", "tb-rp2350"]

# one entry over U-mode's code, with this configuration byte, before entry 1 over all of RAM
OVER_USER = ("    la t0, user\n    srli t0, t0, 2\n    ori t0, t0, 3\n    csrw pmpaddr0, t0\n"
             "    li t0, 0x20007fff\n    csrw pmpaddr1, t0\n    li t0, 0x1f{b:02x}\n    csrw pmpcfg0, t0\n")

PROBES = exp256.PROBES + [
    ("hardwired", "pmpaddr8, 9, 10 and pmpcfg2: the ROM, the peripherals, SIO",
     "".join(f"    csrr t0, {r:#x}\n" + P.format(r="t0") for r in (0x3b8, 0x3b9, 0x3ba, 0x3a2))),
    ("cfg_1b", "entry 0 `0x1b` over U-mode's code: U-mode loads from it",
     OVER_USER.format(b=0x1b) + exp256.TO_USER + "    auipc t0, 0\n    lw t1, 0(t0)\n    ecall\n"),
    ("cfg_1e", "entry 0 `0x1e` over U-mode's code: U-mode runs it",
     OVER_USER.format(b=0x1e) + exp256.TO_USER + "    nop\n    ecall\n"),
    ("exp209_check2", "exp209's check 2, which failed on the chip and passed on the RTL: entry 0 written NAPOT over "
     "64 KiB, `0x1f`; pmpcfg0's low byte, and pmpaddr0 xor what was written",
     "    li t1, 0x20005fff\n    csrw pmpaddr0, t1\n    li t0, 0x1f\n    csrw pmpcfg0, t0\n"
     "    csrr t0, pmpcfg0\n    andi t0, t0, 0xff\n" + P.format(r="t0") +
     "    csrr t0, pmpaddr0\n    xor t0, t0, t1\n" + P.format(r="t0")),
    ("pmpcfgm0_ones", "PMPCFGM0 written all ones: which bits stick",
     "    li t0, -1\n    csrw 0xbd0, t0\n    csrr t1, 0xbd0\n    csrw 0xbd0, zero\n" + P.format(r="t1")),
]


def table() -> str:
    out = [f"{'probe':20} {'core':13} words printed"]
    for name, what, body in PROBES:
        snap = SandboxEmulator(exp256.image(body))
        steps = exp256.run_steps(body)
        got = []
        for tb in CORES:
            prints, code, _ = privdiff.rtl_run(snap, steps, os.path.join(TBDIR, tb))
            got.append(" ".join(f"{w:08x}" for w in prints) + ("" if code is not None else " hangs"))
        for i, tb in enumerate(CORES):
            mark = "   <- not tb-rp2350's" if i == 0 and got[0] != got[1] else ""
            out.append(f"{name if i == 0 else '':20} {tb:13} {got[i]}{mark}".rstrip())
    return "\n".join(out) + "\n"


def main():
    if "--check" in sys.argv:
        want = open(os.path.join(HERE, "table.txt"), encoding="utf-8").read()
        got = table()
        if got == want:
            n = sum("<- not tb-rp2350's" in ln for ln in got.splitlines())
            print(f"PASS  {len(PROBES)} probes on two cores print what probes/table.txt recorded: "
                  f"{n} where the chip's core is not the pinned one")
            return 0
        print("FAIL  the probes print something other than probes/table.txt:")
        for a, b in zip(want.splitlines(), got.splitlines()):
            if a != b:
                print(f"      was  {a}\n      now  {b}")
        return 1
    print(table(), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
