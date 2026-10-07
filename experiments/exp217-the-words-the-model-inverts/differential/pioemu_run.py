#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp217 — the same cases on rp2040-pio-emulator (tools/pio-emulators), one
state per clock. Reads Run.lean's case format on stdin, prints Run.lean's
trace format; `NONE` where the emulator has no emulation for an instruction
(it raises, or its generator just ends). IRQ flags are not in it, so that
field is printed 0 and not compared.

The program is padded to 32 words with 0, `jmp 0`, as instruction memory is
in the other two runners; otherwise a pc past the program's end is an index
error here and a `jmp 0` there.

  pioemu_run.py < cases
"""
import sys
from collections import deque

from pioemu import State, emulate
from pioemu.shift_register import ShiftRegister


def nums(s):
    return [int(t) for t in s.split()]


def run_case(line):
    c, prog, st, tx, ext, steps = (nums(p) for p in line.split("|"))
    prog = prog + [0] * (32 - len(prog))
    wb, wt, in_base, out_base, out_count, set_base, set_count, jmp_pin, in_right, out_right, push_t, pull_t, _ = c
    state = State(program_counter=st[0], x_register=st[1], y_register=st[2],
                  input_shift_register=ShiftRegister(st[3], st[4]),
                  output_shift_register=ShiftRegister(st[5], st[6]),
                  transmit_fifo=deque(tx), receive_fifo=deque(), pin_values=ext[0])
    lines = []
    try:
        gen = emulate(prog, stop_when=lambda _op, s: s.clock >= steps[0], initial_state=state,
                      shift_isr_right=bool(in_right), shift_osr_right=bool(out_right),
                      push_threshold=push_t, pull_threshold=pull_t, out_base=out_base, out_count=out_count,
                      set_base=set_base, set_count=set_count, jmp_pin=jmp_pin, wrap_target=wb, wrap_top=wt)
        for _before, s in gen:
            isr, osr = s.input_shift_register, s.output_shift_register
            lines.append(f"{s.program_counter} {s.x_register} {s.y_register} {isr.contents} {isr.counter} "
                         f"{osr.contents} {osr.counter} {s.pin_values} {s.pin_directions} 0 "
                         f"[{','.join(map(str, s.transmit_fifo))}] [{','.join(map(str, s.receive_fifo))}]")
        if len(lines) < steps[0]:
            lines.append("NONE")
    except Exception:
        lines.append("NONE")
    return lines


def main():
    for n, line in enumerate(l for l in sys.stdin.read().splitlines() if l.strip()):
        print(f"case {n}")
        for out in run_case(line):
            print(out)


if __name__ == "__main__":
    main()
