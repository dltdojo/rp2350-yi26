#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""vk26-alice-5 — the reference: the chain from samples to random bits, each
step from its text and nothing like the kernels' registers.

  1. vk26-alice-2's kernel (../tools/trustref.py): the KAT on the hash, the
     start-up window, the next window; its digest is the entropy input;
  2. Instantiate (SP 800-90A Rev. 1 §10.1.1.2, ../tools/hashdrbg.py):
     seed_material = entropy ‖ nonce ‖ personalization string,
     V = Hash_df(seed_material), C = Hash_df(0x00 ‖ V), counter 1;
  3. vk26-alice-4's Generate (../tools/hashdrbg.py).

Between kernels the shell puts the next kernel's bytes at the region's start
and nothing else: each kernel reads what the last one left.

  seed.py              every NIST case through Instantiate and two Generates,
                       and every stream of trust.py's through the whole chain

  inst_image(region, seed, m, interval)
                     the region with the Instantiate kernel's inputs: the seed
                     material at 0x2400, its length and m and the interval at
                     0x2480 (the kernel's own bytes go in with load_code)
  inst_region(region)
                     the whole 64 KiB region after the Instantiate kernel
  seed_chain(words, nonce, m, want)
                     (code, bits, why): the chain on 2048 samples; bits only
                     when every step passed
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
from hashdrbg import (HB, ONE, PARAMS, PRE, SEEDLEN, V_AT, C_AT, cavp_cases, drbg_generate,  # noqa: E402
                      drbg_instantiate, sha256)
from trustref import OUTPUT, trust_outcome  # noqa: E402

REGION = 0x10000
SEED = OUTPUT              # 0x2400: alice-2's digest, the entropy input
NONCE = SEED + 32          # 0x2420
PI = 0x2480                # m, interval, S
DFPRE = SEED - 5           # 0x23fb: counter, 00 00 01 b8
CPRE = V_AT - 6            # 0x43a: counter, 00 00 01 b8, 00
NONCE_LEN = 16
INTERVAL = 2


def load_code(region, code):
    """The shell's one step between kernels: the next kernel's bytes at the start."""
    r = bytearray(region) + bytes(REGION - len(region))
    r[:len(code)] = code
    return bytes(r)


def inst_image(region, seed, m, interval=INTERVAL):
    assert len(seed) <= PI - SEED
    r = bytearray(region) + bytes(REGION - len(region))
    r[SEED:SEED + len(seed)] = seed
    r[PI:PI + 12] = struct.pack("<3I", m, interval, len(seed))
    return bytes(r)


def df_prefix(k):
    return bytes([k]) + (8 * SEEDLEN).to_bytes(4, "big")


def inst_region(region):
    """What the Instantiate kernel leaves: Hash_df's two hashes for V at 0x440
    and 0x460, for C at 0x480 and 0x4a0, the prefixes it wrote (the counter
    last 2), 0x03 at 0x43f, the zeros and the 1 vk26-alice-4's Generate wants,
    and m, the interval and the counter 1 at 0x400. Nothing else."""
    r = bytearray(region)
    m, interval, s = struct.unpack("<3I", r[PI:PI + 12])
    seed = bytes(r[SEED:SEED + s])
    h1, h2 = sha256(df_prefix(1) + seed), sha256(df_prefix(2) + seed)
    v = (h1 + h2)[:SEEDLEN]
    c1, c2 = sha256(df_prefix(1) + b"\x00" + v), sha256(df_prefix(2) + b"\x00" + v)
    r[DFPRE:SEED] = df_prefix(2)
    r[V_AT:V_AT + 64] = h1 + h2
    r[CPRE:V_AT] = df_prefix(2) + b"\x00"
    r[C_AT:C_AT + 64] = c1 + c2
    r[PRE] = 3
    r[HB:HB + 0xb8] = bytes(0xb8)
    r[ONE + SEEDLEN - 1] = 1
    r[PARAMS:PARAMS + 12] = struct.pack("<3I", m, interval, 1)
    assert v == bytes(r[V_AT:V_AT + SEEDLEN])
    return bytes(r)


def nonce_of(n):
    """The shell's nonce: its round counter, as 16 bytes, little-endian."""
    return n.to_bytes(NONCE_LEN, "little")


def seed_chain(words, nonce, m=4, want=None):
    """The chain as the plan states it: (alice-2's halt code, the returned
    bits or None, why)."""
    code, writes, why = trust_outcome(words, want)
    if code != 0:
        return code, None, why
    state = drbg_instantiate(writes[OUTPUT], nonce)
    bits, _ = drbg_generate(state, 32 * m, INTERVAL)
    return 0, bits, None


def seed_check():
    """Instantiate as inst_region does it, against hashdrbg's, on every NIST
    case: V and C the same, and so the second Generate NIST's."""
    ok = 0
    cases = cavp_cases()
    for c in cases:
        r = inst_region(inst_image(bytes(REGION), c["entropy"] + c["nonce"] + c["pers"], 4))
        v, cc, _ = drbg_instantiate(c["entropy"], c["nonce"], c["pers"])
        state = (bytes(r[V_AT:V_AT + SEEDLEN]), bytes(r[C_AT:C_AT + SEEDLEN]), 1)
        _, state = drbg_generate(state, 128, INTERVAL)
        bits, _ = drbg_generate(state, 128, INTERVAL)
        ok += r[V_AT:V_AT + SEEDLEN] == v and r[C_AT:C_AT + SEEDLEN] == cc and bits == c["want"]
    print(f"{ok} of {len(cases)} NIST cases: the Instantiate kernel's region holds hashdrbg's V and C, and two "
          f"Generates from it give NIST's ReturnedBits")
    return ok == len(cases)


if __name__ == "__main__":
    sys.exit(0 if seed_check() else 1)
