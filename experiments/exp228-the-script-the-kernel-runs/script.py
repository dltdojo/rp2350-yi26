#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp228 — the Script subset, in Python: what the kernel must halt with.

A reading of BIP342's tapscript, made stricter wherever being exact would cost
the proof something, so that a script this subset accepts is one tapscript
would accept too, given the same answer from OP_CHECKSIG. Where it is stricter
it fails, never succeeds; the README lists every place.

  run(script, stack, sig=None, h=None)   the halt code, 0 = accept
      script   bytes
      stack    the initial stack, bottom first — a witness, each element bytes
      sig      (pubkey, signature) -> bool, what the shell answers; default no
      h        bytes -> 32 bytes; default SHA-256

The opcodes:

  0x00          OP_0          push the empty element
  0x01-0x4b     push n        push the next n bytes of the script
  0x4f          OP_1NEGATE    push [0x81]
  0x51-0x60     OP_1..OP_16   push [n]
  0x61          OP_NOP
  0x69          OP_VERIFY     pop; fail unless true
  0x75 0x76     OP_DROP OP_DUP
  0x77 0x78     OP_NIP OP_OVER
  0x7c          OP_SWAP
  0x87 0x88     OP_EQUAL OP_EQUALVERIFY
  0x8b 0x8c     OP_1ADD OP_1SUB
  0x93 0x94     OP_ADD OP_SUB
  0xa8          OP_SHA256
  0xac          OP_CHECKSIG   tapscript's: a 32-byte key, a 64-byte signature or none
  anything else fails

The order of the checks inside each opcode is the kernel's, so that the codes
agree as well as the verdicts.
"""
import hashlib

SMAX = 1020      # script bytes
EMAX = 80        # bytes in one element
DMAX = 32        # elements on the stack

OK, BAD_OPCODE, PUSH_PAST_END, UNDERFLOW, OVERFLOW, NUM, VERIFY, SIG_SIZE, SIG_INVALID, \
    SIG_COUNT, CLEANSTACK, FALSE, EQUALVERIFY = range(13)

NAMES = ["accept", "bad opcode", "push past the end", "too few elements", "too many elements",
         "not a 4-byte minimal number", "OP_VERIFY false", "key or signature the wrong size",
         "signature invalid", "a second signature", "not exactly one element left", "false",
         "OP_EQUALVERIFY unequal"]


class Fail(Exception):
    def __init__(self, code):
        super().__init__(NAMES[code])
        self.code = code


def cast(e):
    """CastToBool: any nonzero byte, except a lone sign bit in the last."""
    for i, b in enumerate(e):
        if b != 0:
            return not (i == len(e) - 1 and b == 0x80)
    return False


def decode(e):
    """A number: at most 4 bytes, minimally encoded, little-endian sign and magnitude."""
    if len(e) > 4:
        raise Fail(NUM)
    if not e:
        return 0
    if e[-1] & 0x7f == 0 and (len(e) == 1 or e[-2] & 0x80 == 0):
        raise Fail(NUM)
    mag = int.from_bytes(e, "little") & ~(0x80 << 8 * (len(e) - 1))
    return -mag if e[-1] & 0x80 else mag


def encode(v):
    """Bitcoin Core's CScriptNum::serialize."""
    if v == 0:
        return b""
    mag, out = abs(v), bytearray()
    while mag:
        out.append(mag & 0xff)
        mag >>= 8
    if out[-1] & 0x80:
        out.append(0x80 if v < 0 else 0)
    elif v < 0:
        out[-1] |= 0x80
    return bytes(out)


def run(script, stack, sig=None, h=None):
    sig = sig or (lambda pk, s: False)
    h = h or (lambda b: hashlib.sha256(b).digest())
    assert len(script) <= SMAX and len(stack) <= DMAX and all(len(e) <= EMAX for e in stack)
    st = [bytes(e) for e in stack]       # bottom first
    sigs = 0
    pc = 0

    def need(k):
        if len(st) < k:
            raise Fail(UNDERFLOW)

    def room():
        if len(st) >= DMAX:
            raise Fail(OVERFLOW)

    try:
        while pc < len(script):
            op = script[pc]
            pc += 1
            if op == 0x00:
                room()
                st.append(b"")
            elif op <= 0x4b:
                if pc + op > len(script):
                    raise Fail(PUSH_PAST_END)
                room()
                st.append(bytes(script[pc:pc + op]))
                pc += op
            elif op == 0x4f:
                room()
                st.append(b"\x81")
            elif 0x51 <= op <= 0x60:
                room()
                st.append(bytes([op - 0x50]))
            elif op == 0x61:
                pass
            elif op == 0x69:
                need(1)
                if not cast(st.pop()):
                    raise Fail(VERIFY)
            elif op == 0x75:
                need(1)
                st.pop()
            elif op == 0x76:
                need(1)
                room()
                st.append(st[-1])
            elif op == 0x77:
                need(2)
                del st[-2]
            elif op == 0x78:
                need(2)
                room()
                st.append(st[-2])
            elif op == 0x7c:
                need(2)
                st[-1], st[-2] = st[-2], st[-1]
            elif op in (0x87, 0x88):
                need(2)
                same = st.pop() == st.pop()
                if op == 0x88:
                    if not same:
                        raise Fail(EQUALVERIFY)
                else:
                    st.append(b"\x01" if same else b"")
            elif op in (0x8b, 0x8c):
                need(1)
                a = decode(st.pop())
                st.append(encode(a + 1 if op == 0x8b else a - 1))
            elif op in (0x93, 0x94):
                need(2)
                b = decode(st[-1])
                a = decode(st[-2])
                del st[-2:]
                st.append(encode(a + b if op == 0x93 else a - b))
            elif op == 0xa8:
                need(1)
                st.append(h(st.pop()))
            elif op == 0xac:
                need(2)
                pk = st.pop()
                s = st.pop()
                if len(pk) != 32:
                    raise Fail(SIG_SIZE)
                if not s:
                    st.append(b"")
                    continue
                if len(s) != 64:
                    raise Fail(SIG_SIZE)
                if sigs:
                    raise Fail(SIG_COUNT)
                if not sig(pk, s):
                    raise Fail(SIG_INVALID)
                sigs = 1
                st.append(b"\x01")
            else:
                raise Fail(BAD_OPCODE)
        if len(st) != 1:
            raise Fail(CLEANSTACK)
        if not cast(st[0]):
            raise Fail(FALSE)
        return OK
    except Fail as f:
        return f.code
