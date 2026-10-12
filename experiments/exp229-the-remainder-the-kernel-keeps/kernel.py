#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp229 — the field kernel, written with labels, emitted as Lean.

Addition, subtraction and multiplication modulo secp256k1's
p = 2^256 - 2^32 - 977, on numbers of eight 32-bit words, least significant
first. The kernel is proof/Field.lean's `kernel`; this writes it between the
`BEGIN generated` and `END generated` markers there, with each label's
instruction number beside it, through tools/lean/kasm.py.

  kernel.py           rewrite the generated block in proof/Field.lean
  kernel.py --check   exit 1 if the block is not what this would write

Each loop's body has one shape, so that one lemma runs each part: its loads
from a0 and a1, then register instructions only, then its store through a2,
then the three pointers on a word and the counter t1 down one, then the branch
back. Every loop is written out where it is used — there is no call and no
return — because lean/Rv32/Ct.lean's checker takes no jal and no jalr, and so
that each loop's pointers are a fixed offset plus a multiple of its own
counter, which is what the checker can follow. For the same reason the
schoolbook product's outer loop is written out eight times: a row's store
pointer moves with both counters.

No branch here depends on a number. Every loop runs a fixed count, and the
one choice the arithmetic needs — subtract p or not — is made with a mask:
out = d ^ ((d ^ x) & mask). The only branches on data are on the operation
itself, which is public.

The layout of the 64 KiB region, from base (s1 holds base + 0x800, PRIME):

  0x0000  the kernel
  0x0800  PRIME  p, eight words, part of the image
  0x0900  OPW    the operation: 0 add, 1 sub, 2 mul
  0x0904  A      a, eight words, a < p
  0x0924  B      b, eight words, b < p
  0x0944  R      the result, eight words, then one word of the kernel's own
  0x0a00  T      a · b, sixteen words
  0x0a40  U      the first fold, ten words
  0x0a80  V      the high words of the next fold, eight words
  0x0ac0  W      the second fold, ten words
  0x0b00  X      the third fold, ten words
  0x0b40  D      x - p, eight words
  0x0b80  S      a + b, nine words

The pieces, each written where it is used (a label marks its first
instruction):

  ADDM  Z = X + (Y & a3), eight words, the carry in Z[8]
  SUBN  Z = X - Y, eight words, the borrow in t0
  SEL   Z = a3 ? X : Y, eight words, a word at a time
  ZERO  Z = 0, eight words
  ROW   T[i .. i+9) = T[i .. i+8) + A[i] · B
  FOLD  Y = L + H · (2^32 + 977), L and H eight words each, Y ten
  HSET  V = [src[8], src[9], 0, 0, 0, 0, 0, 0]
  CSUB  R = src or src - p, by mask: SUBN, the mask, SEL
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROOF = os.path.join(HERE, "proof", "Field.lean")
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools", "lean"))
from kasm import Kernel, splice  # noqa: E402

PRIME, OPW, A, B, R = 0x800, 0x900, 0x904, 0x924, 0x944
T, U, V, W, X, D, S = 0xA00, 0xA40, 0xA80, 0xAC0, 0xB00, 0xB40, 0xB80
P = 2**256 - 2**32 - 977

K = Kernel()
ins = K.ins


def at(rd, off):
    """rd = base + off, from s1 = base + PRIME."""
    ins("opi", "addi", rd, "s1", off - PRIME)


def mov(rd, rs):
    ins("opi", "addi", rd, rs, 0)


def setk(rd, v):
    ins("opi", "addi", rd, "zero", v)


LOOPS = []   # (label, x, y, z): each loop and where its three pointers start


def rounds(name, line, rv, x, y, z):
    K.label(name)
    LOOPS.append((name, x, y, z))
    ins("ld", "lw", "t2", "a0", 0)
    ins("ld", "lw", "t3", "a1", 0)
    for i in line:
        ins(*i)
    ins("st", "sw", "a2", rv, 0)
    for r in ("a0", "a1", "a2"):
        ins("opi", "addi", r, r, 4)
    ins("opi", "addi", "t1", "t1", -1)
    ins("br", "bne", "t1", "zero", name)


