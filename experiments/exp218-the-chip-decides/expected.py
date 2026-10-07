#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp218 — every register write the shell should make, in order, and why,
from the cases in shell/cases.h and the datasheet's registers (rp-pac 7.0.0's
addresses, as tools/hazard3/shell/pio.h writes them out). Written from the
protocol, not from shell.c: check.sh holds the RTL build's writes to it.

  expected.py shell/cases.h > expected.txt
"""
import re
import sys

PIO0 = 0x50200000
CTRL, TXF0 = PIO0, PIO0 + 0x10
INSTR_MEM = PIO0 + 0x48
EXECCTRL, SHIFTCTRL, SM_INSTR, PINCTRL = PIO0 + 0xcc, PIO0 + 0xd0, PIO0 + 0xd8, PIO0 + 0xdc
RESET_SET, RESET_CLR, PIO0_BIT = 0x40022000, 0x40023000, 1 << 11


def read_cases(text):
    """Each case's words, jmp, three registers, and two TX batches, from the
    initialisers in order (case.h's field order)."""
    body = text[text.index("CASES[NCASES] = {"):]
    out = []
    for m in re.finditer(r"\{ (\d+), \{([^}]*)\}, (0x[0-9a-f]+), (0x[0-9a-f]+), (0x[0-9a-f]+), (0x[0-9a-f]+),\s*"
                         r"(\d+), \{([^}]*)\}, (\d+), \{([^}]*)\},", body):
        nums = lambda s: [int(t, 16) for t in s.split(",") if t.strip()]
        out.append(dict(words=nums(m[2]), jmp=int(m[3], 16), execctrl=int(m[4], 16),
                        shiftctrl=int(m[5], 16), pinctrl=int(m[6], 16), tx1=nums(m[8]), tx2=nums(m[10])))
    return out


def emit():
    text = open(sys.argv[1]).read()
    ext = int(re.search(r"#define EXT_PULLED_UP (0x[0-9a-f]+)u", text)[1], 16)
    reads = {name: int(re.search(rf"#define {name}\s+(0x[0-9a-f]+)u", text)[1], 16)
             for name in ("I_PUSH", "I_MOV_ISR_X", "I_MOV_ISR_Y", "I_MOV_ISR_OSR")}
    lines = []
    w = lambda a, v, why: lines.append(f"{a:08x} {v:08x}   {why}")
    for p in range(2, 10):
        up = ext >> p & 1
        # OD (bit 7), IE (6), DRIVE 4 mA (5:4 = 1), PUE (3) or PDE (2), SCHMITT (1); ISO (8) clear
        pad = 0x80 | 0x40 | 0x10 | (0x08 if up else 0x04) | 0x02
        w(0x40038000 + 4 + 4 * p, pad, f"GPIO{p} pad: output disabled, input enabled, pulled {'up' if up else 'down'}, not isolated")
        w(0x40028000 + 8 * p + 4, 6, f"GPIO{p}_CTRL: FUNCSEL 6, PIO0")
    for k, c in enumerate(read_cases(text), 1):
        w(RESET_SET, PIO0_BIT, f"case {k}: RESETS set alias, PIO0 into reset")
        w(RESET_CLR, PIO0_BIT, f"case {k}: RESETS clear alias, PIO0 out of it")
        for i in range(32):
            word = c["words"][i] if i < len(c["words"]) else 0
            w(INSTR_MEM + 4 * i, word, f"case {k}: INSTR_MEM{i}" + ("" if i < len(c["words"]) else ", jmp 0"))
        w(EXECCTRL, c["execctrl"], f"case {k}: SM0_EXECCTRL")
        w(SHIFTCTRL, c["shiftctrl"], f"case {k}: SM0_SHIFTCTRL")
        w(PINCTRL, c["pinctrl"], f"case {k}: SM0_PINCTRL")
        w(CTRL, 0x110, f"case {k}: CTRL, SM0_RESTART (bit 4) and CLKDIV_RESTART (bit 8)")
        w(SM_INSTR, c["jmp"], f"case {k}: SM0_INSTR, jmp to where it starts")
        for t in c["tx1"]:
            w(TXF0, t, f"case {k}: TXF0, first batch")
        w(CTRL, 1, f"case {k}: CTRL, SM0_ENABLE: run to the first stop")
        w(CTRL, 0, f"case {k}: CTRL, disabled: stopped")
        for t in c["tx2"]:
            w(TXF0, t, f"case {k}: TXF0, second batch")
        w(CTRL, 1, f"case {k}: CTRL, SM0_ENABLE: run to the second stop")
        w(CTRL, 0, f"case {k}: CTRL, disabled: stopped, to be read")
        w(SM_INSTR, reads["I_PUSH"], f"case {k}: SM0_INSTR, push noblock: ISR out")
        for r, name in (("I_MOV_ISR_X", "X"), ("I_MOV_ISR_Y", "Y"), ("I_MOV_ISR_OSR", "OSR")):
            w(SM_INSTR, reads[r], f"case {k}: SM0_INSTR, mov isr, {name.lower()}")
            w(SM_INSTR, reads["I_PUSH"], f"case {k}: SM0_INSTR, push noblock: {name} out")
    w(CTRL, 0, "CTRL: every state machine stopped, before the verdict")
    print("# exp218 — every register write the shell makes, in order, and why:")
    print("# expected.py's reading of shell/cases.h. check.sh holds the RTL")
    print("# build's printed writes to these lines, address and value.")
    print("#")
    print("# <address> <value>   <why>")
    print("\n".join(lines))


if __name__ == "__main__":
    emit()
