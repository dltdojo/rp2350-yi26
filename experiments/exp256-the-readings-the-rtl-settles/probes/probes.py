#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Probes: one question each, about what a Hazard3 does with one instruction or one CSR write, asked of every reader.

The monitor suites ask what monitors need. These ask what the readers might read differently: the corners of the
privileged specification the monitors never step on, or step on once. Each probe is a small M-mode program, alone
in RAM from the reset vector, that prints what it found to the print port and writes 0 to the exit word:

  * a word it computed, printed as it is;
  * a trap: the handler prints the tag `TRAP`, `mcause` and `mepc`'s offset from the reset vector, and goes on at
    the probe's end -- with `minstret` too, for the probe that counts.

Run as a program, it runs each on the emulator and prints its words. privdiff.py runs it to hold the model to the
emulator, and to hold the RTL to the emulator: every probe starts from reset. `PROBES` is what a test reads.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../.."))
sys.path.insert(0, os.path.join(REPO, "tools"))
sys.path.insert(0, os.path.join(REPO, "tools", "monitor"))
import harness  # noqa: E402
from monitor.emulator import SandboxEmulator, BASE  # noqa: E402

TRAP = 0x54524150

# M-mode from reset: the trap vector, PMP entry 0 over the whole 256 KiB of RAM for U-mode (NAPOT, RWX -- the same
# bits in either order), the print port in s10, where to go on after a trap in s11. A probe that wants `minstret` in
# its trap report sets s9.
PROLOGUE = """
    la    t0, handler
    csrw  mtvec, t0
    li    t0, 0x20007fff
    csrw  pmpaddr0, t0
    li    t0, 0x1f
    csrw  pmpcfg0, t0
    la    s11, done
    li    s10, 0xc0000004
    li    s9, 0
"""
EPILOGUE = """
done:
    li    t0, 0xc0000008
    sw    zero, 0(t0)
park:
    wfi
    j     park
handler:
    li    t0, 0x54524150
    sw    t0, 0(s10)
    csrr  t0, mcause
    sw    t0, 0(s10)
    csrr  t0, mepc
    la    t1, _start
    sub   t0, t0, t1
    sw    t0, 0(s10)
    beqz  s9, 1f
    csrr  t0, minstret
    sw    t0, 0(s10)
1:
    csrw  mepc, s11
    li    t0, 0x1800
    csrs  mstatus, t0
    mret
"""
# into U-mode at the label `user`, which the probe defines
TO_USER = """
    la    t0, user
    csrw  mepc, t0
    li    t0, 0x1800
    csrc  mstatus, t0
    mret
    .balign 32
user:
"""
PRINT = "    sw    {r}, 0(s10)\n"

