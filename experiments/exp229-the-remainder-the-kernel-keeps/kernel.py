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

Subroutines take pointers in a0, a1, a2 (and a mask in a3) and return through
ra; they move the pointers they are given:

  ADDM  Z = X + (Y & mask), eight words, the carry in Z[8]
  SUBN  Z = X - Y, eight words, the borrow in t0
  SEL   Z = mask ? X : D, eight words, a word at a time
  MUL   T = A · B, sixteen words
  FOLD  Y = L + H · (2^32 + 977), L and H eight words each, Y ten
  HSET  V = [t0, t1, 0, 0, 0, 0, 0, 0]
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


def call(name):
    ins("jal", "ra", name)


def ret():
    ins("jalr", "zero", "ra", 0)


def step(*regs):
    """Each pointer on a word, the counter t1 down one, and round again."""
    for r in regs:
        ins("opi", "addi", r, r, 4)
    ins("opi", "addi", "t1", "t1", -1)


def csub(src):
    """R = src mod p, src nine words below 2p: subtract p, and keep src if it borrowed."""
    at("a0", src)
    at("a1", PRIME)
    at("a2", D)
    call("SUBN")                          # t0: did src[0..8) - p borrow
    ins("ld", "lw", "t1", "s1", src + 32 - PRIME)
    ins("op", "sltu", "t2", "t1", "t0")   # src < p  ⇔  src[8] < borrow
    ins("op", "sub", "a3", "zero", "t2")  # all ones: keep src
    at("a0", src)
    at("a1", D)
    at("a2", R)
    call("SEL")


def fold(lo, hi, out):
    at("a0", lo)
    at("a1", hi)
    at("a2", out)
    call("FOLD")