ADDM_LINE = [("op", "and", "t3", "t3", "a3"), ("op", "add", "t4", "t2", "t3"), ("op", "sltu", "t5", "t4", "t3"),
             ("op", "add", "t4", "t4", "t0"), ("op", "sltu", "t6", "t4", "t0"), ("op", "add", "t0", "t5", "t6")]
SUBN_LINE = [("op", "sub", "t4", "t2", "t3"), ("op", "sltu", "t5", "t2", "t3"), ("op", "sltu", "t6", "t4", "t0"),
             ("op", "sub", "t4", "t4", "t0"), ("op", "add", "t0", "t5", "t6")]
SEL_LINE = [("op", "xor", "t4", "t2", "t3"), ("op", "and", "t4", "t4", "a3"), ("op", "xor", "t4", "t4", "t3")]
ZERO_LINE = [("op", "sub", "t4", "t2", "t2")]
ROW_LINE = [("op", "mul", "t5", "a4", "t2"), ("op", "mulhu", "t6", "a4", "t2"),
            ("op", "add", "t4", "t3", "t5"), ("op", "sltu", "a5", "t4", "t5"),
            ("op", "add", "t4", "t4", "t0"), ("op", "sltu", "a6", "t4", "t0"),
            ("op", "add", "t0", "t6", "a5"), ("op", "add", "t0", "t0", "a6")]
FOLD_LINE = [("op", "mul", "t4", "t3", "a4"), ("op", "mulhu", "t5", "t3", "a4"),
             ("op", "add", "t6", "t2", "t4"), ("op", "sltu", "a5", "t6", "t4"),
             ("op", "add", "t6", "t6", "a3"), ("op", "sltu", "a6", "t6", "a3"),
             ("op", "add", "t6", "t6", "t0"), ("op", "sltu", "a7", "t6", "t0"),
             ("op", "add", "t0", "t5", "a5"), ("op", "add", "t0", "t0", "a6"),
             ("op", "add", "t0", "t0", "a7"), ("opi", "addi", "a3", "t3", 0)]


def addm(name, x, y, z):
    """Z = X + (Y & a3), the carry in Z[8]; a3 is set before."""
    K.label(name)
    at("a0", x)
    at("a1", y)
    at("a2", z)
    setk("t0", 0)
    setk("t1", 8)
    rounds(name + "_L", ADDM_LINE, "t4", x, y, z)
    ins("st", "sw", "a2", "t0", 0)


def subn(name, x, y, z):
    """Z = X - Y, the borrow in t0."""
    K.label(name)
    at("a0", x)
    at("a1", y)
    at("a2", z)
    setk("t0", 0)
    setk("t1", 8)
    rounds(name + "_L", SUBN_LINE, "t4", x, y, z)


def sel(name, x, y, z):
    """Z = a3 ? X : Y, a word at a time: y ^ ((x ^ y) & a3)."""
    K.label(name)
    at("a0", x)
    at("a1", y)
    at("a2", z)
    setk("t1", 8)
    rounds(name + "_L", SEL_LINE, "t4", x, y, z)


def zero8(name, z):
    """Z = 0, eight words: each word less itself."""
    K.label(name)
    at("a0", z)
    at("a1", z)
    at("a2", z)
    setk("t1", 8)
    rounds(name + "_L", ZERO_LINE, "t4", z, z, z)


def row(name, i):
    """T[i .. i+9) = T[i .. i+8) + A[i] · B: the carry chain of one row."""
    K.label(name)
    ins("ld", "lw", "a4", "s1", A + 4 * i - PRIME)
    at("a0", B)
    at("a1", T + 4 * i)
    at("a2", T + 4 * i)
    setk("t0", 0)
    setk("t1", 8)
    rounds(name + "_L", ROW_LINE, "t4", B, T + 4 * i, T + 4 * i)
    ins("st", "sw", "a2", "t0", 0)


def fold(name, lo, hi, out):
    """OUT = L + H·977 + H·2^32, ten words."""
    K.label(name)
    at("a0", lo)
    at("a1", hi)
    at("a2", out)
    setk("t0", 0)                         # carry
    setk("a3", 0)                         # H[i - 1]
    setk("a4", 977)
    setk("t1", 8)
    rounds(name + "_L", FOLD_LINE, "t6", lo, hi, out)
    ins("op", "add", "t6", "a3", "t0")    # OUT[8] = H[7] + carry
    ins("op", "sltu", "t5", "t6", "a3")   # OUT[9]
    ins("st", "sw", "a2", "t6", 0)
    ins("st", "sw", "a2", "t5", 4)


