# SPDX-License-Identifier: Apache-2.0
"""exp228 — scripts and the images that hold them.

  image(kernel, script, stack)   kernel.bin with the script and the initial
                                 stack laid out where the kernel reads them
  hand()                         name -> (script, stack, sig): one case at
                                 least for every opcode and every way to fail
  fuzz(n, seed)                  n scripts drawn mostly from the subset's own
                                 opcodes, so that most of them run a while
  KEY, MSG, SIGN(...)            a BIP340 key, the message every CHECKSIG
                                 here is about, and a signature on it

The message stands where BIP341's signature hash stands in tapscript: the shell
holds it, and the kernel never sees it.
"""
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "bip340"))
import reference as bip340  # noqa: E402
from script import DMAX, EMAX, SMAX  # noqa: E402

SLEN, SCRIPT, DEPTH, STACK, SLOT = 0x1400, 0x1404, 0x1800, 0x1804, 84

SECKEY = bytes.fromhex("b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef")
KEY = bip340.pubkey_gen(SECKEY)
MSG = bytes.fromhex("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")   # sha256("")


def SIGN(msg=MSG, aux=b"\x00" * 32):
    return bip340.schnorr_sign(msg, SECKEY, aux)


def valid(pk, s, msg=MSG):
    return len(pk) == 32 and len(s) == 64 and bip340.schnorr_verify(msg, pk, s)


def slot(e):
    assert len(e) <= EMAX
    return struct.pack("<I", len(e)) + bytes(e) + bytes(EMAX - len(e))


def image(kernel, script, stack):
    assert len(script) <= SMAX and len(stack) <= DMAX
    img = bytearray(STACK + SLOT * len(stack))
    img[:len(kernel)] = kernel
    img[SLEN:SLEN + 4] = struct.pack("<I", len(script))
    img[SCRIPT:SCRIPT + len(script)] = script
    img[DEPTH:DEPTH + 4] = struct.pack("<I", len(stack))
    for i, e in enumerate(stack):
        img[STACK + SLOT * i:STACK + SLOT * (i + 1)] = slot(e)
    return bytes(img)


def push(b):
    b = bytes(b)
    assert 1 <= len(b) <= 0x4b
    return bytes([len(b)]) + b


def num(v):
    from script import encode
    e = encode(v)
    return b"\x00" if not e else push(e)


OP = dict(OP_0=0x00, OP_1NEGATE=0x4f, OP_1=0x51, OP_2=0x52, OP_3=0x53, OP_16=0x60, OP_NOP=0x61,
          OP_VERIFY=0x69, OP_DROP=0x75, OP_DUP=0x76, OP_NIP=0x77, OP_OVER=0x78, OP_SWAP=0x7c,
          OP_EQUAL=0x87, OP_EQUALVERIFY=0x88, OP_1ADD=0x8b, OP_1SUB=0x8c, OP_ADD=0x93, OP_SUB=0x94,
          OP_SHA256=0xa8, OP_CHECKSIG=0xac)
globals().update(OP)


def ops(*xs):
    out = bytearray()
    for x in xs:
        out += bytes([x]) if isinstance(x, int) else bytes(x)
    return bytes(out)


