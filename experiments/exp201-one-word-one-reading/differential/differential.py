#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp201 — hold lean/Rv32/Isa.lean's encodings against LLVM's.

Reads Gen.lean's output on stdin:

  E|<asm>|<word>   llvm-mc assembles <asm>; its word must be <word>
  D|<word>|<asm>   llvm-objdump disassembles <word>; it must print <asm>, and
                   where Lean said NONE it must print nothing this model
                   accepts — `<unknown>`, or an instruction outside RV32IM's
                   computational subset (fence, csr*, ebreak, mret, ...)

Lean's two theorems say the encoder and the decoder agree with each other. They
cannot say either agrees with the specification, because the specification is
prose; this is the only check here that can, and it uses an assembler written
by somebody else to do it.

Prints PASS/FAIL lines in the repository's format; exit 0 when all pass.
"""
import os
import re
import subprocess
import sys
import tempfile

TRIPLE = ["-triple=riscv32", "-mattr=+m"]

# What LLVM may call a word this model refuses: real instructions, outside the
# subset on purpose. Anything else LLVM decodes, Lean must decode too.
OUTSIDE = re.compile(r"^(fence(\.i|\.tso)?|pause|ebreak|c\.\S+|csrr[swc]i?|mret|sret|uret|dret|wfi|"
                     r"sfence\.\S+|hfence\.\S+|hinval\.\S+|sinval\.\S+|cbo\.\S+|prefetch\.\S+|"
                     r"unimp)$")


def num(tok):
    return int(tok, 0)


def norm_asm(text):
    """`addi x1, x2, -0x5` and `addi x1, x2, -5` are the same instruction."""
    mn, _, ops = text.strip().partition(" ")
    out = []
    for op in [o.strip() for o in ops.split(",") if o.strip()]:
        m = re.fullmatch(r"(-?(?:0x[0-9a-fA-F]+|\d+))\((x\d+)\)", op)
        if m:
            out.append(f"{num(m.group(1))}({m.group(2)})")
        elif re.fullmatch(r"x\d+", op):
            out.append(op)
        else:
            out.append(str(num(op)))
    return mn + " " + ", ".join(out) if out else mn


def assemble(lines):
    src = ".text\n" + "\n".join(lines) + "\n"
    r = subprocess.run(["llvm-mc", *TRIPLE, "-show-encoding"], input=src,
                       capture_output=True, text=True)
    words = []
    for line in r.stdout.splitlines():
        m = re.search(r"# encoding: \[([^\]]*)\]", line)
        if m:
            bs = [int(b, 16) for b in m.group(1).split(",")]
            words.append(int.from_bytes(bytes(bs), "little"))
    return words, r.stderr


def disassemble(words):
    with tempfile.TemporaryDirectory() as d:
        s, o = os.path.join(d, "w.s"), os.path.join(d, "w.o")
        with open(s, "w") as f:
            f.write(".text\n" + "".join(f".word 0x{w:08x}\n" for w in words))
        subprocess.run(["llvm-mc", *TRIPLE, "-filetype=obj", s, "-o", o], check=True)
        r = subprocess.run(["llvm-objdump", "-d", "-M", "no-aliases", "-M", "numeric",
                            "--mattr=+m", o], capture_output=True, text=True, check=True)
    out = {}
    for line in r.stdout.splitlines():
        m = re.match(r"\s*([0-9a-f]+):\s+(?:[0-9a-f]{2} ){4}\s*(.*)$", line)
        if not m:
            continue
        addr = int(m.group(1), 16)
        text = re.sub(r"\s+", " ", m.group(2)).strip()
        # Branches and jumps print an absolute target and a symbol: make it the
        # offset the instruction holds.
        t = re.match(r"^(\S+) (.*?)(0x[0-9a-f]+) <[^>]*>$", text)
        if t and t.group(1) in ("beq", "bne", "blt", "bge", "bltu", "bgeu", "jal"):
            off = (int(t.group(3), 16) - addr + 2**31) % 2**32 - 2**31
            text = f"{t.group(1)} {t.group(2)}{off}"
        # `jalr` gets a symbol too, which says nothing about the word.
        text = re.sub(r" <[^>]*>$", "", text)
        out[addr // 4] = text
    return [out.get(i, "<missing>") for i in range(len(words))]


def main():
    enc, dec = [], []
    for line in sys.stdin:
        kind, a, b = line.rstrip("\n").split("|")
        if kind == "E":
            enc.append((a, int(b, 16)))
        elif kind == "D":
            dec.append((int(a, 16), b))
    failed = 0

    words, err = assemble([a for a, _ in enc])
    bad = [(a, w, l) for (a, w), l in zip(enc, words) if w != l]
    if len(words) != len(enc):
        print(f"FAIL  llvm-mc assembles every instruction Lean prints — {len(words)} of {len(enc)}: "
              f"{err.strip().splitlines()[:2]}")
        failed = 1
    elif bad:
        a, w, l = bad[0]
        print(f"FAIL  every encoding is LLVM's — {len(bad)} of {len(enc)} differ; first: "
              f"`{a}` Lean {w:08x}, LLVM {l:08x}")
        failed = 1
    else:
        forms = len({a.split()[0] for a, _ in enc})
        print(f"PASS  every encoding is LLVM's: {len(enc)} instructions, all {forms} forms")

    # A word whose low two bits are not 11 is in the 16-bit (C) space, and one
    # whose low five are 11111 starts a 48-bit-or-longer encoding: neither is a
    # 32-bit instruction at all, so the length decides, not LLVM. Lean must
    # refuse every one, and they stay out of the disassembly, where one 2-byte
    # <unknown> would knock every following word out of step.
    other_len = [(w, lean) for w, lean in dec if w & 3 != 3 or w & 0x1f == 0x1f]
    dec = [(w, lean) for w, lean in dec if not (w & 3 != 3 or w & 0x1f == 0x1f)]
    wrong_len = [w for w, lean in other_len if lean != "NONE"]
    if wrong_len:
        print(f"FAIL  no word of another length is read as a 32-bit instruction — "
              f"{len(wrong_len)}; first {wrong_len[0]:08x}")
        failed = 1
    else:
        print(f"PASS  no word of another length is read as a 32-bit instruction: "
              f"{len(other_len)} refused")

    texts = disassemble([w for w, _ in dec])
    accepted = refused = outside = 0
    problems = []
    for (w, lean), llvm in zip(dec, texts):
        mn = llvm.split(" ")[0]
        if lean == "NONE":
            if llvm == "<unknown>":
                refused += 1
            elif OUTSIDE.match(mn):
                outside += 1
            else:
                problems.append(f"{w:08x}: Lean refuses it, LLVM reads `{llvm}`")
        else:
            accepted += 1
            if llvm == "<unknown>" or norm_asm(llvm) != norm_asm(lean):
                problems.append(f"{w:08x}: Lean reads `{lean}`, LLVM `{llvm}`")
    if problems:
        print(f"FAIL  every word is read as LLVM reads it — {len(problems)} of {len(dec)} differ; "
              f"first: {problems[0]}")
        failed = 1
    else:
        print(f"PASS  every word is read as LLVM reads it: {len(dec)} words — "
              f"{accepted} the same instruction, {refused} refused by both, "
              f"{outside} real instructions this model refuses on purpose")
    return failed


if __name__ == "__main__":
    sys.exit(main())