def hset_from(src):
    """V = [src[8], src[9], 0, 0, 0, 0, 0, 0]."""
    ins("ld", "lw", "t0", "s1", src + 32 - PRIME)
    ins("ld", "lw", "t1", "s1", src + 36 - PRIME)
    at("a0", V)
    call("HSET")


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
    at("a0", A)
    at("a1", B)
    at("a2", T)
    call("MUL")
    fold(T, T + 32, U)
    hset_from(U)
    fold(U, V, W)
    hset_from(W)
    fold(W, V, X)
    csub(X)
    ins("jal", "zero", "HALT")

    K.label("OP_ADD")
    at("a0", A)
    at("a1", B)
    at("a2", S)
    setk("a3", -1)
    call("ADDM")
    csub(S)
    ins("jal", "zero", "HALT")

    K.label("OP_SUB")
    at("a0", A)
    at("a1", B)
    at("a2", D)
    call("SUBN")
    ins("op", "sub", "a3", "zero", "t0")  # borrowed: add p back
    at("a0", D)
    at("a1", PRIME)
    at("a2", R)
    call("ADDM")

    K.label("HALT")
    setk("a0", 0)
    setk("t0", 1)
    ins("ecall")

    # ---- ADDM: Z = X + (Y & a3), carry in Z[8] ----------------------------------
    K.label("ADDM")
    setk("t0", 0)
    setk("t1", 8)
    K.label("ADDM_L")
    ins("ld", "lw", "t2", "a0", 0)
    ins("ld", "lw", "t3", "a1", 0)
    ins("op", "and", "t3", "t3", "a3")
    ins("op", "add", "t4", "t2", "t3")
    ins("op", "sltu", "t5", "t4", "t3")
    ins("op", "add", "t4", "t4", "t0")
    ins("op", "sltu", "t6", "t4", "t0")
    ins("op", "add", "t0", "t5", "t6")
    ins("st", "sw", "a2", "t4", 0)
    step("a0", "a1", "a2")
    ins("br", "bne", "t1", "zero", "ADDM_L")
    ins("st", "sw", "a2", "t0", 0)
    ret()

    # ---- SUBN: Z = X - Y, borrow in t0 --------------------------------------------
    K.label("SUBN")
    setk("t0", 0)
    setk("t1", 8)
    K.label("SUBN_L")
    ins("ld", "lw", "t2", "a0", 0)
    ins("ld", "lw", "t3", "a1", 0)
    ins("op", "sub", "t4", "t2", "t3")
    ins("op", "sltu", "t5", "t2", "t3")
    ins("op", "sltu", "t6", "t4", "t0")
    ins("op", "sub", "t4", "t4", "t0")
    ins("op", "add", "t0", "t5", "t6")
    ins("st", "sw", "a2", "t4", 0)
    step("a0", "a1", "a2")
    ins("br", "bne", "t1", "zero", "SUBN_L")
    ret()

    # ---- SEL: Z = D ^ ((D ^ X) & a3) ---------------------------------------------
    K.label("SEL")
    setk("t1", 8)
    K.label("SEL_L")
    ins("ld", "lw", "t2", "a0", 0)
    ins("ld", "lw", "t3", "a1", 0)
    ins("op", "xor", "t4", "t2", "t3")
    ins("op", "and", "t4", "t4", "a3")
    ins("op", "xor", "t4", "t4", "t3")
    ins("st", "sw", "a2", "t4", 0)
    step("a0", "a1", "a2")
    ins("br", "bne", "t1", "zero", "SEL_L")
    ret()

    # ---- MUL: T = A · B, sixteen words --------------------------------------------
    K.label("MUL")
    mov("a4", "a2")
    setk("t1", 16)
    K.label("MUL_Z")
    ins("st", "sw", "a4", "zero", 0)
    ins("opi", "addi", "a4", "a4", 4)
    ins("opi", "addi", "t1", "t1", -1)
    ins("br", "bne", "t1", "zero", "MUL_Z")
    setk("t1", 8)
    K.label("MUL_O")
    ins("ld", "lw", "t2", "a0", 0)        # a_i
    setk("t0", 0)                         # carry
    mov("a5", "a1")                       # b_j
    mov("a4", "a2")                       # T[i + j]
    setk("t3", 8)
    K.label("MUL_I")
    ins("ld", "lw", "t4", "a5", 0)
    ins("op", "mul", "t5", "t2", "t4")
    ins("op", "mulhu", "t6", "t2", "t4")
    ins("ld", "lw", "a6", "a4", 0)
    ins("op", "add", "a6", "a6", "t5")
    ins("op", "sltu", "a7", "a6", "t5")
    ins("op", "add", "a6", "a6", "t0")
    ins("op", "sltu", "a3", "a6", "t0")
    ins("op", "add", "t0", "t6", "a7")
    ins("op", "add", "t0", "t0", "a3")
    ins("st", "sw", "a4", "a6", 0)
    ins("opi", "addi", "a5", "a5", 4)
    ins("opi", "addi", "a4", "a4", 4)
    ins("opi", "addi", "t3", "t3", -1)
    ins("br", "bne", "t3", "zero", "MUL_I")
    ins("st", "sw", "a4", "t0", 0)        # T[i + 8]
    step("a0", "a2")
    ins("br", "bne", "t1", "zero", "MUL_O")
    ret()

    # ---- FOLD: Y = L + H·977 + H·2^32, ten words -----------------------------------
    K.label("FOLD")
    setk("t0", 0)                         # carry
    setk("a3", 0)                         # H[i - 1]
    setk("a4", 977)
    setk("t1", 8)
    K.label("FOLD_L")
    ins("ld", "lw", "t2", "a0", 0)        # L[i]
    ins("ld", "lw", "t3", "a1", 0)        # H[i]
    ins("op", "mul", "t4", "t3", "a4")
    ins("op", "mulhu", "t5", "t3", "a4")
    ins("op", "add", "t6", "t2", "t4")
    ins("op", "sltu", "a5", "t6", "t4")
    ins("op", "add", "t6", "t6", "a3")
    ins("op", "sltu", "a6", "t6", "a3")
    ins("op", "add", "t6", "t6", "t0")
    ins("op", "sltu", "a7", "t6", "t0")
    ins("op", "add", "t0", "t5", "a5")
    ins("op", "add", "t0", "t0", "a6")
    ins("op", "add", "t0", "t0", "a7")
    mov("a3", "t3")
    ins("st", "sw", "a2", "t6", 0)
    step("a0", "a1", "a2")
    ins("br", "bne", "t1", "zero", "FOLD_L")
    ins("op", "add", "t6", "a3", "t0")    # Y[8] = H[7] + carry
    ins("op", "sltu", "t5", "t6", "a3")   # Y[9]
    ins("st", "sw", "a2", "t6", 0)
    ins("st", "sw", "a2", "t5", 4)
    ret()

    # ---- HSET: V = [t0, t1, 0 × 6] -------------------------------------------------
    K.label("HSET")
    ins("st", "sw", "a0", "t0", 0)
    ins("st", "sw", "a0", "t1", 4)
    for k in range(2, 8):
        ins("st", "sw", "a0", "zero", 4 * k)
    ret()


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