def hset(name, src):
    """V = [src[8], src[9], 0, 0, 0, 0, 0, 0]."""
    K.label(name)
    ins("ld", "lw", "t0", "s1", src + 32 - PRIME)
    ins("ld", "lw", "t1", "s1", src + 36 - PRIME)
    ins("st", "sw", "s1", "t0", V - PRIME)
    ins("st", "sw", "s1", "t1", V + 4 - PRIME)
    for k in range(2, 8):
        ins("st", "sw", "s1", "zero", V + 4 * k - PRIME)


def csub(name, src):
    """R = src mod p, src nine words below 2p: subtract p, and keep src if it borrowed."""
    subn(name, src, PRIME, D)             # t0: did src[0..8) - p borrow
    ins("ld", "lw", "t1", "s1", src + 32 - PRIME)
    ins("op", "sltu", "t2", "t1", "t0")   # src < p  ⇔  src[8] < borrow
    ins("op", "sub", "a3", "zero", "t2")  # all ones: keep src
    sel(name + "_SEL", src, D, R)


def halt(name):
    K.label(name)
    setk("a0", 0)
    setk("t0", 1)
    ins("ecall")


def field_kernel():
    K.label("ENTRY")
    ins("auipc", "s1", 0)
    ins("opi", "addi", "s1", "s1", 1024)
    ins("opi", "addi", "s1", "s1", 1024)
    ins("ld", "lw", "t0", "s1", OPW - PRIME)
    ins("br", "beq", "t0", "zero", "OP_ADD")
    setk("t1", 1)
    ins("br", "beq", "t0", "t1", "OP_SUB")

    K.label("OP_MUL")
    zero8("M_ZERO", T)
    for i in range(8):
        row(f"M_ROW{i}", i)
    fold("M_FOLD1", T, T + 32, U)
    hset("M_HSET1", U)
    fold("M_FOLD2", U, V, W)
    hset("M_HSET2", W)
    fold("M_FOLD3", W, V, X)
    csub("M_CSUB", X)
    halt("M_HALT")

    K.label("OP_ADD")
    setk("a3", -1)
    addm("A_ADDM", A, B, S)
    csub("A_CSUB", S)
    halt("A_HALT")

    K.label("OP_SUB")
    subn("S_SUBN", A, B, D)
    ins("op", "sub", "a3", "zero", "t0")  # borrowed: add p back
    addm("S_ADDM", D, PRIME, R)
    halt("S_HALT")


def field_block():
    labels, code = K.assemble()
    assert 4 * len(code) <= PRIME, len(code)
    lines = ["-- BEGIN generated by kernel.py — do not edit", ""]
    lines.append("/-- Where each label is: an instruction number. -/")
    for name, k in labels.items():
        lines.append(f"def {name} : Nat := {k}")
    lines.append("")
    lines.append(f"/-- The kernel, {len(code)} instructions. -/")
    lines.append("def kernel : List Instr := [")
    for k, text in enumerate(code):
        lines.append(f"  {text}{',' if k + 1 < len(code) else ' ]'}")
    lines.append("")
    lines.append("/-- Each loop, and where a0, a1 and a2 start in it: offsets from base. -/")
    lines.append("def loops : List (Nat × Nat × Nat × Nat) := [")
    for k, (name, x, y, z) in enumerate(LOOPS):
        lines.append(f"  ({name}, {x:#x}, {y:#x}, {z:#x}){',' if k + 1 < len(LOOPS) else ' ]'}")
    lines.append("")
    lines.append("-- END generated by kernel.py")
    return "\n".join(lines)


field_kernel()

if __name__ == "__main__":
    text = open(PROOF).read()
    new = splice(text, field_block(), "kernel.py")
    if sys.argv[1:] == ["--check"]:
        sys.exit(0 if new == text else 1)
    open(PROOF, "w").write(new)
    labels, code = K.assemble()
    print(f"proof/Field.lean: {len(code)} instructions, {len(labels)} labels")