def hand():
    import hashlib
    sig = SIGN()
    h = hashlib.sha256(KEY).digest()
    c = {}
    # accepted
    c["one"] = (ops(OP_1), [], False)
    c["2+3=5"] = (ops(OP_2, OP_3, OP_ADD, num(5), OP_EQUAL), [], False)
    c["7-9=-2"] = (ops(num(7), num(9), OP_SUB, num(-2), OP_EQUAL), [], False)
    c["1add of 0x7fffffff"] = (ops(num(0x7fffffff), OP_1ADD, num(0x80000000), OP_EQUAL), [], False)
    c["1sub of -0x7fffffff"] = (ops(num(-0x7fffffff), OP_1SUB, push(b"\x00\x00\x00\x80\x80"), OP_EQUAL), [], False)
    c["dup drop nip over swap"] = (ops(OP_1, OP_2, OP_SWAP, OP_DROP, OP_DUP, OP_OVER, OP_NIP, OP_EQUAL,
                                       OP_VERIFY, OP_16), [], False)
    c["sha256 of a witness"] = (ops(OP_SHA256, push(hashlib.sha256(b"abc").digest()), OP_EQUAL), [b"abc"], False)
    c["sha256 of nothing"] = (ops(OP_0, OP_SHA256, push(hashlib.sha256(b"").digest()), OP_EQUAL), [], False)
    c["pay to key hash"] = (ops(OP_DUP, OP_SHA256, push(h), OP_EQUALVERIFY, OP_CHECKSIG), [sig, KEY], True)
    c["pay to key"] = (ops(push(KEY), OP_CHECKSIG), [sig], True)
    c["empty signature pushes false"] = (ops(push(KEY), OP_CHECKSIG, OP_0, OP_EQUAL), [b""], False)
    c["negative zero is false"] = (ops(OP_VERIFY, OP_1), [b"\x00\x80"], False)
    c["nop"] = (ops(OP_NOP, OP_1, OP_NOP), [], False)
    c["1negate"] = (ops(OP_1NEGATE, OP_1ADD, OP_0, OP_EQUAL), [], False)
    # each way to fail
    c["bad opcode"] = (ops(OP_1, 0x6a), [], False)                  # OP_RETURN
    c["pushdata1"] = (ops(0x4c, 0x01, 0x01), [], False)
    c["push past the end"] = (ops(0x05, 1, 2, 3), [], False)
    c["underflow"] = (ops(OP_1, OP_ADD), [], False)
    c["overflow"] = (ops(*([OP_1] * (DMAX + 1))), [], False)
    c["overflow by dup"] = (ops(*([OP_DUP] * 2)), [b"x"] * (DMAX - 1), False)
    c["5-byte operand"] = (ops(push(b"\x01\x02\x03\x04\x05"), OP_1ADD), [], False)
    c["non-minimal operand"] = (ops(push(b"\x01\x00"), OP_1ADD), [], False)
    c["non-minimal zero"] = (ops(push(b"\x00"), OP_1ADD), [], False)
    c["verify false"] = (ops(OP_0, OP_VERIFY, OP_1), [], False)
    c["key the wrong size"] = (ops(push(KEY[:31]), OP_CHECKSIG), [sig], True)
    c["signature the wrong size"] = (ops(push(KEY), OP_CHECKSIG), [sig + b"\x01"], True)
    c["signature invalid"] = (ops(push(KEY), OP_CHECKSIG), [sig[:-1] + bytes([sig[-1] ^ 1])], True)
    c["a second signature"] = (ops(OP_DUP, push(KEY), OP_CHECKSIG, OP_VERIFY, push(KEY), OP_CHECKSIG),
                               [sig], True)
    c["two left"] = (ops(OP_1, OP_1), [], False)
    c["none left"] = (b"", [], False)
    c["false left"] = (ops(OP_0), [], False)
    c["equalverify unequal"] = (ops(OP_1, OP_2, OP_EQUALVERIFY, OP_1), [], False)
    c["the whole stack, all 32"] = (ops(*([OP_DROP] * (DMAX - 1))), [bytes([i + 1]) * 80 for i in range(DMAX)], False)
    return c


def fuzz(n, seed=228):
    rng = random.Random(seed)
    common = [0x00, 0x4f, 0x51, 0x52, 0x60, 0x61, 0x69, 0x75, 0x76, 0x77, 0x78, 0x7c, 0x87, 0x88,
              0x8b, 0x8c, 0x93, 0x94, 0xa8, 0xac]
    out = []
    for _ in range(n):
        script = bytearray()
        for _ in range(rng.randrange(0, 24)):
            r = rng.random()
            if r < 0.6:
                script.append(rng.choice(common))
            elif r < 0.85:
                k = rng.choice([1, 2, 3, 4, 5, 32, rng.randrange(1, 76)])
                body = bytes(rng.choice([0, 0x80, 0x7f, 0xff, rng.randrange(256)]) for _ in range(k))
                script += bytes([k]) + body[:k] if rng.random() < 0.97 else bytes([k]) + body[:k // 2]
            else:
                script.append(rng.randrange(256))
        stack = [bytes(rng.randrange(256) for _ in range(rng.choice([0, 1, 2, 4, 5, 32, 64, 80])))
                 for _ in range(rng.randrange(0, 5))]
        out.append((bytes(script[:SMAX]), stack))
    return out
