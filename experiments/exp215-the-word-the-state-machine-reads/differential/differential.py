#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp215 — hold lean/Pio/Isa.lean's encodings against pioasm's, over every word.

Reads Gen.lean's output on stdin: all 65536 words, each with the text Lean
reads it as, or NONE.

Two directions, both against pioasm 2.3.1 (`tools/pioasm`), `.pio_version 1`:

  Lean's readings   every text Lean prints for a word it decodes is assembled;
                    the word pioasm makes must be that word
  pioasm's words    every instruction in the grammar below — written here
                    from pioasm's syntax, not from Lean — is assembled, at
                    every delay; each word pioasm makes must be one Lean
                    decodes, and together they must be exactly the words
                    Lean decodes, no more and no fewer

Lean's two theorems say its encoder and decoder agree with each other. They
cannot say either agrees with the datasheet, which is prose; this is the
check that can, with an assembler written by somebody else.

  differential.py [PIOASM]     PASS/FAIL lines; exit 0 = all pass
"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PIOASM = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    HERE, "..", "..", "..", "tools", "pioasm", "pioasm-2.3.1", "pioasm")
WORD = re.compile(r"^\s*0x([0-9a-f]{4}), //\s*\d+: ")


def assemble(texts):
    """Words for texts, a list of (text, putget), in order: programs of 32,
    each padded with nop so that every jmp target 0..31 is inside it."""
    progs, order = [], []
    for putget in (False, True):
        batch = [t for t, p in texts if p == putget]
        for k in range(0, len(batch), 32):
            chunk = batch[k:k + 32]
            progs.append((putget, chunk + ["nop"] * (32 - len(chunk))))
            order.append(len(chunk))
    src = [".pio_version 1"]
    for n, (putget, lines) in enumerate(progs):
        src.append(f".program p{n}")
        if putget:
            src.append(".fifo putget")
        src += lines
    with tempfile.TemporaryDirectory() as work:
        path = os.path.join(work, "all.pio")
        open(path, "w").write("\n".join(src) + "\n")
        out = subprocess.run([PIOASM, "-o", "c-sdk", path], capture_output=True, text=True)
    if out.returncode != 0:
        return None, out.stderr.strip().splitlines()[:6]
    words = [int(m.group(1), 16) for line in out.stdout.splitlines() if (m := WORD.match(line))]
    # Words come out program by program, 32 each; keep the first `n` of each.
    flat, i = [], 0
    for n in order:
        flat += words[i:i + n]
        i += 32
    ordered = [t for t, p in texts if not p] + [t for t, p in texts if p]
    if len(flat) != len(ordered):
        return None, [f"pioasm gave {len(flat)} words for {len(ordered)} texts"]
    return dict(zip(ordered, flat)), []


def grammar():
    """Every PIO instruction pioasm 2.3.1 accepts at .pio_version 1, without
    side-set, at delay 0; written from pioasm's syntax."""
    out = []
    conds = ["", "!x, ", "x--, ", "!y, ", "y--, ", "x!=y, ", "pin, ", "!osre, "]
    out += [(f"jmp {c}{a}", False) for c in conds for a in range(32)]
    for p in (0, 1):
        out += [(f"wait {p} gpio {n}", False) for n in range(32)]
        out += [(f"wait {p} pin {n}", False) for n in range(32)]
        for n in range(8):
            out += [(f"wait {p} irq {n}", False), (f"wait {p} irq prev {n}", False),
                    (f"wait {p} irq {n} rel", False), (f"wait {p} irq next {n}", False)]
        out += [(f"wait {p} jmppin + {n}", False) for n in range(4)]
    out += [(f"in {s}, {n}", False) for s in ["pins", "x", "y", "null", "isr", "osr"] for n in range(1, 33)]
    out += [(f"out {d}, {n}", False) for d in ["pins", "x", "y", "null", "pindirs", "pc", "isr", "exec"]
            for n in range(1, 33)]
    for f in ("", "iffull "):
        out += [(f"push {f}block", False), (f"push {f}noblock", False)]
    for e in ("", "ifempty "):
        out += [(f"pull {e}block", False), (f"pull {e}noblock", False)]
    for k in ["y"] + [str(n) for n in range(8)]:
        out += [(f"mov rxfifo[{k}], isr", True), (f"mov osr, rxfifo[{k}]", True)]
    out += [(f"mov {d}, {o}{s}", False)
            for d in ["pins", "x", "y", "pindirs", "exec", "pc", "isr", "osr"]
            for o in ["", "~", "::"]
            for s in ["pins", "x", "y", "null", "status", "isr", "osr"]]
    for o in ("set", "wait", "clear"):
        for n in range(8):
            out += [(f"irq {o} {n}", False), (f"irq prev {o} {n}", False),
                    (f"irq {o} {n} rel", False), (f"irq next {o} {n}", False)]
    out += [(f"set {d}, {v}", False) for d in ["pins", "x", "y", "pindirs"] for v in range(32)]
    return out


def main():
    lean = {}
    for line in sys.stdin:
        w, text, putget = line.rstrip("\n").split("|")
        lean[int(w, 16)] = (None if text == "NONE" else text, putget == "1")
    bad = 0

    if len(lean) != 65536:
        print(f"FAIL  Gen.lean printed every word — it printed {len(lean)}")
        return 1
    decoded = {w: tp for w, tp in lean.items() if tp[0] is not None}
    got, err = assemble([tp for tp in decoded.values()])
    if got is None:
        print(f"FAIL  pioasm assembles every text Lean prints — {' / '.join(err)}")
        bad = 1
    else:
        wrong = [(w, t, got[t]) for w, (t, _) in decoded.items() if got[t] != w]
        if wrong:
            bad = 1
            print(f"FAIL  pioasm reads each of the {len(decoded)} words Lean decodes as Lean does — "
                  f"{len(wrong)} differ, e.g. " +
                  "; ".join(f"{w:04x} '{t}' is {g:04x} to pioasm" for w, t, g in wrong[:4]))
        else:
            print(f"PASS  pioasm reads each of the {len(decoded)} words Lean decodes as Lean does: "
                  f"its text assembles back to the word")

    base = grammar()
    texts = [(t if d == 0 else f"{t} [{d}]", p) for t, p in base for d in range(32)]
    got, err = assemble(texts)
    if got is None:
        print(f"FAIL  pioasm assembles the grammar — {' / '.join(err)}")
        return 1
    words = set(got.values())
    refused = sorted(w for w in words if lean[w][0] is None)
    if refused:
        bad = 1
        print(f"FAIL  Lean decodes every word pioasm makes — it refuses {len(refused)}, e.g. " +
              ", ".join(f"{w:04x}" for w in refused[:6]))
    else:
        print(f"PASS  Lean decodes every word pioasm makes from {len(base)} instructions at 32 delays each "
              f"({len(texts)} texts, {len(words)} distinct words)")
    if words == set(decoded):
        print(f"PASS  and those are exactly the {len(decoded)} words Lean decodes; the other "
              f"{65536 - len(decoded)} it refuses, and pioasm made none of them")
    else:
        bad = 1
        extra = sorted(set(decoded) - words)
        print(f"FAIL  the words pioasm makes are exactly the ones Lean decodes — Lean decodes "
              f"{len(extra)} pioasm did not make, e.g. " + ", ".join(f"{w:04x} '{lean[w][0]}'" for w in extra[:4]))
    return bad


if __name__ == "__main__":
    sys.exit(main())
