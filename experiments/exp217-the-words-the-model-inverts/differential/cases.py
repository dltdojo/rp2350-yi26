#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp217 — the cases the differential runs, the same for all three runners.

  cases.py            one case per line on stdout, then nothing else

Each line: `<family> # <config> | <program words> | <state> | <tx> | <ext> | <steps>`
(Run.lean's format after the `#`). A fixed seed, so a case that disagrees is
there next time too. Programs are drawn per family from the RP2040's PIO
instructions — the RP2350's additions are in neither emulator — with no delay
and no EXEC destination: both emulators count cycles where the model counts
instructions, and run an EXEC'd instruction in the same step.

  core    jmp (all but PIN), in and out with the registers, push and pull
          with every flag, mov between registers with every operation,
          set x and y
  pinw    the same, and set/out/mov to pins and pindirs
  pinr    the same, and in/mov from pins, wait gpio and pin, jmp pin;
          external inputs on GPIO0..29, directions all in
  irq     irq set, clear and wait, wait irq, mov from status
"""
import random

STEPS = 24


def jmp(c, a): return (0 << 13) | (c << 5) | a
def wait(p, s, i): return (1 << 13) | (p << 7) | (s << 5) | i
def in_(s, n): return (2 << 13) | (s << 5) | n
def out(d, n): return (3 << 13) | (d << 5) | n
def push(f, b): return 0x8000 | (f << 6) | (b << 5)
def pull(e, b): return 0x8080 | (e << 6) | (b << 5)
def mov(d, o, s): return (5 << 13) | (d << 5) | (o << 3) | s
def irq(c, w, i): return (6 << 13) | (c << 6) | (w << 5) | i
def set_(d, v): return (7 << 13) | (d << 5) | v


def core(r, n):
    return r.choice([
        lambda: jmp(r.choice([0, 1, 2, 3, 4, 5, 7]), r.randrange(n)),
        lambda: in_(r.choice([1, 2, 3, 6, 7]), r.randrange(32)),
        lambda: out(r.choice([1, 2, 3, 5, 6]), r.randrange(32)),
        lambda: push(r.randrange(2), r.randrange(2)),
        lambda: pull(r.randrange(2), r.randrange(2)),
        lambda: mov(r.choice([1, 2, 5, 6, 7]), r.randrange(3), r.choice([1, 2, 3, 6, 7])),
        lambda: set_(r.choice([1, 2]), r.randrange(32)),
    ])()


def pinw(r, n):
    if r.random() < 0.5:
        return core(r, n)
    return r.choice([
        lambda: set_(r.choice([0, 4]), r.randrange(32)),
        lambda: out(r.choice([0, 4]), r.randrange(32)),
        lambda: mov(0, r.randrange(3), r.choice([1, 2, 3, 6, 7])),
    ])()


def pinr(r, n):
    if r.random() < 0.5:
        return core(r, n)
    return r.choice([
        lambda: in_(0, r.randrange(32)),
        lambda: mov(r.choice([1, 2, 6, 7]), r.randrange(3), 0),
        lambda: wait(r.randrange(2), 0, r.randrange(30)),
        lambda: wait(r.randrange(2), 1, r.randrange(8)),
        lambda: jmp(6, r.randrange(n)),
    ])()


def irqs(r, n):
    if r.random() < 0.5:
        return core(r, n)
    # Flags 0 and 1 most of the time, so that a wait often finds a flag
    # something before it set.
    flag = lambda: r.choice([0, 1, r.randrange(8)])
    return r.choice([
        lambda: irq(r.randrange(2), 0, flag()),
        lambda: irq(0, 1, flag()),
        lambda: wait(r.randrange(2), 2, flag()),
        lambda: mov(r.choice([1, 2]), r.randrange(2), 5),
    ])()


def cases():
    r = random.Random(217)
    out_ = []
    for family, gen, count in (("core", core, 300), ("pinw", pinw, 150), ("pinr", pinr, 150), ("irq", irqs, 100)):
        for k in range(count):
            n = r.randrange(2, 9)
            prog = [gen(r, n) for _ in range(n)]
            wb = r.randrange(n)
            wt = r.randrange(wb, n)
            in_base = r.randrange(30) if (family == "pinr" and k % 2) else 0
            out_base, out_count = r.randrange(30), r.randrange(0, 33)
            set_base, set_count = r.randrange(30), r.randrange(0, 6)
            cfg = [wb, wt, in_base, out_base, out_count, set_base, set_count, r.randrange(30),
                   r.randrange(2), r.randrange(2), r.choice([32, r.randrange(1, 33)]),
                   r.choice([32, r.randrange(1, 33)]), r.randrange(5)]
            st = [r.randrange(n), r.getrandbits(32), r.choice([0, r.getrandbits(32)]), r.getrandbits(32),
                  r.randrange(33), r.getrandbits(32), r.randrange(33)]
            tx = [r.getrandbits(32) for _ in range(r.randrange(5))]
            ext = r.getrandbits(30) if family == "pinr" else 0
            out_.append(f"{family} # {' '.join(map(str, cfg))} | {' '.join(map(str, prog))} | "
                        f"{' '.join(map(str, st))} | {' '.join(map(str, tx))} | {ext} | {STEPS}")
    return out_


if __name__ == "__main__":
    print("\n".join(cases()))