# name, what it asks, the body
PROBES = [
    ("mstatus_reset", "mstatus as reset leaves it: which privilege an mret returns to before anything writes MPP",
     "    csrr  t0, mstatus\n" + PRINT.format(r="t0")),
    ("mcountinhibit_reset", "mcountinhibit as reset leaves it: whether the counters count before anything writes it",
     "    csrr  t0, mcountinhibit\n" + PRINT.format(r="t0")),
    ("ebreak_u", "ebreak in U-mode: a breakpoint (3), or an illegal instruction (2)",
     TO_USER + "    ebreak\n    ecall\n"),
    ("fence_m", "fence: an instruction, or illegal",
     "    fence\n    li t0, 1\n" + PRINT.format(r="t0")),
    ("misa_m", "reading misa: a value, or illegal",
     "    csrr  t0, misa\n" + PRINT.format(r="t0")),
    ("mhartid_m", "reading mhartid: a value, or illegal",
     "    csrr  t0, mhartid\n" + PRINT.format(r="t0")),
    ("mtvec_bit0", "mtvec written with bit 0 set (vectored mode): read back",
     "    la t1, handler\n    ori t0, t1, 1\n    csrw mtvec, t0\n    csrr t2, mtvec\n    csrw mtvec, t1\n"
     + PRINT.format(r="t2")),
    ("mtvec_bit1", "mtvec written with bit 1 set: read back",
     "    la t1, handler\n    ori t0, t1, 2\n    csrw mtvec, t0\n    csrr t2, mtvec\n    csrw mtvec, t1\n"
     + PRINT.format(r="t2")),
    ("mpp_01", "mstatus written with MPP = 01, a mode Hazard3 does not have: read back",
     "    li t0, 0x800\n    csrw mstatus, t0\n    csrr t1, mstatus\n" + PRINT.format(r="t1")),
    ("mstatus_ones", "mstatus written all ones: which bits stick",
     "    li t0, -1\n    csrw mstatus, t0\n    csrr t1, mstatus\n    csrw mstatus, zero\n" + PRINT.format(r="t1")),
    ("mcountinhibit_ones", "mcountinhibit written all ones: which bits stick",
     "    li t0, -1\n    csrw mcountinhibit, t0\n    csrr t1, mcountinhibit\n" + PRINT.format(r="t1")),
    ("pmpaddr_napot", "pmpaddr1 with its low two bits clear, read back while entry 1 is NAPOT, then while it is OFF",
     "    li t0, 0x20004000\n    csrw pmpaddr1, t0\n    li t0, 0x181f\n    csrw pmpcfg0, t0\n"
     "    csrr t1, pmpaddr1\n" + PRINT.format(r="t1") +
     "    li t0, 0x1f\n    csrw pmpcfg0, t0\n    csrr t1, pmpaddr1\n" + PRINT.format(r="t1")),
    ("pmpcfg_tor", "entry 1 written TOR, which the RP2350 does not have: pmpcfg0 read back",
     "    li t0, 0x0f1f\n    csrw pmpcfg0, t0\n    csrr t1, pmpcfg0\n" + PRINT.format(r="t1")),
    ("pmpcfg_na4", "entry 1 written NA4: pmpcfg0 read back",
     "    li t0, 0x171f\n    csrw pmpcfg0, t0\n    csrr t1, pmpcfg0\n" + PRINT.format(r="t1")),
    ("pmpcfg1", "reading pmpcfg1, entries 4 to 7: a value, or illegal",
     "    csrr  t0, 0x3a1\n" + PRINT.format(r="t0")),
    ("pmpaddr4", "reading pmpaddr4: a value, or illegal",
     "    csrr  t0, 0x3b4\n" + PRINT.format(r="t0")),
    ("pmpcfgm0", "reading Hazard3's PMPCFGM0: a value, or illegal",
     "    csrr  t0, 0xbd0\n" + PRINT.format(r="t0")),
    ("counted_mret", "minstret from a write of 0 to the trap of a U-mode ecall right after an mret",
     "    li s9, 1\n    csrwi mcountinhibit, 0\n    csrw minstret, zero\n" + TO_USER + "    ecall\n"),
    ("lock_m", "entry 0 locked, read only, over 32 bytes M-mode then stores to; entry 1 the RAM",
     "    li t0, 0x20007fff\n    csrw pmpaddr1, t0\n    li t0, 0x20000403\n    csrw pmpaddr0, t0\n"
     "    li t0, 0x1f99\n    csrw pmpcfg0, t0\n"
     "    li t1, 0x80001000\n    sw zero, 0(t1)\n    li t0, 2\n" + PRINT.format(r="t0")),
    ("x_only", "an entry execute-only in the standard bit order (0x1c) over U-mode's code, before entry 0: "
     "fetch from it, then load from it",
     "    la t0, user\n    srli t0, t0, 2\n    ori t0, t0, 3\n    csrw pmpaddr0, t0\n"
     "    li t0, 0x20007fff\n    csrw pmpaddr1, t0\n    li t0, 0x1f1c\n    csrw pmpcfg0, t0\n"
     + TO_USER + "    auipc t0, 0\n    lw t1, 0(t0)\n    ecall\n"),
    ("u_peripheral", "U-mode loads from 0x40000000, which no dynamic entry covers",
     TO_USER + "    li t0, 0x40000000\n    lw t1, 0(t0)\n    ecall\n"),
    ("wfi_u_tw", "wfi in U-mode with mstatus.TW set",
     "    li t0, 0x200000\n    csrs mstatus, t0\n" + TO_USER + "    wfi\n    ecall\n"),
    ("wfi_u", "wfi in U-mode with mstatus.TW clear, as every monitor here leaves it",
     TO_USER + "    wfi\n    ecall\n"),
]


