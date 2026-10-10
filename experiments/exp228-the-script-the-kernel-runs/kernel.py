#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp228 — the interpreter kernel, written with labels, emitted as Lean.

The kernel the proof is about is proof/Script.lean's `kernel`, a `List Instr`.
Written by hand it would be several hundred instructions of branch offsets
counted on fingers; this writes it from labels instead and puts the result
between the `BEGIN generated` and `END generated` markers in that file, with
each label's instruction number beside it, so that the proof can name places
rather than count them. check.sh runs it again and requires no difference.

  kernel.py           rewrite the generated block in proof/Script.lean
  kernel.py --check   exit 1 if the block is not what this would write

The layout of the 64 KiB region, from base:

  0x0000  the kernel
  0x1000  TABLE    256 words: where each opcode's handler starts, from base
  0x1400  SLEN     the script's length
  0x1404  SCRIPT   its bytes, at most 1020
  0x1800  DEPTH    how many elements the stack starts with, at most 32
  0x1804  STACK    32 slots of 84 bytes, bottom first: the length as a word,
                   then the element's bytes, then zeros to the end of the slot
  0x2284  TMP      one more slot, for SWAP and SHA256

Every slot the kernel writes is zeroed first, so a slot is a function of its
element alone. That is what lets two elements be compared, and a number be
read, a word at a time.

Registers, for the whole run:

  s1 base     s2 the next script byte     s3 the script's end
  s4 the next free slot                   s5 signatures checked (0 or 1)
  s6 STACK's end                          s7 STACK
  s8 TABLE                                s9 TMP
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROOF = os.path.join(HERE, "proof", "Script.lean")

TABLE, SLEN, SCRIPT, DEPTH, STACK, SLOT, DMAX = 0x1000, 0x1400, 0x1404, 0x1800, 0x1804, 84, 32
TMP = STACK + SLOT * DMAX

REG = dict(zero=0, ra=1, t0=5, t1=6, t2=7, s1=9, a0=10, a1=11, a2=12, a3=13, a4=14, a5=15, a6=16,
           a7=17, s2=18, s3=19, s4=20, s5=21, s6=22, s7=23, s8=24, s9=25, t3=28, t4=29, t5=30, t6=31)

items = []          # ("label", name) | ("i", fmt, args)


def label(name):
    items.append(("label", name))


def ins(kind, *args):
    items.append(("i", kind, args))


# ---------- macros ---------------------------------------------------------------

def li(rd, v):
    assert -2048 <= v < 2048
    ins("opi", "addi", rd, "zero", v)


def addi(rd, rs, v):
    assert -2048 <= v < 2048
    ins("opi", "addi", rd, rs, v)


def j(lbl):
    ins("jal", "zero", lbl)


def need(k, fail="F_UNDER"):
    """Fewer than k elements: fail."""
    ins("op", "sub", "t1", "s4", "s7")
    li("t2", SLOT * k)
    ins("br", "bltu", "t1", "t2", fail)


def room():
    """No slot left: fail."""
    ins("br", "bgeu", "s4", "s6", "F_OVER")


