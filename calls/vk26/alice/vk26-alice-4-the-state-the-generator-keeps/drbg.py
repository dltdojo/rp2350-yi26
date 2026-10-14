#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""vk26-alice-4 — the reference: Hash_DRBG from SP 800-90A Rev. 1's text
(§10.1.1, §10.3.1), with SHA-256 and seedlen = 440 bits, nothing like the
kernel's registers; and what the kernel's region must hold before and after.

  drbg.py            every case of cavp/Hash_DRBG_SHA256.txt: instantiate,
                     Generate twice, the second's bits against NIST's

  drbg_instantiate(entropy, nonce, pers)   (V, C, reseed_counter), §10.1.1.2
  drbg_generate(state, nbytes)             (bits, new state), §10.1.1.4, no
                                      additional input; None when a reseed
                                      is required
  drbg_image(kernel, state, interval, m)
                     the region's image: the kernel, then the state where
                     the kernel keeps it (the header of proof/Drbg.lean)
  drbg_outcome(state, interval, m)
                     (halt code, {offset: bytes}): what Generate leaves
  drbg_region(img, state, interval, m)
                     (halt code, the whole 64 KiB region afterwards)
  cavp_cases()       the NIST cases, as dicts

Instantiate's Hash_df is here so that NIST's vectors can be used. It is not
the kernel's and is in no proof: vk26-alice-5 is where it is meant to be.
"""
import hashlib
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SEEDLEN = 55                      # 440 bits
PARAMS, PRE, V_AT, C_AT, DATA, HB, CB, ONE, OUT = 0x400, 0x43f, 0x440, 0x480, 0x4c0, 0x500, 0x540, 0x580, 0x600
MAX_BLOCKS = (0x10000 - OUT) // 32


def sha256(b):
    return hashlib.sha256(b).digest()


def hash_df(data, nbytes):
    """§10.3.1: as many hashes of counter ‖ no_of_bits ‖ input as fill nbytes."""
    out, counter = b"", 1
    while len(out) < nbytes:
        out += sha256(bytes([counter]) + (8 * nbytes).to_bytes(4, "big") + data)
        counter += 1
    return out[:nbytes]


def drbg_instantiate(entropy, nonce, pers=b""):
    """§10.1.1.2: V = Hash_df(seed material), C = Hash_df(0x00 ‖ V), counter 1."""
    v = hash_df(entropy + nonce + pers, SEEDLEN)
    return v, hash_df(b"\x00" + v, SEEDLEN), 1


def plus(*terms):
    """The sum, mod 2^seedlen, as seedlen bytes: §10.1.1.4 step 4's arithmetic."""
    total = sum(int.from_bytes(t, "big") if isinstance(t, bytes) else t for t in terms)
    return (total % (1 << (8 * SEEDLEN))).to_bytes(SEEDLEN, "big")


def hashgen(v, nbytes):
    """§10.1.1.4's Hashgen: Hash(data), data + 1, … until nbytes are made."""
    out, data = b"", v
    while len(out) < nbytes:
        out += sha256(data)
        data = plus(data, 1)
    return out[:nbytes]


def drbg_generate(state, nbytes, interval=1 << 48):
    """§10.1.1.4 with no additional input."""
    v, c, counter = state
    if counter > interval:
        return None
    bits = hashgen(v, nbytes)
    h = sha256(b"\x03" + v)
    return bits, (plus(v, h, c, counter), c, counter + 1)


def drbg_image(kernel, state, interval, m):
    v, c, counter = state
    assert len(v) == len(c) == SEEDLEN and 1 <= m <= MAX_BLOCKS and counter < 2 ** 32 and interval < 2 ** 32 - 1
    img = bytearray(OUT)
    img[:len(kernel)] = kernel
    img[PARAMS:PARAMS + 12] = struct.pack("<3I", m, interval, counter)
    img[PRE] = 3
    img[V_AT:V_AT + SEEDLEN] = v
    img[C_AT:C_AT + SEEDLEN] = c
    img[ONE + SEEDLEN - 1] = 1
    return bytes(img)


def drbg_outcome(state, interval, m):
    """Halt 1 and nothing written when a reseed is required; else halt 0 and
    the m blocks at 0x600, the new V and counter, and the work left behind:
    data at V + m, H, and the counter's bytes."""
    v, c, counter = state
    made = drbg_generate(state, 32 * m, interval)
    if made is None:
        return 1, {}
    bits, (v2, _, counter2) = made
    return 0, {OUT: bits, V_AT: v2, PARAMS + 8: struct.pack("<I", counter2), DATA: plus(v, m),
               HB + SEEDLEN - 32: sha256(b"\x03" + v), CB + SEEDLEN - 4: counter.to_bytes(4, "big")}


def drbg_region(img, state, interval, m):
    code, writes = drbg_outcome(state, interval, m)
    out = bytearray(img) + bytes(0x10000 - len(img))
    for at, b in writes.items():
        out[at:at + len(b)] = b
    return code, bytes(out)


def cavp_cases(path=os.path.join(HERE, "cavp", "Hash_DRBG_SHA256.txt")):
    cases, group = [], {}
    for line in open(path):
        line = line.strip()
        if line.startswith("[") and " = " in line:
            k, v = line[1:-1].split(" = ")
            group[k] = v
        elif line.startswith("COUNT"):
            cases.append({"group": dict(group), "count": int(line.split("=")[1])})
        elif "=" in line and cases and not line.startswith("#"):
            k, _, v = line.partition("=")
            cases[-1].setdefault(k.strip(), []).append(v.strip())
    for c in cases:
        c["entropy"], c["nonce"] = bytes.fromhex(c["EntropyInput"][0]), bytes.fromhex(c["Nonce"][0])
        c["pers"], c["want"] = bytes.fromhex(c["PersonalizationString"][0]), bytes.fromhex(c["ReturnedBits"][0])
        c["name"] = f"CAVP P{c['group']['PersonalizationStringLen']} #{c['count']}"
    return cases


def cavp_check():
    cases = cavp_cases()
    ok = 0
    for c in cases:
        state = drbg_instantiate(c["entropy"], c["nonce"], c["pers"])
        _, state = drbg_generate(state, len(c["want"]))
        bits, state = drbg_generate(state, len(c["want"]))
        ok += bits == c["want"]
    print(f"{ok} of {len(cases)} NIST cases: instantiate, Generate twice, the second's {8 * len(cases[0]['want'])} "
          f"bits NIST's")
    sys.exit(0 if ok == len(cases) else 1)


if __name__ == "__main__":
    cavp_check()