def image(body: str) -> bytes:
    code = harness.assemble_at(PROLOGUE + body + EPILOGUE, BASE + 0x40)
    return bytes(0x40) + code


def run(body: str, steps: int = 2000) -> SandboxEmulator:
    emu = SandboxEmulator(image(body))
    emu.run(steps)
    return emu


def readers(body: str, steps: int = 2000) -> dict:
    """What each reader prints for one probe: the emulator, the model (privrun), the RTL as the RP2350 configures it
    and the RTL as Hazard3's testbench does. A reader that never writes the exit word is marked `hangs`."""
    import privdiff

    def show(prints, code):
        return " ".join(f"{w:08x}" for w in prints) + ("" if code is not None else " hangs")

    snap = SandboxEmulator(image(body))
    emu = run(body, steps)
    taken = run_steps(body, steps)
    out = {"emulator": show(emu.prints, emu.exit_code if emu.halted else None),
           "model": show(*privdiff.model_run(snap, taken))}
    for tb in ("tb-rp2350", "tb"):
        path = os.path.join(REPO, "tools", "hazard3", "Hazard3", "test", "sim", "tb_verilator", tb)
        prints, code, _ = privdiff.rtl_run(snap, taken, path)
        out[tb] = show(prints, code)
    return out


def run_steps(body: str, steps: int = 2000) -> int:
    """How many steps the emulator takes to the park, `wfi` excluded."""
    emu = SandboxEmulator(image(body))
    n = 0
    while n < steps and not emu.halted:
        emu.step()
        n += 1
    return n


def table() -> str:
    """Every probe, every reader: what it printed, and whether that is what the RTL as the RP2350 configures it
    printed."""
    sys.path.insert(0, os.path.join(REPO, "tools", "monitor"))
    out = [f"{'probe':20} {'reader':10} words printed"]
    for name, what, body in PROBES:
        r = readers(body)
        for k, v in r.items():
            mark = "   <- not the RTL's" if k in ("emulator", "model") and v != r["tb-rp2350"] else ""
            out.append(f"{name if k == 'emulator' else '':20} {k:10} {v}{mark}".rstrip())
    return "\n".join(out) + "\n"


def main():
    if "--table" in sys.argv:
        print(table(), end="")
        return 0
    if "--check" in sys.argv:
        # what every reader printed, held to what they printed when README.md's table was recorded
        want = open(os.path.join(HERE, "table.txt"), encoding="utf-8").read()
        got = table()
        if got == want:
            n = sum("<- not the RTL's" in ln for ln in got.splitlines())
            print(f"PASS  {len(PROBES)} probes on four readers print what probes/table.txt recorded: "
                  f"{n} readings that are not the RTL's")
            return 0
        print("FAIL  the probes print something other than probes/table.txt:")
        for a, b in zip(want.splitlines(), got.splitlines()):
            if a != b:
                print(f"      was  {a}\n      now  {b}")
        return 1
    for name, what, body in PROBES:
        emu = run(body)
        words = " ".join(f"{w:08x}" for w in emu.prints)
        print(f"{name:20} {'exit ' + str(emu.exit_code) if emu.halted else 'no exit':8} {words}")


if __name__ == "__main__":
    sys.exit(main())