def zero(r):
    """The slot at r, all 84 bytes, zero."""
    for k in range(SLOT // 4):
        ins("st", "sw", r, "zero", 4 * k)


def copy(src, dst, words=SLOT // 4, so=0, do=0):
    for k in range(words):
        ins("ld", "lw", "t1", src, so + 4 * k)
        ins("st", "sw", dst, "t1", do + 4 * k)


def cast(r, false):
    """CastToBool of the slot at r, which is about to be dropped: clear the
    sign bit of its last byte, then any bit left is true. Jumps to `false`."""
    ins("ld", "lw", "t1", r, 0)
    ins("br", "beq", "t1", "zero", false)
    ins("op", "add", "t2", r, "t1")
    ins("ld", "lbu", "t3", "t2", 3)
    ins("opi", "andi", "t3", "t3", 0x7f)
    ins("st", "sb", "t2", "t3", 3)
    li("t4", 0)
    for k in range(1, SLOT // 4):
        ins("ld", "lw", "t5", r, 4 * k)
        ins("op", "or", "t4", "t4", "t5")
    ins("br", "beq", "t4", "zero", false)


# ---------- the kernel -----------------------------------------------------------

label("INIT")
ins("auipc", "s1", 0)
ins("lui", "t0", TABLE >> 12)
ins("op", "add", "s8", "s1", "t0")
ins("ld", "lw", "t1", "s8", SLEN - TABLE)
addi("s2", "s8", SCRIPT - TABLE)
ins("op", "add", "s3", "s2", "t1")
ins("ld", "lw", "t2", "s2", DEPTH - SCRIPT)
addi("s7", "s2", STACK - SCRIPT)
li("t3", SLOT)
ins("op", "mul", "t3", "t2", "t3")
ins("op", "add", "s4", "s7", "t3")
addi("s6", "s7", 2047)
addi("s6", "s6", SLOT * DMAX - 2047)
addi("s9", "s6", 0)
li("s5", 0)

label("LOOP")
ins("br", "bgeu", "s2", "s3", "END")
ins("ld", "lbu", "t0", "s2", 0)
addi("s2", "s2", 1)
ins("sh", "slli", "t1", "t0", 2)
ins("op", "add", "t1", "t1", "s8")
ins("ld", "lw", "t1", "t1", 0)
ins("op", "add", "t1", "t1", "s1")
ins("jalr", "zero", "t1", 0)

FAILS = ["F_BAD", "F_PAST", "F_UNDER", "F_OVER", "F_NUM", "F_VERIFY", "F_SIZE", "F_INVALID",
         "F_COUNT", "F_CLEAN", "F_FALSE", "F_EQV"]
for code, name in enumerate(FAILS, start=1):
    label(name)
    li("a0", code)
    j("HALT")
label("HALT")
li("t0", 1)
ins("ecall")

label("H_OP0")
room()
zero("s4")
addi("s4", "s4", SLOT)
j("LOOP")

label("H_PUSH")
ins("op", "add", "t2", "s2", "t0")
ins("br", "bltu", "s3", "t2", "F_PAST")
room()
zero("s4")
ins("st", "sw", "s4", "t0", 0)
addi("t3", "s4", 4)
label("PUSH_BYTE")
ins("ld", "lbu", "t4", "s2", 0)
ins("st", "sb", "t3", "t4", 0)
addi("s2", "s2", 1)
addi("t3", "t3", 1)
ins("br", "bne", "s2", "t2", "PUSH_BYTE")
addi("s4", "s4", SLOT)
j("LOOP")

label("H_NEG1")
li("t0", 0x81 + 0x50)
label("H_OPN")
room()
zero("s4")
li("t1", 1)
ins("st", "sw", "s4", "t1", 0)
addi("t1", "t0", -0x50)
ins("st", "sb", "s4", "t1", 4)
addi("s4", "s4", SLOT)
j("LOOP")

label("H_VERIFY")
need(1)
addi("s4", "s4", -SLOT)
cast("s4", "F_VERIFY")
j("LOOP")

label("H_DROP")
need(1)
addi("s4", "s4", -SLOT)
j("LOOP")

label("H_DUP")
need(1)
room()
addi("a3", "s4", -SLOT)
copy("a3", "s4")
addi("s4", "s4", SLOT)
j("LOOP")

label("H_NIP")
need(2)
addi("a3", "s4", -SLOT)
addi("a4", "s4", -2 * SLOT)
copy("a3", "a4")
addi("s4", "s4", -SLOT)
j("LOOP")

label("H_OVER")
need(2)
room()
addi("a3", "s4", -2 * SLOT)
copy("a3", "s4")
addi("s4", "s4", SLOT)
j("LOOP")

label("H_SWAP")
need(2)
addi("a3", "s4", -SLOT)
addi("a4", "s4", -2 * SLOT)
copy("a3", "s9")
copy("a4", "a3")
copy("s9", "a4")
j("LOOP")

label("H_EQUAL")
li("t6", 0)
j("EQ")
label("H_EQV")
li("t6", 1)
label("EQ")
need(2)
addi("a3", "s4", -SLOT)
addi("a4", "s4", -2 * SLOT)
li("t4", 0)
for k in range(SLOT // 4):
    ins("ld", "lw", "t1", "a3", 4 * k)
    ins("ld", "lw", "t2", "a4", 4 * k)
    ins("op", "xor", "t1", "t1", "t2")
    ins("op", "or", "t4", "t4", "t1")
addi("s4", "s4", -2 * SLOT)
ins("br", "bne", "t6", "zero", "EQV_TAIL")
zero("s4")
ins("br", "bne", "t4", "zero", "EQ_PUSH")
li("t1", 1)
ins("st", "sw", "s4", "t1", 0)
ins("st", "sb", "s4", "t1", 4)
label("EQ_PUSH")
addi("s4", "s4", SLOT)
j("LOOP")
label("EQV_TAIL")
ins("br", "bne", "t4", "zero", "F_EQV")
j("LOOP")

# A number from the slot at a0: its sign in a1, its magnitude in a2, back to ra.
label("DECODE")
ins("ld", "lw", "t1", "a0", 0)
li("a1", 0)
li("a2", 0)
ins("br", "beq", "t1", "zero", "DEC_RET")
li("t2", 4)
ins("br", "bltu", "t2", "t1", "F_NUM")
ins("ld", "lw", "t3", "a0", 4)
ins("sh", "slli", "t4", "t1", 3)
addi("t5", "t4", -8)
ins("op", "srl", "t2", "t3", "t5")
ins("opi", "andi", "t6", "t2", 0x7f)
ins("br", "bne", "t6", "zero", "DEC_OK")
li("t6", 1)
ins("br", "beq", "t1", "t6", "F_NUM")
addi("t5", "t4", -16)
ins("op", "srl", "t6", "t3", "t5")
ins("opi", "andi", "t6", "t6", 0x80)
ins("br", "beq", "t6", "zero", "F_NUM")
label("DEC_OK")
ins("sh", "srli", "a1", "t2", 7)
addi("t5", "t4", -1)
li("t6", 1)
ins("op", "sll", "t6", "t6", "t5")
ins("opi", "xori", "t6", "t6", -1)
ins("op", "and", "a2", "t3", "t6")
label("DEC_RET")
ins("jalr", "zero", "ra", 0)

label("H_1ADD")
li("a5", 0)
j("UNARY")
label("H_1SUB")
li("a5", 1)
label("UNARY")
need(1)
addi("a0", "s4", -SLOT)
ins("jal", "ra", "DECODE")
addi("a3", "a1", 0)
addi("a4", "a2", 0)
li("a6", 1)
addi("s4", "s4", -SLOT)
j("CORE")

label("H_ADD")
li("a7", 0)
j("BINARY")
label("H_SUB")
li("a7", 1)
label("BINARY")
need(2)
addi("a0", "s4", -SLOT)
ins("jal", "ra", "DECODE")
ins("op", "xor", "a5", "a1", "a7")
addi("a6", "a2", 0)
addi("a0", "s4", -2 * SLOT)
ins("jal", "ra", "DECODE")
addi("a3", "a1", 0)
addi("a4", "a2", 0)
addi("s4", "s4", -2 * SLOT)

# (a3, a4) + (a5, a6), signs and magnitudes, into (a1, a2).
label("CORE")
ins("br", "bne", "a3", "a5", "CORE_DIFF")
ins("op", "add", "a2", "a4", "a6")
addi("a1", "a3", 0)
j("ENCODE")
label("CORE_DIFF")
ins("br", "bltu", "a4", "a6", "CORE_LT")
ins("op", "sub", "a2", "a4", "a6")
addi("a1", "a3", 0)
j("ENCODE")
label("CORE_LT")
ins("op", "sub", "a2", "a6", "a4")
addi("a1", "a5", 0)

# The number (a1, a2) into a fresh slot at s4, pushed.
label("ENCODE")
zero("s4")
ins("br", "beq", "a2", "zero", "ENC_DONE")
li("t1", 1)
ins("sh", "srli", "t2", "a2", 8)
ins("br", "beq", "t2", "zero", "ENC_N")
li("t1", 2)
ins("sh", "srli", "t2", "a2", 16)
ins("br", "beq", "t2", "zero", "ENC_N")
li("t1", 3)
ins("sh", "srli", "t2", "a2", 24)
ins("br", "beq", "t2", "zero", "ENC_N")
li("t1", 4)
label("ENC_N")
ins("sh", "slli", "t3", "t1", 3)
addi("t4", "t3", -8)
ins("op", "srl", "t2", "a2", "t4")
ins("opi", "andi", "t2", "t2", 0x80)
ins("br", "beq", "t2", "zero", "ENC_FITS")
# The magnitude's word first, then the sign byte after it: the other way
# round, the word would write over the sign byte whenever the magnitude has
# fewer than four bytes (-128 would come out as 80 00, which is 128).
ins("sh", "slli", "t5", "a1", 7)
ins("op", "add", "t6", "s4", "t1")
ins("st", "sw", "s4", "a2", 4)
ins("st", "sb", "t6", "t5", 4)
addi("t1", "t1", 1)
ins("st", "sw", "s4", "t1", 0)
j("ENC_DONE")
label("ENC_FITS")
addi("t4", "t3", -1)
ins("op", "sll", "t5", "a1", "t4")
ins("op", "or", "a2", "a2", "t5")
ins("st", "sw", "s4", "a2", 4)
ins("st", "sw", "s4", "t1", 0)
label("ENC_DONE")
addi("s4", "s4", SLOT)
j("LOOP")

label("H_SHA")
need(1)
addi("a3", "s4", -SLOT)
addi("a0", "a3", 4)
ins("ld", "lw", "a1", "a3", 0)
addi("a2", "s9", 4)
li("t0", 2)
ins("ecall")
zero("a3")
copy("s9", "a3", words=8, so=4, do=4)
li("t1", 32)
ins("st", "sw", "a3", "t1", 0)
j("LOOP")

label("H_CHECKSIG")
need(2)
addi("a3", "s4", -SLOT)
addi("a4", "s4", -2 * SLOT)
ins("ld", "lw", "t1", "a3", 0)
li("t2", 32)
ins("br", "bne", "t1", "t2", "F_SIZE")
ins("ld", "lw", "t3", "a4", 0)
addi("s4", "s4", -2 * SLOT)
ins("br", "bne", "t3", "zero", "CS_SIG")
zero("s4")
addi("s4", "s4", SLOT)
j("LOOP")
label("CS_SIG")
li("t2", 64)
ins("br", "bne", "t3", "t2", "F_SIZE")
ins("br", "bne", "s5", "zero", "F_COUNT")
addi("a0", "a3", 4)
addi("a1", "a4", 4)
li("t0", 3)
ins("ecall")
ins("br", "beq", "a0", "zero", "F_INVALID")
li("s5", 1)
zero("s4")
li("t1", 1)
ins("st", "sw", "s4", "t1", 0)
ins("st", "sb", "s4", "t1", 4)
addi("s4", "s4", SLOT)
j("LOOP")

label("END")
ins("op", "sub", "t1", "s4", "s7")
li("t2", SLOT)
ins("br", "bne", "t1", "t2", "F_CLEAN")
cast("s7", "F_FALSE")
li("a0", 0)
j("HALT")

# ---------- which handler for which opcode -----------------------------------------

def handler(op):
    if op == 0x00: return "H_OP0"
    if op <= 0x4b: return "H_PUSH"
    if op == 0x4f: return "H_NEG1"
    if 0x51 <= op <= 0x60: return "H_OPN"
    if op == 0x61: return "LOOP"
    return {0x69: "H_VERIFY", 0x75: "H_DROP", 0x76: "H_DUP", 0x77: "H_NIP", 0x78: "H_OVER",
            0x7c: "H_SWAP", 0x87: "H_EQUAL", 0x88: "H_EQV", 0x8b: "H_1ADD", 0x8c: "H_1SUB",
            0x93: "H_ADD", 0x94: "H_SUB", 0xa8: "H_SHA", 0xac: "H_CHECKSIG"}.get(op, "F_BAD")


# ---------- assembly into Lean -----------------------------------------------------

def assemble():
    labels, n = {}, 0
    for it in items:
        if it[0] == "label":
            assert it[1] not in labels, it[1]
            labels[it[1]] = n
        else:
            n += 1
    out, pc = [], 0
    for it in items:
        if it[0] == "label":
            continue
        kind, args = it[1], it[2]
        r = lambda x: REG[x]
        if kind == "opi":
            op, rd, rs, v = args
            text = f".opi .{op} {r(rd)} {r(rs)} {v & 0xfff:#x}"
        elif kind == "op":
            op, rd, a, b = args
            text = f".op .{op} {r(rd)} {r(a)} {r(b)}"
        elif kind == "sh":
            op, rd, rs, v = args
            text = f".sh .{op} {r(rd)} {r(rs)} {v}"
        elif kind == "ld":
            op, rd, rs, v = args
            assert -2048 <= v < 2048
            text = f".ld .{op} {r(rd)} {r(rs)} {v & 0xfff:#x}"
        elif kind == "st":
            op, rs1, rs2, v = args
            assert -2048 <= v < 2048
            text = f".st .{op} {r(rs1)} {r(rs2)} {v & 0xfff:#x}"
        elif kind == "br":
            op, a, b, lbl = args
            off = 4 * (labels[lbl] - pc)
            assert -4096 <= off < 4096, (lbl, off)
            text = f".br .{op} {r(a)} {r(b)} {(off >> 1) & 0xfff:#x}"
        elif kind == "jal":
            rd, lbl = args
            off = 4 * (labels[lbl] - pc)
            text = f".jal {r(rd)} {(off >> 1) & 0xfffff:#x}"
        elif kind == "jalr":
            rd, rs, v = args
            text = f".jalr {r(rd)} {r(rs)} {v & 0xfff:#x}"
        elif kind == "auipc":
            rd, v = args
            text = f".auipc {r(rd)} {v:#x}"
        elif kind == "lui":
            rd, v = args
            text = f".lui {r(rd)} {v:#x}"
        elif kind == "ecall":
            text = ".ecall"
        else:
            raise ValueError(kind)
        out.append(text)
        pc += 1
    return labels, out


def lean_block():
    labels, code = assemble()
    assert 4 * len(code) <= TABLE, len(code)
    lines = ["-- BEGIN generated by kernel.py — do not edit", ""]
    lines.append("/-- Where each label is: an instruction number. -/")
    for name, k in labels.items():
        lines.append(f"def {name} : Nat := {k}")
    lines.append("")
    lines.append(f"/-- The kernel, {len(code)} instructions. -/")
    lines.append("def kernel : List Instr := [")
    for k, text in enumerate(code):
        sep = "," if k + 1 < len(code) else " ]"
        lines.append(f"  {text}{sep}")
    lines.append("")
    lines.append("/-- Each opcode's handler, as a byte offset from base. -/")
    tab = [4 * labels[handler(op)] for op in range(256)]
    lines.append("def table : List Nat := [")
    for k in range(0, 256, 16):
        row = ", ".join(f"{v:#x}" for v in tab[k:k + 16])
        lines.append(f"  {row}{',' if k + 16 < 256 else ' ]'}")
    lines.append("")
    lines.append("-- END generated by kernel.py")
    return "\n".join(lines)


def splice(text, block):
    pat = re.compile(r"-- BEGIN generated by kernel\.py.*?-- END generated by kernel\.py", re.S)
    assert pat.search(text), "no generated block in proof/Script.lean"
    return pat.sub(lambda _: block, text)


if __name__ == "__main__":
    text = open(PROOF).read()
    new = splice(text, lean_block())
    if sys.argv[1:] == ["--check"]:
        sys.exit(0 if new == text else 1)
    open(PROOF, "w").write(new)
    labels, code = assemble()
    print(f"proof/Script.lean: {len(code)} instructions, {len(labels)} labels")
